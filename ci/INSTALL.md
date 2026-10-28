# MySQL AUDIT 插件安装说明（openEuler 24.03 LTS-SP4 / MySQL 8.4.x）

本包由 GitHub Actions 在 openEuler 24.03 LTS-SP4 容器内编译，并已用真实的
MySQL 8.4.x 二进制加载验证过审计日志输出。

## 1. 环境要求

- 操作系统：openEuler 24.03 LTS-SP4（glibc 2.38），x86_64
- MySQL：8.4.x 官方 Linux 通用二进制（linux-glibc2.28-x86_64）
- 插件是按 mysqld 的 THD 结构体偏移工作的，**必须**使用与包名一致的
  MySQL 版本；换版本请重新编译，或在 `my.cnf` 里换一组 `audit_offsets`

## 2. 安装

```bash
# 找到 MySQL 的 plugin_dir
mysql -uroot -p -e "SHOW VARIABLES LIKE 'plugin_dir';"

# 拷贝插件（默认一般是 /usr/local/mysql/lib/plugin）
cp libaudit_plugin.so /usr/local/mysql/lib/plugin/
chown mysql:mysql /usr/local/mysql/lib/plugin/libaudit_plugin.so
chmod 755 /usr/local/mysql/lib/plugin/libaudit_plugin.so
```

## 3. 配置

把 `my.cnf.example` 里的内容合并到 `my.cnf` 的 `[mysqld]` 段：

```ini
plugin-load-add            = AUDIT=libaudit_plugin.so
audit_json_file            = ON
audit_json_log_file        = /var/log/mysql/mysql-audit.json
audit_record_cmds          = connect,quit,query,create,alter,drop,grant,insert,update,delete,select
audit_record_objs          = smoke.*
```

> 插件默认按 mysqld 二进制的 md5 匹配内置偏移表；本包已经内置了对应版本的
> 偏移行，正常情况下不需要手工设置 `audit_offsets`。
> 如果启动日志里出现 `Offsets ... match thread validation check fails`，
> 说明 mysqld 二进制与本包内置的偏移不匹配，见第 5 节。

`audit_json_file_flush` 是 NOCMDOPT 变量，不能写进 `my.cnf`，需要立即刷盘时用 SQL：

```sql
SET GLOBAL audit_json_file_flush = 1;
```

## 4. 加载与验证

```bash
systemctl restart mysqld     # 或你自己的启动方式

mysql -uroot -p -e "SELECT plugin_name, plugin_status, plugin_version
                    FROM information_schema.plugins WHERE plugin_name='AUDIT';"

# 产生一些操作，然后看审计日志
mysql -uroot -p -e "CREATE DATABASE IF NOT EXISTS demo; USE demo;
                    CREATE TABLE t1(id INT PRIMARY KEY);
                    INSERT INTO t1 VALUES (1);"
tail -n 5 /var/log/mysql/mysql-audit.json
```

正常的话每行是一条 JSON 记录，包含 `cmd`、`user`、`host`、`query` 等字段。

也可以直接 SQL 加载（不用改 my.cnf）：

```sql
INSTALL PLUGIN AUDIT SONAME 'libaudit_plugin.so';
SET GLOBAL audit_json_file = ON;
SET GLOBAL audit_json_log_file = '/var/log/mysql/mysql-audit.json';
```

## 5. 偏移不匹配怎么办

插件靠 mysqld 的 `THD` 结构体偏移取数据，不同版本/不同发行版编译的 mysqld
偏移可能不同。判断方法：

```bash
mysqld --version                 # 确认版本
md5sum $(which mysqld)           # 与发布页里记录的 md5 对比
grep -a "Using offsets" /var/log/mysqld.log
```

如果校验失败，用官方带调试符号的 mysqld 重新提取偏移：

```bash
# 需要 gdb；官方 linux-glibc2.28 tarball 里的 mysqld 带 DWARF
tar -xJf mysql-<ver>-linux-glibc2.28-x86_64.tar.xz mysql-<ver>-linux-glibc2.28-x86_64/bin/mysqld
bash ci/extract-offsets.sh mysql-<ver>-linux-glibc2.28-x86_64/bin/mysqld <ver>
```

把输出的一行加到 `src/audit_offsets.cc` 的 `/* +++ MYSQL 64 OFFSETS GO HERE +++ */`
下面，重新编译即可。也可以临时用 SQL 指定：

```sql
SET GLOBAL audit_offsets = '9512, 9552, 5024, 6452, 1280, 0, 0, 32, 64, 160, 1368, 9652, 6072, 4328, 4336, 4340, 7736, 1592, 32, 8696, 8736, 8720, 13032, 140, 668, 344';
```

## 6. 卸载

```sql
UNINSTALL PLUGIN AUDIT;   -- 需要 audit_uninstall_plugin=ON
```
