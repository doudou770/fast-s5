# fast-s5

**fast-s5** 是面向 **Alpine Linux + OpenRC** 的轻量 SOCKS5 管理工具，基于 [MicroSocks](https://github.com/rofl0r/microsocks)。用一个 `fast-s5.sh` 文件完成安装、随机账号生成、开机自启、配置修改、出口测试和卸载，适合在自己的 VPS、家用小主机或 Alpine 虚拟机上快速搭建带密码的 TCP 代理。

## 功能

- 随机选择空闲端口（20000–60000），用户名和密码默认各为 **10 位随机英文字母和数字**。
- 菜单一键添加随机用户、按用户名删除用户；每个用户使用独立端口、服务和日志。
- 支持自定义端口和账号；终端输入密码时不回显。
- 交互输入兼容常见终端的 Backspace / 退格键，输入有误可删除重输；支持 `Ctrl+U` 清空当前输入。
- 使用 OpenRC 管理服务和开机自启，代理进程以独立的 `fast-s5` 低权限账号运行。
- 配置文件权限为 `600`，原子写入；修改后启动失败会尝试恢复旧配置和服务。
- 检查实际配置的监听端口，支持查看账号、最近日志和本机代理出口测试。
- 安装成功、修改配置或查看账号时，输出另一台机器可使用的 `curl -x socks5://账号:密码@IP:端口 http://cip.cc` 测试命令。
- 可保留配置卸载，再次安装时恢复原账号与端口。
- 固定编译 MicroSocks `v1.0.5`，并核对源码提交，避免默认构建随上游变化。

## 系统要求与范围

- Alpine Linux，已启用 **OpenRC**，使用 root 执行；普通的最小 Docker 容器通常不满足此条件。
- 能访问 Alpine 软件源和 GitHub；出口测试还需访问 `https://api.ipify.org`。
- 首次安装自动安装 `git`、`build-base`、`ca-certificates` 和 `iproute2`；使用出口测试时按需安装 `curl`。脚本使用 Alpine 自带的 BusyBox `/bin/sh`（ash），不依赖 Bash；交互逐字输入使用 ash 支持的 `read -n`。
- 当前仅面向 Alpine，不适用于 Debian、Ubuntu、CentOS 或 systemd 服务管理环境。
- 默认监听 `0.0.0.0`（所有 IPv4 网卡），只支持 SOCKS5 TCP CONNECT，不支持 UDP 转发。MicroSocks 可连接 IPv4、IPv6 和域名目标，具体取决于服务器网络。

**SOCKS5 用户名密码认证不加密客户端到代理服务器的连接。** 请优先通过可信网络或 VPN 访问，并限制允许连接的来源 IP。访问 HTTPS 网站也不会加密 SOCKS5 认证过程。不要将账号密码、配置文件或含凭据的终端输出提交到仓库。

## 快速开始

先以 root 登录已启用 OpenRC 的 Alpine Linux。

### 一行启动

复制下面这一行，即可下载脚本并打开管理菜单：

```sh
curl -fsSL "https://raw.githubusercontent.com/doudou770/fast-s5/main/fast-s5.sh" -o /root/fast-s5.sh && sh /root/fast-s5.sh
```

进入菜单后选择 `1) 安装 / 恢复` 即可开始。脚本保存在 `/root/fast-s5.sh`，以后运行 `sh /root/fast-s5.sh` 可再次打开菜单。脚本使用 Alpine 自带的 `sh`，无需安装 Bash。

若系统提示找不到 `curl`，先安装下载工具后重试：

```sh
apk add --no-cache curl ca-certificates
```

也可以分步下载、检查脚本后再运行：

```sh
curl -fL --retry 3 \
  https://raw.githubusercontent.com/doudou770/fast-s5/main/fast-s5.sh \
  -o /root/fast-s5.sh
chmod 700 /root/fast-s5.sh
```

### 快速随机安装

一行完成下载并直接安装，账号和密码默认各随机 10 位：

```sh
curl -fsSL "https://raw.githubusercontent.com/doudou770/fast-s5/main/fast-s5.sh" -o /root/fast-s5.sh && sh /root/fast-s5.sh install --random
```

已经下载脚本时，直接运行：

```sh
sh /root/fast-s5.sh install --random
```

无需输入端口和账号，成功后显示连接信息，并设置开机自启。已有服务时会拒绝覆盖；如果此前卸载时保留了配置，则恢复所有尚未安装的账号服务，保留原账号和端口。该命令会直接安装，请在确认需要部署的服务器上运行。

### 交互安装与管理

```sh
sh /root/fast-s5.sh
```

选择 `1) 安装 / 恢复`，按提示输入端口、用户名和密码，全部回车使用随机值，最后确认安装。也可以直接执行：

```sh
sh /root/fast-s5.sh install
```

如果已克隆本仓库，可在仓库目录执行 `sh fast-s5.sh`，不必再次下载。下载地址使用 `main` 分支最新文件；需要固定部署版本时，请将 URL 中的 `main` 替换为已发布的标签或提交号。

## 命令

以下示例假设脚本保存在 `/root/fast-s5.sh`。

| 命令 | 作用 |
| --- | --- |
| `sh /root/fast-s5.sh` | 打开交互菜单 |
| `sh /root/fast-s5.sh install` | 交互安装，或恢复保留的配置 |
| `sh /root/fast-s5.sh install --random` | 使用随机配置直接安装；存在保留配置时恢复原配置 |
| `sh /root/fast-s5.sh users` | 列出所有用户名、端口及服务名，不显示密码 |
| `sh /root/fast-s5.sh add-user --random` | 一键添加用户，账号和密码各随机 10 位，端口随机 |
| `sh /root/fast-s5.sh add-user` | 交互添加用户，可自定义账号和端口 |
| `sh /root/fast-s5.sh delete-user [用户名]` | 删除一个用户，删除前确认；省略用户名时交互选择 |
| `sh /root/fast-s5.sh status [用户名]` | 查看运行状态、监听端口和开机自启 |
| `sh /root/fast-s5.sh credentials [IP或域名] [用户名]` | 显示账号及远程 curl 测试命令，可传入服务器地址 |
| `sh /root/fast-s5.sh configure [用户名]` | 修改选中账号并重启；失败时尝试回滚 |
| `sh /root/fast-s5.sh restart [用户名]` | 重启选中账号服务并检查监听状态 |
| `sh /root/fast-s5.sh test [用户名]` | 经选中账号的本机代理查询出口 IP |
| `sh /root/fast-s5.sh logs [用户名]` | 查看选中账号最近 50 行日志 |
| `sh /root/fast-s5.sh uninstall` | 交互卸载所有用户 |
| `sh /root/fast-s5.sh --help` | 查看帮助，无需 root |

直接命令操作失败时返回非零状态码；交互菜单会显示错误并允许继续操作。输入结束时退出或取消当前操作，不会无限循环。

### 快速添加与删除用户

首次安装后，菜单选择 `9) 快速添加随机用户`，无需再输入账号和密码，成功后即可复制新用户的 curl 测试命令。选择 `10) 删除用户`，输入列表中的用户名并确认；`11) 用户列表` 可查看全部账号。菜单中的状态、凭据、修改、重启、测试和日志操作均先选择用户名。

也可以直接运行：

```sh
sh /root/fast-s5.sh add-user --random
sh /root/fast-s5.sh users
sh /root/fast-s5.sh credentials 203.0.113.10 Ab3Cd4Ef5G
sh /root/fast-s5.sh delete-user Ab3Cd4Ef5G
```

`Ab3Cd4Ef5G` 为示例用户名，请替换成实际值。**MicroSocks v1.0.5 每个进程只支持一组账号密码，因此本项目每个用户使用不同的 TCP 端口**，并单独开机自启。添加后还需为新端口配置安全组、防火墙或路由器映射；同一端口不能配置多个账号。重复用户名、已分配给其他账号的端口及正在被其他程序监听的端口会被拒绝。

删除用户会停止该用户服务、取消其开机自启，并删除对应配置和日志；其他用户不受影响。停止或取消开机自启失败时保留管理文件，排查后可再次删除。删除最后一个用户后，可以重新执行 `install` 创建账号。直接账号命令省略用户名时操作首次安装的账号；如该账号已删除，请使用菜单或显式指定现有用户名。

### 配置规则

| 配置 | 限制 |
| --- | --- |
| 端口 | `1024–65535`，十进制，无前导零，不能被其他 TCP 监听占用 |
| 用户名 | `1–64` 位，允许英文字母、数字、下划线、点、短横线 |
| 密码 | `10–128` 位，允许英文字母、数字、下划线、短横线 |

安装及添加用户时，**回车使用随机值**，用户名和密码各 10 位。修改配置时，**回车保持原值**；输入 `r` 或 `R` 随机生成对应值，随机用户名和密码也各 10 位。已有账号不会因升级脚本自动改变。密码只在输入时隐藏，查看凭据或安装成功时会明文显示。修改端口后需同步调整防火墙、安全组及路由器映射。

## 客户端连接与验证

在客户端填写服务器 IP 或域名、端口、用户名和密码，协议选择 SOCKS5。

### 在另一台机器快速测试

安装完成后，fast-s5 会输出已填入账号、密码和端口的命令。将其中的 `IP` 替换为服务器公网 IP 或域名，再复制到另一台装有 curl 的机器执行：

```sh
curl -x socks5://账号:密码@IP:端口 http://cip.cc
```

例如（以下为示例账号和文档示例 IP，请替换）：

```sh
curl -x socks5://Ab3Cd4Ef5G:H6iJ7kL8mN@203.0.113.10:23456 http://cip.cc
```

也可以在服务器上指定公网地址，直接生成完整命令：

```sh
sh /root/fast-s5.sh credentials 203.0.113.10
```

输出示例：

```text
在另一台机器上测试：
curl -x socks5://Ab3Cd4Ef5G:H6iJ7kL8mN@203.0.113.10:23456 http://cip.cc
```

成功时 cip.cc 显示代理的出口 IP 及相关信息。家宽路由器的外部映射端口与服务端口不同时，还需将命令中的端口改为外部端口。Windows PowerShell 中若 `curl` 是命令别名，请使用 `curl.exe -x ...`。

### 通过代理解析域名 / 排除测试环境干扰

`socks5://` 在客户端解析目标域名；改用 `socks5h://` 时由代理服务器解析。如果客户端设置了 `NO_PROXY`，可通过 `--noproxy ''` 强制经过代理，并设置超时：

```sh
curl --fail --show-error --noproxy '' \
  --connect-timeout 8 --max-time 20 \
  --proxy 'socks5h://SERVER_IP:PORT' \
  --proxy-user 'USERNAME:PASSWORD' \
  https://api.ipify.org
```

成功时显示代理服务器的出口 IP。含真实凭据的命令会进入终端历史，勿在共享终端中粘贴真实密码。部分客户端不支持带账号密码的 SOCKS5，请确认客户端能力。

服务器自身的测试命令：

```sh
sh /root/fast-s5.sh test
```

该命令连接 `127.0.0.1`，验证认证、代理转发和出口访问，**不能证明公网入口已经开放**。外部测试失败时，先检查以下网络设置。

### VPS / 云服务器

在云控制台安全组以及服务器防火墙中允许对应 **TCP** 端口，建议将来源限制为自己的客户端公网 IP。脚本不自动改动防火墙，也不添加端口转发规则。

### 家用网络 / 路由器后方

1. 为运行脚本的设备固定内网 IP。
2. 将路由器的外部 TCP 端口映射到设备的内网 IP 和 SOCKS5 端口。
3. 客户端使用家庭公网 IP 或 DDNS 域名；外部端口与内部端口不同时，填写外部端口。
4. 用手机移动网络等外部网络测试，避免路由器不支持 NAT 回环导致误判。

如果上级网络采用 CGNAT，或没有可入站的公网 IPv4，仅做路由器映射通常无效，需要向运营商申请公网 IP，或使用可到达该设备的 VPN 等方案。

## 文件与服务

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/microsocks` | 编译后的代理程序 |
| `/etc/conf.d/fast-s5` | 端口、用户名和密码，root 所有，权限 `600` |
| `/etc/init.d/fast-s5` | OpenRC 服务脚本 |
| `/var/log/fast-s5.log` | 服务日志，`fast-s5` 所有，权限 `600` |
| `/run/fast-s5.pid` | OpenRC 管理的进程 PID 文件 |
| `/run/fast-s5.lock/` | 防止同时运行多个管理器的锁，含管理器 PID |
| `/etc/conf.d/fast-s5.user-<编号>` | 额外用户的独立配置，权限 `600` |
| `/etc/init.d/fast-s5.user-<编号>` | 额外用户的 OpenRC 服务脚本 |
| `/var/log/fast-s5.user-<编号>.log` | 额外用户的服务日志 |
| `/run/fast-s5.user-<编号>.pid` | 额外用户的服务 PID 文件 |

首次安装的服务名为 `fast-s5`，额外用户为 `fast-s5.user-<编号>`；编号是内部随机标识，修改用户名时不变。所有代理进程的系统运行账号和组均为 `fast-s5`，代理用户名不创建 Linux 系统账号。已有可执行的 `/usr/local/bin/microsocks` 会被复用，脚本不自动升级它；请确保它来自可信来源并兼容 MicroSocks 参数。请在未被其他服务占用上述路径的系统上使用。

OpenRC 会加载各服务对应的 `/etc/conf.d/` 配置，因此请保持其为可信的 root 配置。建议通过管理器修改；手动编辑后务必保持生成格式及权限，再执行 `restart`。不要将不可信文件放入这些路径。

```sh
rc-service fast-s5 status
rc-service fast-s5 stop
rc-service fast-s5 start
rc-update show default
```

日志可能包含客户端地址及目标信息；长期使用请自行配置日志轮转。脚本不会自动安装日志轮转服务。

### 从旧命名版本迁移

如果已部署早期使用 `socks5` 服务名的版本，请先用旧版脚本卸载并选择保留配置，停止旧服务后，将 `/etc/conf.d/socks5` 移动为 `/etc/conf.d/fast-s5`（确保目标不存在），再运行 `sh /root/fast-s5.sh install` 恢复原账号与端口。新版管理的是 `fast-s5` 服务，请避免同时保留旧服务运行。

## 卸载与恢复

```sh
sh /root/fast-s5.sh uninstall
```

- 选项 `1`：停止所有用户服务、取消开机自启、删除服务脚本，保留各账号配置、程序和日志。之后执行 `install` 或 `install --random` 恢复全部保留账号。
- 选项 `2`：输入 `DELETE` 后，停止所有用户服务并删除各服务脚本、配置、日志及共享代理程序。
- 停止服务或取消开机自启失败时中止后续卸载并保留共享程序；此前已经完成的用户操作不回滚。排查后重新执行即可继续。

只想删除单个用户时，请选择菜单 `10) 删除用户` 或执行 `delete-user`。

两种方式均保留系统账号 `fast-s5`、安装依赖以及下载的管理脚本，避免影响其他用途。脚本不会删除你自行保存的配置备份，也不会更改路由器或云安全组。

## 常见问题

**启动或编译失败**

检查 Alpine 软件源、GitHub 网络连通性、可用磁盘空间和端口占用，查看 `logs` 输出。安装失败时会尝试撤销新建服务；若停止服务失败，会保留配置和服务文件便于排查。修改配置后启动失败会尝试恢复旧配置；如果恢复服务也失败，需要根据日志手动处理。

**本机测试成功，其他设备连接失败**

核对服务器地址和客户端端口，再检查云安全组、系统防火墙、路由器 TCP 映射以及是否存在 CGNAT。确认修改配置后客户端也更新了账号和端口。

**出现管理器锁目录提示**

先检查 `/run/fast-s5.lock/pid` 中记录的进程是否仍在运行。只有确认没有其他管理器运行后，才删除该目录中的 `pid` 文件并用 `rmdir` 移除空目录。正常退出及常规中断会自动清理；强制杀死进程或断电可能留下锁。

**能否用于 UDP、无认证代理或加密隧道？**

当前脚本始终启用账号密码认证，MicroSocks 此版本仅支持 TCP。需要 UDP 或加密传输时应选择支持相应功能的方案，或通过 VPN 使用本服务。

## 开发与检查

保持 Shell 文件为 UTF-8、LF 换行，首行为 `#!/bin/sh`。

```sh
sh -n fast-s5.sh
shellcheck -s sh fast-s5.sh tests/*.sh
sh tests/run.sh
```

回归测试使用临时目录和模拟命令，不会安装代理或修改系统服务，覆盖 10 位随机凭据、用户添加和删除、重复账号和端口拒绝、多用户卸载恢复、输入校验、退格编辑、密码隐藏、远程测试命令生成、配置读取及修改失败回滚等流程。请使用 Alpine ash 或支持 `read -n` 的 Bash 执行测试。GitHub Actions 在 Alpine 容器中执行语法、ShellCheck 和回归检查；这些检查不能替代实际 OpenRC 主机上的完整部署验证。

提交问题时请附上 Alpine 版本、运行命令及脱敏后的错误信息，移除密码、公网 IP 和个人数据。欢迎提交修复及改进。

## 许可证

本项目采用 [MIT License](LICENSE)。MicroSocks 是独立的上游项目，也使用 MIT 许可证，其版权及许可说明见上游 [COPYING](https://github.com/rofl0r/microsocks/blob/v1.0.5/COPYING)。
