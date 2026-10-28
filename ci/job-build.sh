#!/usr/bin/env bash
# Job 2: build the plugin inside openEuler 24.03 LTS-SP4 and smoke-test it.
set -euo pipefail

LOG=/tmp/ci-build.log
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

V="${MYSQL_VERSION:?}"
REPO_ROOT="${GITHUB_WORKSPACE:-$PWD}"
OFFSETS_ROW_FILE="${OFFSETS_ROW_FILE:-/tmp/offsets-row.txt}"
SRC="/tmp/mysql-${V}"
DIST="$REPO_ROOT/dist"
cd "$REPO_ROOT"

step() { echo; echo "===== $* ====="; }

step "environment"
sed -n '1,3p' /etc/os-release
ldd --version | sed -n 1p
nproc
free -g | sed -n '1,2p'
df -h / | tail -1

step "install build dependencies"
dnf install -y -q autoconf automake libtool gcc gcc-c++ make bison gdb \
  tar xz curl openssl-devel ncurses-devel libaio libaio-devel zlib-devel \
  libtirpc-devel rpcgen pkgconf-pkg-config numactl-libs cmake \
  which diffutils file findutils python3 2>&1 | tail -5
echo "--- toolchain after install ---"
gcc --version | sed -n 1p
g++ --version | sed -n 1p
cmake --version | sed -n 1p
gdb --version 2>&1 | sed -n 1p

step "download MySQL source ${V}"
cd /tmp
curl -fsSL --retry 3 --retry-delay 5 -o mysql-src.tar.gz \
  "https://cdn.mysql.com/Downloads/MySQL-8.4/mysql-${V}.tar.gz"
ls -l mysql-src.tar.gz
tar xzf mysql-src.tar.gz
ls -d /tmp/mysql-*
[ -d "$SRC" ] || { echo "source dir $SRC missing"; ls -d /tmp/mysql-*/; exit 1; }
cat "$SRC/VERSION" 2>/dev/null || ls "$SRC"

step "generate MySQL headers (no full server build)"
cd "$SRC"
cmake . -DFORCE_INSOURCE_BUILD=1 -DWITH_UNIT_TESTS=OFF -DWITH_ROUTER=OFF \
  -DWITH_SSL=system -DCMAKE_BUILD_TYPE=Release -DWITH_DEBUG=0 > /tmp/cmake.log 2>&1 \
  || { tail -40 /tmp/cmake.log; exit 1; }
make -j"$(nproc)" GenServerSource GenError > /tmp/gen.log 2>&1 \
  || { tail -60 /tmp/gen.log; exit 1; }
ls -l include/my_config.h include/mysql_version.h include/mysqld_error.h sql/sql_yacc.h

step "patch sources"
cd "$REPO_ROOT"
DROP_WERROR="${DROP_WERROR:-1}" bash "$REPO_ROOT"/ci/patch-build.sh

step "insert offsets row for ${V}"
ROW="$(cat "$OFFSETS_ROW_FILE")"
echo "row: $ROW"
python3 "$REPO_ROOT"/ci/insert-offsets.py "$ROW"

step "repo layout"
cd "$REPO_ROOT"
pwd
ls -d src include ci configure.ac

step "bootstrap"
chmod +x bootstrap.sh
./bootstrap.sh > /tmp/autoreconf.log 2>&1 || { tail -30 /tmp/autoreconf.log; exit 1; }

step "configure"
mkdir -p /tmp/plugin
./configure --with-mysql="$SRC" --with-mysql-plugindir=/tmp/plugin > /tmp/configure.log 2>&1 \
  || { tail -40 /tmp/configure.log; exit 1; }
grep -E "CPPFLAGS:" /tmp/configure.log | tail -1

step "make"
make -j"$(nproc)" > /tmp/make.log 2>&1 || {
  echo "--- errors ---"
  grep -nE "error:|Error [0-9]" /tmp/make.log | sed -n '1,40p'
  tail -60 /tmp/make.log
  exit 1
}
grep -cE "warning:" /tmp/make.log || true

step "symbol diagnostics"
echo "--- objects ---"
nm -C src/*.o 2>/dev/null | grep -i "thd_alloc" || echo "(none in objects)"
echo "--- shared lib (all thd_alloc) ---"
readelf -sW src/.libs/libaudit_plugin.so.0.0.0 2>/dev/null | grep -i thd_alloc || echo "(none)"
echo "--- mysqld provides it? ---"
grep -c . /dev/null || true

step "prepare distributable .so"
mkdir -p "$DIST"
cp -L src/.libs/libaudit_plugin.so "$DIST/libaudit_plugin.so"
strip --strip-unneeded "$DIST/libaudit_plugin.so"
file "$DIST/libaudit_plugin.so"
echo "--- shared library deps ---"
ldd "$DIST/libaudit_plugin.so"
if ldd "$DIST/libaudit_plugin.so" | grep -q "not found"; then
  echo "ERROR: unresolved shared library dependency"; exit 1
fi
if ldd "$DIST/libaudit_plugin.so" | grep -qi "udis86"; then
  echo "ERROR: plugin still links against libudis86"; exit 1
fi
md5sum "$DIST/libaudit_plugin.so"
echo "--- exported plugin symbols ---"
nm -D --defined-only "$DIST/libaudit_plugin.so" | grep -E "_mysql_plugin|audit_plugin_so_init"

step "smoke test with real mysqld ${V}"
PLUGIN_SO="$DIST/libaudit_plugin.so" bash "$REPO_ROOT"/ci/smoke-test.sh

step "package"
name="mysql-audit-openeuler24.03-x86_64-mysql${V}"
rm -rf "pkg/$name"
mkdir -p "pkg/$name"
cp "$DIST/libaudit_plugin.so" "pkg/$name/"
cp "$REPO_ROOT"/README.md COPYING LICENSE.md plugin-name.txt "pkg/$name/"
cp "$REPO_ROOT"/ci/INSTALL.md "pkg/$name/INSTALL.md"
sed "s/@MYSQL_VERSION@/${V}/g" "$REPO_ROOT"/ci/my.cnf.example > "pkg/$name/my.cnf.example"
cp "$OFFSETS_ROW_FILE" "pkg/$name/offsets-row.txt"
(
  cd pkg
  tar czf "/tmp/${name}.tar.gz" "$name"
  sha256sum "/tmp/${name}.tar.gz" > "/tmp/${name}.tar.gz.sha256"
  md5sum "/tmp/${name}.tar.gz" > "/tmp/${name}.tar.gz.md5"
)
cp /tmp/"${name}".tar.gz* "$DIST/"
cp "$DIST/libaudit_plugin.so" "$DIST/libaudit_plugin-${V}.so"
ls -l "$DIST"

step "done"
