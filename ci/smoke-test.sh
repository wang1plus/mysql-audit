#!/usr/bin/env bash
# Load the freshly built plugin into a real mysqld and prove that the audit
# trail is written. Runs inside the openEuler container of the build job.
#
# Requires: /tmp/mysql-<ver>-linux-glibc2.28-x86_64 (official binary, already
# downloaded by the offsets job? -> we re-download here for a self-contained test)
set -euo pipefail

V="${MYSQL_VERSION:?MYSQL_VERSION not set}"
BASE="/tmp/mysql-${V}-linux-glibc2.28-x86_64"
PLUGIN_SO="${PLUGIN_SO:-dist/libaudit_plugin.so}"
WORK=/tmp/audit-smoke

echo "== preparing mysqld ${V} =="
if [ ! -x "$BASE/bin/mysqld" ]; then
  cd /tmp
  curl -fsSL --retry 3 -o mysql-bin.tar.xz \
    "https://cdn.mysql.com/Downloads/MySQL-8.4/mysql-${V}-linux-glibc2.28-x86_64.tar.xz"
  tar -xJf mysql-bin.tar.xz
fi
test -x "$BASE/bin/mysqld"
export LD_LIBRARY_PATH="$BASE/lib/private"

rm -rf "$WORK"
mkdir -p "$WORK/data" "$WORK/log"
# 不要用 --plugin-dir 覆盖 MySQL 自带的 plugin 目录，否则 mysqld 找不到自己的
# component（component_reference_cache 等）。改为把插件拷进基于目录里的 plugin/。
mkdir -p "$BASE/lib/plugin"
cp "$PLUGIN_SO" "$BASE/lib/plugin/libaudit_plugin.so"
PLUGIN_DIR="$BASE/lib/plugin"
echo "plugin dir: $PLUGIN_DIR"
ls -l "$PLUGIN_DIR/libaudit_plugin.so"
ls "$PLUGIN_DIR" | grep -c . || true

echo "== initializing a throwaway datadir =="
"$BASE/bin/mysqld" --no-defaults --initialize-insecure \
  --basedir="$BASE" --datadir="$WORK/data" --user=root \
  --log-error="$WORK/log/init.err"

echo "== starting mysqld with the plugin =="
"$BASE/bin/mysqld" --no-defaults \
  --basedir="$BASE" --datadir="$WORK/data" --user=root \
  --socket="$WORK/mysql.sock" --port=13316 --mysqlx=0 \
  --log-error="$WORK/log/run.err" \
  --plugin-dir="$PLUGIN_DIR" \
  --plugin-load-add=AUDIT=libaudit_plugin.so \
  --audit_json_file=ON \
  --audit_json_log_file="$WORK/log/audit.json" &
MYSQLD_PID=$!

cleanup() {
  "$BASE/bin/mysqladmin" --socket="$WORK/mysql.sock" -uroot shutdown >/dev/null 2>&1 \
    || kill "$MYSQLD_PID" >/dev/null 2>&1 || true
  wait "$MYSQLD_PID" 2>/dev/null || true
}
trap cleanup EXIT

for _ in $(seq 1 60); do
  [ -S "$WORK/mysql.sock" ] && break
  if ! kill -0 "$MYSQLD_PID" 2>/dev/null; then
    echo "mysqld died during startup:"; tail -40 "$WORK/log/run.err"; exit 1
  fi
  sleep 1
done
[ -S "$WORK/mysql.sock" ] || { echo "socket never appeared"; tail -40 "$WORK/log/run.err"; exit 1; }

echo "== plugin status =="
echo "--- mysqld startup log (tail) ---"
tail -40 "$WORK/log/run.err" || true
set +e
"$BASE/bin/mysql" -uroot --socket="$WORK/mysql.sock" -e \
  "SELECT plugin_name, plugin_status, plugin_version FROM information_schema.plugins WHERE plugin_name='AUDIT';" \
  | tee /tmp/plugin-status.txt
rc=$?
set -e
if [ $rc -ne 0 ]; then
  echo "--- client failed, dumping mysqld error log ---"
  tail -60 "$WORK/log/run.err" || true
  echo "--- mysqld alive? ---"
  kill -0 "$MYSQLD_PID" 2>/dev/null && echo alive || echo dead
  exit 1
fi
grep -q ACTIVE /tmp/plugin-status.txt || { echo "plugin not active"; tail -60 "$WORK/log/run.err"; exit 1; }

echo "== offsets used (from error log) =="
grep -aE "Using offsets|setup_offsets|mysqld:" "$WORK/log/run.err" | tail -6 || true

echo "== generating audit traffic =="
"$BASE/bin/mysql" -uroot --socket="$WORK/mysql.sock" -e \
  "CREATE DATABASE IF NOT EXISTS smoke; USE smoke;
   CREATE TABLE IF NOT EXISTS t (id INT PRIMARY KEY, note VARCHAR(32));
   INSERT INTO t VALUES (1,'hello') ON DUPLICATE KEY UPDATE note=VALUES(note);
   SELECT * FROM t; UPDATE t SET note='changed' WHERE id=1; DELETE FROM t WHERE id=1;
   CREATE USER IF NOT EXISTS 'smoke_user'@'localhost' IDENTIFIED BY 'Smoke#12345';
   GRANT SELECT ON smoke.* TO 'smoke_user'@'localhost';
   FLUSH PRIVILEGES;"

echo "== audit log =="
test -s "$WORK/log/audit.json" || { echo "audit log empty"; tail -40 "$WORK/log/run.err"; exit 1; }
lines=$(wc -l < "$WORK/log/audit.json")
echo "audit lines: $lines"
tail -3 "$WORK/log/audit.json"

echo "== audit log commands =="
python3 - "$WORK/log/audit.json" <<'PY'
import json, sys

seen = []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except json.JSONDecodeError:
        continue
    cmd = rec.get("cmd")
    if cmd:
        seen.append(cmd)

print("commands seen:", sorted(set(seen)))
mtypes = sorted({json.loads(l).get("msg-type") for l in open(sys.argv[1]) if l.strip()})
print("msg-types:", mtypes)

joined = " ".join(c.lower() for c in seen)

# 一定要有的：登录后的 GRANT 和会话结束的 Quit
required = ["grant", "quit"]
# DML/DDL 至少命中一个（命令名由 mysqld 的 Com_* 计数器提供，版本间可能不同）
working = ["insert", "create", "update", "delete", "select", "alter"]

missing = [w for w in required if w not in joined]
if missing:
    print("MISSING required commands:", missing)
    sys.exit(1)
if not any(w in joined for w in working):
    print("MISSING any of DML/DDL commands:", working)
    sys.exit(1)
if len(seen) < 5:
    print("too few audit records:", len(seen))
    sys.exit(1)
PY

echo "SMOKE TEST PASSED"
