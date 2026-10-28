# fast-s5

**fast-s5** 是面向 **Alpine Linux + OpenRC** 的 SOCKS5 快速部署和用户管理脚本，基于 [3proxy](https://github.com/3proxy/3proxy)。只需一个 `fast-s5.sh` 文件，即可安装代理、生成账号、设置开机自启，以及添加和删除用户。

## 功能

- 用户名和密码默认各 **10 位随机英文字母和数字**，也可自定义。
- **多个用户可以共用同一个端口**，也可以为不同用户指定不同端口；每个账号只能使用其分配的端口。
- 菜单快速添加用户时只需选择端口，账号和密码自动生成。
- 首次安装随机选择空闲端口（20000–60000）；快速添加时回车共用已有端口，输入 `r` 使用随机新端口。
- 支持退格删除输入，兼容 Backspace 的 BS / DEL 两种编码；`Ctrl+U` 清空输入，密码输入不回显。
- 启动脚本时显示一次 Fast-S5 ASCII 艺术字，返回菜单时不重复显示。
- 使用 OpenRC 管理共享服务和开机自启，代理进程以低权限系统账号 `fast-s5` 运行。
- 原子写入配置；应用失败时尝试恢复旧配置和服务。支持保留配置卸载与恢复。
- 安装成功、修改配置及查看凭据时，输出可在另一台机器执行的 curl 测试命令。
- 固定编译 3proxy `0.9.5`，校验源码提交；旧版 MicroSocks 账号可自动迁移。

## 系统要求

- Alpine Linux，已启用 **OpenRC**，使用 root 执行。普通最小 Docker 容器通常不满足此条件。
- 能访问 Alpine 软件源和 GitHub；本机出口测试还需访问 `https://api.ipify.org`。
- 首次安装自动安装 `git`、`build-base`、`linux-headers`、`ca-certificates` 和 `iproute2`；出口测试按需安装 `curl`。
- 使用 Alpine 自带的 BusyBox `/bin/sh`（ash），不依赖 Bash；交互逐字输入使用 ash 的 `read -n`。
- 当前不支持 Debian、Ubuntu、CentOS 或 systemd 环境。

默认监听 `0.0.0.0`（所有 IPv4 网卡），强制用户名密码认证，只允许 SOCKS5 TCP CONNECT；不开放 BIND 或 UDP 转发。

SOCKS5 账号密码认证本身不加密客户端到代理的连接。建议通过可信网络或 VPN 使用，并限制入口来源 IP。不要将真实凭据、配置文件或含密码的终端输出提交到仓库。

## 快速开始

先以 root 登录已启用 OpenRC 的 Alpine Linux。

### 一行启动

下载脚本并打开菜单：

```sh
curl -fsSL "https://raw.githubusercontent.com/doudou770/fast-s5/main/fast-s5.sh" -o /root/fast-s5.sh && sh /root/fast-s5.sh
```

选择 `1) 安装 / 恢复`。以后执行 `sh /root/fast-s5.sh` 即可再次打开菜单。

若找不到 curl，先安装：

```sh
apk add --no-cache curl ca-certificates
```

### 一行随机安装

直接安装，端口随机，账号和密码各随机 10 位，无需交互输入：

```sh
curl -fsSL "https://raw.githubusercontent.com/doudou770/fast-s5/main/fast-s5.sh" -o /root/fast-s5.sh && sh /root/fast-s5.sh install --random
```

成功后显示凭据和远程测试命令，并开启开机自启。已有新版服务时拒绝覆盖；若此前卸载保留了配置，则恢复全部账号及原端口。

也可以先下载并检查脚本，再运行：

```sh
curl -fL --retry 3 https://raw.githubusercontent.com/doudou770/fast-s5/main/fast-s5.sh -o /root/fast-s5.sh
sh /root/fast-s5.sh install
```

交互安装时，端口、用户名、密码全部回车使用随机值，最后确认。已克隆仓库时可直接执行 `sh fast-s5.sh`。下载地址指向 `main` 分支；需要固定版本时可将 `main` 替换成已发布标签或提交号。

## 快速添加与删除用户

首次安装后，菜单选择 `9) 快速添加用户（可输入端口）`：

```text
端口 [回车共用 23456，r 随机新端口]:
```

- 回车：新用户共用 `23456` 端口。
- 输入已有端口：与该端口的用户共用监听器，使用各自的账号密码。
- 输入新的空闲端口：在该端口提供代理。
- 输入 `r` 或 `R`：随机选择尚未分配的空闲端口。

账号和密码各自动生成 10 位，成功后输出新用户的 curl 测试命令。新增端口还需要开放对应 TCP 安全组、防火墙或路由器映射。重复用户名和被其他程序占用的端口会被拒绝。

选择 `10) 删除用户`，输入用户名并确认；`11) 用户列表` 可查看全部用户名和端口。

**所有账号共用一个 fast-s5 服务。增删、修改账号或重启服务会短暂中断所有用户的连接，客户端需要重连。** 删除一个账号后，同端口的其他账号仍可登录；某端口的最后一个账号被删除后不再监听该端口。删除全部账号后停止服务，之后可重新安装。

也可以直接执行：

```sh
# 指定端口，自动生成 10 位用户名和密码；允许填写已有端口
sh /root/fast-s5.sh add-user --port 23456

# 共用第一个现有账号的端口，自动生成凭据
sh /root/fast-s5.sh add-user --random

# 交互选择端口，可自定义用户名和密码
sh /root/fast-s5.sh add-user

sh /root/fast-s5.sh users
sh /root/fast-s5.sh delete-user Ab3Cd4Ef5G
```

`Ab3Cd4Ef5G` 为示例用户名，请替换成实际值。

## 命令

以下示例假设脚本保存在 `/root/fast-s5.sh`。

| 命令 | 作用 |
| --- | --- |
| `sh /root/fast-s5.sh` | 打开菜单 |
| `sh /root/fast-s5.sh install [--random]` | 安装、恢复保留的账号，或迁移旧版服务 |
| `sh /root/fast-s5.sh users` | 列出用户名和端口，不显示密码 |
| `sh /root/fast-s5.sh add-user` | 交互添加，可选择已有端口 |
| `sh /root/fast-s5.sh add-user --random` | 共用已有端口，随机生成账号密码 |
| `sh /root/fast-s5.sh add-user --port 23456` | 指定端口，随机生成账号密码 |
| `sh /root/fast-s5.sh delete-user [用户名]` | 确认后删除用户；省略用户名时交互选择 |
| `sh /root/fast-s5.sh status [用户名]` | 查看共享服务和该账号端口状态 |
| `sh /root/fast-s5.sh credentials [IP或域名] [用户名]` | 显示凭据和远程测试命令 |
| `sh /root/fast-s5.sh configure [用户名]` | 修改账号和端口，短暂重启共享服务 |
| `sh /root/fast-s5.sh restart` | 重启共享服务并检查全部监听端口 |
| `sh /root/fast-s5.sh test [用户名]` | 测试该账号的本机代理出口 |
| `sh /root/fast-s5.sh logs` | 查看共享服务最近 50 行日志 |
| `sh /root/fast-s5.sh uninstall` | 交互卸载全部账号 |
| `sh /root/fast-s5.sh --help` | 查看帮助，无需 root |

账号命令省略用户名时操作首次安装的账号；若该账号已删除，请通过菜单选择或显式指定用户名。菜单的状态、凭据、修改和出口测试会先选择账号；重启和日志针对共享服务。命令执行失败返回非零状态码；菜单提示错误后可继续操作。

### 配置规则

| 配置 | 限制 |
| --- | --- |
| 端口 | `1024–65535`，无前导零，可与已有 fast-s5 账号共用 |
| 用户名 | 全局唯一，`1–64` 位，允许字母、数字、`_ . -` |
| 密码 | `10–128` 位，允许字母、数字、`_ -` |

首次安装时回车使用随机值；添加用户时端口回车共用已有端口，用户名和密码回车随机生成。修改配置时回车保持原值，输入 `r` 或 `R` 随机生成对应值。随机用户名和密码均为 10 位。升级脚本不会自动更改已有凭据。

## 在另一台机器测试

安装成功后会输出已填入凭据和端口的命令。将 `IP` 替换为服务器公网 IP 或域名，在另一台装有 curl 的机器执行：

```sh
curl -x socks5://账号:密码@IP:端口 http://cip.cc
```

示例（请替换为实际值）：

```sh
curl -x socks5://Ab3Cd4Ef5G:H6iJ7kL8mN@203.0.113.10:23456 http://cip.cc
```

也可以指定公网地址和用户名，让脚本生成完整命令：

```sh
sh /root/fast-s5.sh credentials 203.0.113.10 Ab3Cd4Ef5G
```

成功时 cip.cc 显示代理的出口 IP。Windows PowerShell 中若 curl 为命令别名，请使用 `curl.exe`。外部映射端口与服务端口不同的，需要将测试命令的端口改为外部端口。

`socks5://` 在客户端解析目标域名；`socks5h://` 由代理解析。排除 `NO_PROXY` 等环境设置干扰时，可执行：

```sh
curl --fail --show-error --noproxy '' \
  --connect-timeout 8 --max-time 20 \
  --proxy 'socks5h://SERVER_IP:PORT' \
  --proxy-user 'USERNAME:PASSWORD' \
  https://api.ipify.org
```

服务器上的 `sh /root/fast-s5.sh test [用户名]` 连接本机 `127.0.0.1`，验证认证和出口访问；公网入口仍需从外部机器验证。含真实密码的命令会进入终端历史，请妥善保存。

### 网络设置

VPS / 云服务器：在安全组和服务器防火墙中允许对应 TCP 端口，建议将来源限制为客户端公网 IP。脚本不自动修改防火墙或端口映射。

家用网络：为服务器固定内网 IP，在路由器上将外部 TCP 端口映射到服务器 IP 和代理端口。客户端填写公网 IP 或 DDNS 域名及外部端口。建议用手机移动网络测试，避免 NAT 回环影响判断。存在 CGNAT 或无公网 IPv4 时，单独设置路由器映射通常不能提供公网入口。

## 文件与服务

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/fast-s5-proxy` | 编译后的 3proxy 代理程序 |
| `/etc/conf.d/fast-s5` | 首个账号记录，root 所有，权限 `600` |
| `/etc/conf.d/fast-s5.user-<编号>` | 额外账号记录，root 所有，权限 `600` |
| `/etc/fast-s5/3proxy.cfg` | 自动生成的共享代理配置，root:fast-s5，权限 `640` |
| `/etc/init.d/fast-s5` | 唯一的 OpenRC 服务脚本 |
| `/var/log/fast-s5.log` | 全部账号的共享日志，fast-s5 所有，权限 `600` |
| `/var/log/fast-s5-build.log` | 最近一次构建的完整输出，权限 `600`，卸载时保留供排查 |
| `/run/fast-s5.pid` | 共享服务的 PID 文件 |
| `/run/fast-s5.lock/` | 管理器互斥锁，含管理器 PID |
| `/etc/fast-s5/migration.*` | 旧版迁移备份目录，权限 `700`，含凭据 |

账号编号为内部标识，修改用户名时不变。代理用户名不会创建 Linux 系统账号；所有监听器由系统账号 `fast-s5` 运行。`/etc/fast-s5` 目录权限为 `750`，共享配置包含明文凭据，仅 root 和服务组可读。已有可执行的 `fast-s5-proxy` 会被复用，不自动升级；请确保其来自可信来源并兼容 3proxy 0.9.5。

建议通过管理器修改账号。手动编辑账号记录时保持生成格式及权限，再执行 `restart`；不要直接编辑自动生成的 `3proxy.cfg`。OpenRC 会加载同名 `/etc/conf.d/` 文件，请仅放置可信的 root 配置。

```sh
rc-service fast-s5 status
rc-service fast-s5 stop
rc-service fast-s5 start
rc-update show default
```

共享日志可能包含用户名、客户端地址及目标信息；长期使用请自行配置日志轮转。

### 从 MicroSocks 版本升级

保留现有账号文件，用新版脚本执行 `install`，或首次执行添加、删除、修改及重启操作时，脚本会构建 3proxy、备份旧服务和账号记录，再将各独立服务合并为一个共享服务。**账号、密码及原端口保持不变**，迁移期间连接会短暂中断。旧服务名称须为 `fast-s5` 或对应的 `fast-s5.user-<编号>`。

新服务启动失败时尝试恢复旧服务。备份路径会在终端显示；若自动恢复未完成，按提示检查日志并利用备份恢复。备份含明文密码，迁移成功后也会保留，确认不再需要时由管理员移除。

更早使用 `socks5` 服务名的版本：先用旧脚本卸载并保留配置，确认旧服务已停止，将 `/etc/conf.d/socks5` 移至 `/etc/conf.d/fast-s5`（确保目标不存在），再使用新版 `install` 恢复。

## 卸载与恢复

执行 `sh /root/fast-s5.sh uninstall`：

- 选项 `1`：停止服务、取消自启、删除服务脚本及生成的共享配置，保留账号记录、程序和日志；再次 `install` 恢复全部账号。
- 选项 `2`：输入 `DELETE` 后，删除服务、账号记录、程序和日志。
- 停止或取消自启失败时中止后续操作，保留管理文件便于排查后重试。

两种方式均保留系统账号、安装依赖、下载的管理脚本及迁移备份。单独删除用户请使用菜单 `10` 或 `delete-user`。

## 常见问题

**编译时出现 warning**：3proxy 0.9.5 在部分平台上会产生整数格式或线程标识转换警告。`warning` 本身不表示构建失败，最终以脚本的构建结果和服务启动结果为准。脚本仅构建所需的 `3proxy` 程序，将依赖安装、源码下载和编译详情写入 `/var/log/fast-s5-build.log`；终端显示进度与结果，构建失败时显示末尾 40 行。已有代理程序会直接复用，无需为了这些警告重新安装。

**启动或编译失败**：检查软件源、GitHub 网络、磁盘空间和端口占用。构建问题查看 `tail -n 80 /var/log/fast-s5-build.log`；服务启动问题查看脚本的 `logs` 输出。配置应用失败时会尝试恢复原配置；停止或恢复也失败时会保留相关文件并提示人工排查。

**本机成功，外部连接失败**：核对公网地址和外部端口，检查安全组、防火墙、路由器映射及 CGNAT。

**管理器锁未清理**：检查 `/run/fast-s5.lock/pid` 中的进程。确认无管理器运行后，删除该 `pid` 文件，再用 `rmdir` 移除空锁目录。常规退出会自动清理，强制杀进程或断电可能留下锁。

## 开发与检查

Shell 文件使用 UTF-8、LF 换行，首行为 `#!/bin/sh`。

```sh
sh -n fast-s5.sh
shellcheck -s sh fast-s5.sh tests/*.sh
sh tests/run.sh

# 可选：使用实际 3proxy 0.9.5 测试认证、共享端口及删除用户
python3 tests/proxy_integration.py /path/to/3proxy
```

回归测试使用临时目录和模拟服务，覆盖共享监听配置、端口归属、快速添加、删除、迁移与失败恢复、输入编辑及凭据输出。请使用 Alpine ash 或支持 `read -n` 的 Bash。协议测试使用脚本实际生成的配置和回环地址，不访问外网。GitHub Actions 在 Alpine 上执行静态检查、回归测试，并编译固定版本代理运行协议测试；这些检查不能替代实际 OpenRC 主机上的部署验证。

提交问题时请附 Alpine 版本、运行命令和脱敏后的错误信息。

## 许可证

本项目采用 [MIT License](LICENSE)。3proxy 为独立上游项目，其版权、BSD 风格许可条款及可选许可证见 [copying](https://github.com/3proxy/3proxy/blob/0.9.5/copying)。
