#!/usr/bin/env bash
# Job 1: extract THD offsets from the official mysqld binary of $MYSQL_VERSION.
set -euo pipefail

LOG=/tmp/ci-offsets.log
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

V="${MYSQL_VERSION:?MYSQL_VERSION is not set}"
OUT_DIR="${OFFSETS_OUT:-$PWD/offsets-out}"
mkdir -p "$OUT_DIR"

echo "== target mysql version: $V =="
echo "== arch: $(uname -m) =="
df -h /tmp | tail -1

echo
echo "== download official binary tarball =="
url="https://cdn.mysql.com/Downloads/MySQL-8.4/mysql-${V}-linux-glibc2.28-x86_64.tar.xz"
echo "url=$url"
curl -fsSL --retry 3 --retry-delay 5 -o /tmp/mysql-bin.tar.xz "$url"
ls -l /tmp/mysql-bin.tar.xz
xz -t /tmp/mysql-bin.tar.xz && echo "xz integrity: ok"

echo
echo "== extract bin/mysqld only =="
mkdir -p /tmp/dist
tar -xJf /tmp/mysql-bin.tar.xz -C /tmp/dist --wildcards '*/bin/mysqld'
BIN="$(find /tmp/dist -type f -name mysqld | sed -n 1p)"
[ -n "$BIN" ] || { echo "mysqld not found in tarball"; find /tmp/dist -maxdepth 4 | sed -n '1,20p'; exit 1; }
echo "bin=$BIN"
ls -l "$BIN"
md5sum -b "$BIN"

echo
echo "== gdb =="
gdb --version 2>&1 | sed -n 1p

echo
echo "== extract THD offsets =="
ROW="$(bash ci/extract-offsets.sh "$BIN" "$V")"
echo "----ROW-BEGIN----"
echo "$ROW"
echo "----ROW-END----"
echo "offset values: $(echo "$ROW" | sed 's/.*\",//' )"
printf '%s\n' "$ROW" > "$OUT_DIR/offsets-row.txt"

echo
echo "== validate row =="
python3 - "$OUT_DIR/offsets-row.txt" <<'PY'
import sys
row = open(sys.argv[1]).read().strip()
parts = row.split('"')
version, md5, numbers = parts[1], parts[3], parts[-1]
nums = [int(x) for x in numbers.split(",") if x.strip()]
print("version:", version)
print("md5:", md5)
print("field count:", len(nums), "(expected 26)")
assert len(nums) == 26, "unexpected number of offsets"
assert all(n >= 0 for n in nums), "negative offset"
print("values:", nums)
PY

echo
echo "== done =="
