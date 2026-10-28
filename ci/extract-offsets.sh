#!/usr/bin/env bash
# Extract THD offsets from a mysqld binary that carries DWARF debug info and
# print them as a ThdOffsets initializer row body.
#
# Usage: extract-offsets.sh <path-to-mysqld> [version-label]
#
# Oracle's official "linux-glibc2.28" tarballs ship an unstripped mysqld
# (~450 MB) with full DWARF, so no MySQL source build is needed for this step.
set -euo pipefail

BIN="${1:?usage: extract-offsets.sh <mysqld> [version]}"
LABEL="${2:-}"

[ -f "$BIN" ] || { echo "not a file: $BIN" >&2; exit 2; }
BIN="$(readlink -f "$BIN")"

if [ -z "$LABEL" ]; then
  # label is normally passed in by the caller; fall back to a strings scan
  LABEL="$(strings "$BIN" 2>/dev/null | grep -m1 -oE 'Ver [0-9][0-9.]+' | awk '{print $2}' || true)"
fi
[ -n "$LABEL" ] || { echo "cannot determine version, pass it as 2nd argument" >&2; exit 2; }

MD5="$(md5sum -b "$BIN" | awk '{print $1}')"

GDB_SCRIPT="$(mktemp)"
trap 'rm -f "$GDB_SCRIPT"' EXIT

cat > "$GDB_SCRIPT" <<'GDBEOF'
# gdb expands its type table lazily; ptype/info types warms it up so that
# lookup_type("THD") below does not fail with "No type named THD".
set language c++
info types ^THD$
ptype THD

python
import gdb
import json

# ThdOffsets field order (lex_comment is inserted separately: MySQL 8.4 has no
# LEX::comment, offset-extract.sh emits a literal 0 for it).
layout = [
    ("THD", "query_id"),
    ("THD", "m_thread_id"),
    ("THD", "m_main_security_ctx"),
    ("THD", "m_command"),
    ("THD", "lex"),
    (None, None),  # lex_comment -> 0
    ("Security_context", "m_user"),
    ("Security_context", "m_host"),
    ("Security_context", "m_ip"),
    ("Security_context", "m_priv_user"),
    ("THD", "m_db"),
    ("THD", "killed"),
    ("THD", "m_protocol"),
    ("PFS_thread", "m_session_connect_attrs"),
    ("PFS_thread", "m_session_connect_attrs_length"),
    ("PFS_thread", "m_session_connect_attrs_cs_number"),
    ("THD", "net"),
    ("LEX", "m_sql_cmd"),
    ("Sql_cmd_uninstall_plugin", "m_comment"),
    ("THD", "previous_found_rows"),
    ("THD", "m_sent_row_count"),
    ("THD", "m_row_count_func"),
    ("THD", "m_stmt_da"),
    ("Diagnostics_area", "m_status"),
    ("Diagnostics_area", "m_mysql_errno"),
    ("Table_ref", "view_tables"),
]

values = []
errors = []
for tname, field in layout:
    if tname is None:
        values.append(0)
        continue
    value = None
    # preferred: let the expression evaluator resolve it (same as the
    # upstream offset-extract.sh does with printf)
    try:
        value = int(gdb.parse_and_eval("(size_t)&((%s*)0)->%s" % (tname, field)))
    except Exception:
        pass
    if value is None:
        try:
            value = int(gdb.lookup_type(tname)[field].bitpos // 8)
        except Exception as exc:
            errors.append("%s::%s (%s)" % (tname, field, str(exc)[:60]))
    values.append(value)

print("OFFSETS_JSON " + json.dumps({"values": values, "errors": errors}))
end
GDBEOF

RAW="$(gdb -n -q -batch -x "$GDB_SCRIPT" "$BIN" 2>/dev/null | grep '^OFFSETS_JSON' | tail -1 || true)"
if [ -z "$RAW" ]; then
  echo "ERROR: gdb could not read type information (stripped binary?)" >&2
  exit 3
fi

python3 - "$RAW" "$LABEL" "$MD5" <<'PY'
import json, sys

raw, label, md5 = sys.argv[1], sys.argv[2], sys.argv[3]
payload = json.loads(raw.split(" ", 1)[1])
values, errors = payload["values"], payload["errors"]

if errors:
    print("ERROR: unresolved fields: " + ", ".join(errors), file=sys.stderr)
    sys.exit(4)
if any(v is None for v in values):
    print("ERROR: some offsets are missing", file=sys.stderr)
    sys.exit(4)

print('"%s","%s", %s' % (label, md5, ", ".join(str(v) for v in values)))
PY
