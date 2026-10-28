# CI 构建流水线说明

`.github/workflows/build.yml` 在 GitHub 的免费 runner 上完成：

1. 从官方 MySQL 二进制包提取 THD 偏移
2. 在 openEuler 24.03 LTS-SP4 容器里编译插件
3. 用真实的 mysqld 加载插件并校验审计日志
4. 打包并（可选）发布到 GitHub Release

## 为什么这样做

这个插件不是普通插件：它直接按 `THD` 结构体的内存偏移读数据，所以

- 必须和目标 mysqld **版本一一对应**（仓库里原有 8.4.4/8.4.5 的偏移，
  8.4.13 的 `stmt_da` 已经从 13032 变成 13088）；
- 必须在目标系统的 glibc 上编译（openEuler 24.03 是 glibc 2.38，
  ubuntu-22.04 只有 2.35、ubuntu-24.04 是 2.39，直接宿主编译容易踩符号版本），
  所以构建放在 openEuler 容器里跑。

官方 `mysql-<ver>-linux-glibc2.28-x86_64.tar.xz` 里的 `mysqld` 是**带 DWARF
调试信息**的（约 450MB），因此偏移可以被 gdb 自动提取，不需要先编译整个
MySQL server。

## 触发方式

| 方式 | 行为 |
| --- | --- |
| Actions → build → Run workflow | 可指定 MySQL 版本，默认构建并发布 |
| push 形如 `v*` 的 tag | 自动构建并发布 |
| Pull Request | 只构建验证，不发布 |

手动触发时可选参数：

- `mysql_version`：默认 `8.4.13`
- `publish_release`：是否发布到 Release（默认开）
- `release_tag`：Release tag，留空则用 `v<mysql_version>-<run_number>`

## 产物

`dist/` 里会有：

- `libaudit_plugin-<ver>.so` — 插件本体（已 strip，不依赖私有 .so）
- `mysql-audit-openeuler24.03-x86_64-mysql<ver>.tar.gz` — 含插件 + 安装文档 + my.cnf 示例
- `.md5` / `.sha256` 校验文件

## 脚本职责

| 文件 | 作用 |
| --- | --- |
| `ci/job-offsets.sh` | 下载官方二进制、提取偏移、校验字段数 |
| `ci/extract-offsets.sh` | gdb 脚本：从带 DWARF 的 mysqld 读 `THD`/`LEX`/`Security_context` 等字段偏移 |
| `ci/patch-build.sh` | 让老代码能在 gcc 12 + MySQL 8.4 头文件下编译（详见脚本内注释） |
| `ci/insert-offsets.py` | 把新偏移行插入 `src/audit_offsets.cc`（幂等） |
| `ci/job-build.sh` | 生成 MySQL 头文件、bootstrap、configure、make、打包 |
| `ci/smoke-test.sh` | 启动真实 mysqld、加载插件、断言审计日志里有预期命令 |

## patch-build.sh 改了哪些地方

原样保留上游代码、改在构建期打补丁，是为了以后还能顺利 merge 上游。
每个补丁的原因都写在脚本注释里，主要有：

1. `udis86/Makefile.am` 的 SUBDIRS 指向了顶层 configure 不会生成的子目录
2. `udis86/libudis86/Makefile.am` 的 `@PYTHON@` 未被替换、相对路径不对
3. udis86 的 python 脚本是 python2 写法（`/` 整除在 py3 变成 float）
4. udis86 缺 config.h
5. udis86 必须以 noinst 方式静态链进插件，否则 `.so` 依赖 `libudis86.so.0`
6. MySQL 8.4 头文件需要 C++20，原 configure.ac 硬写 CXXFLAGS 没带 `-std`
7. MySQL ≥ 8.4 把 binlog event 头文件挪到了 `<src>/libs`
8. `thd_alloc_service` 在 `-fno-common`（gcc≥10）下必须由插件自己定义，
   且初值必须是版本号，否则 mysqld 加载时报 `undefined symbol`

## 换一个 MySQL 版本

默认支持任何 8.4.x：手动触发时把 `mysql_version` 改掉即可，偏移会自动
重新提取。如果目标版本改动了 `THD` 布局或插件依赖的 API，编译或自测会
直接失败，失败原因看对应 run 的 `build-log` artifact 或展开的日志。
