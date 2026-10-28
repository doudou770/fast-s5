#!/bin/sh
# fast-s5: Alpine Linux / OpenRC SOCKS5 manager.
set -u
umask 077
LC_ALL=C
export LC_ALL

SERVICE=fast-s5
BIN=/usr/local/bin/microsocks
CONF=/etc/conf.d/fast-s5
INIT=/etc/init.d/fast-s5
LOG=/var/log/fast-s5.log
LOCK=/run/fast-s5.lock
SERVICE_USER=fast-s5
MICROSOCKS_VERSION=1.0.5
MICROSOCKS_COMMIT=98421a21c4adc4c77c0cf3a5d650cc28ad3e0107
TERMINAL_STATE=
LOCK_HELD=0

error() { printf '错误：%s\n' "$*" >&2; }

cleanup() {
    if [ -n "$TERMINAL_STATE" ]; then
        stty "$TERMINAL_STATE" 2>/dev/null || :
    fi
    if [ "$LOCK_HELD" -eq 1 ]; then
        rm -f "$LOCK/pid"
        rmdir "$LOCK" 2>/dev/null || :
    fi
}

# Handle both BS (^H) and DEL (^?) without relying on the terminal's erase setting.
# All interactive fields use ASCII; escape sequences and other controls are ignored.
read_terminal() {
    input_hidden=$1
    TERMINAL_STATE=$(stty -g) || return 1
    stty -icanon -echo min 1 time 0 || return 1
    input_bs=$(printf '\010') input_del=$(printf '\177')
    input_cr=$(printf '\r') input_eof=$(printf '\004')
    input_kill=$(printf '\025') input_esc=$(printf '\033')
    REPLY='' input_escape=0 input_result=0
    while :; do
        # BusyBox ash (Alpine /bin/sh) provides -n; keep reading in-process.
        # shellcheck disable=SC3045
        IFS= read -r -n 1 input_char || { input_result=1; break; }
        case "$input_char" in
            "$input_eof") input_result=1; break ;;
            ''|"$input_cr") break ;;
        esac
        case "$input_escape" in
            1)
                case "$input_char" in '['|O) input_escape=2 ;; *) input_escape=0 ;; esac
                continue ;;
            2)
                case "$input_char" in [a-zA-Z~]) input_escape=0 ;; esac
                continue ;;
        esac
        case "$input_char" in
            "$input_bs"|"$input_del")
                if [ -n "$REPLY" ]; then
                    REPLY=${REPLY%?}
                    [ "$input_hidden" = yes ] || printf '\b \b'
                fi ;;
            "$input_kill")
                while [ -n "$REPLY" ]; do
                    REPLY=${REPLY%?}
                    [ "$input_hidden" = yes ] || printf '\b \b'
                done ;;
            "$input_esc") input_escape=1 ;;
            [[:print:]])
                REPLY=$REPLY$input_char
                [ "$input_hidden" = yes ] || printf '%s' "$input_char" ;;
        esac
    done
    stty "$TERMINAL_STATE" || return 1
    TERMINAL_STATE=''
    printf '\n'
    [ "$input_result" -eq 0 ] || { error '输入已结束，操作取消。'; return 1; }
}

read_input() {
    printf '%s' "$1"
    if [ -t 0 ]; then
        read_terminal "$2"
    else
        IFS= read -r REPLY || { error '输入已结束，操作取消。'; return 1; }
    fi
}

read_value() { read_input "$1" no; }
read_secret() { read_input "$1" yes; }

confirm() {
    read_value "$1 [Y/n]: " || return 1
    case "$REPLY" in ''|y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

valid_port() {
    case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 5 ] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]
}

valid_user() {
    case "$1" in ''|*[!a-zA-Z0-9_.-]*) return 1 ;; esac
    [ "${#1}" -le 64 ]
}

valid_pass() {
    case "$1" in *[!a-zA-Z0-9_-]*) return 1 ;; esac
    [ "${#1}" -ge 16 ] && [ "${#1}" -le 128 ]
}

validate() {
    if ! valid_port "$PORT" || ! valid_user "$USER_NAME" || ! valid_pass "$PASS"; then
        error '端口须为 1024–65535（无前导零）；用户名 1–64 位（字母、数字、_ . -）；密码 16–128 位（字母、数字、_ -）。'
        return 1
    fi
}

# Parse the generated format as data; never execute configuration as shell code.
load_conf() {
    [ -f "$CONF" ] || { error '没有配置，请先安装。'; return 1; }
    PORT='' USER_NAME='' PASS=''
    while IFS='=' read -r conf_key conf_value || [ -n "$conf_key" ]; do
        case "$conf_key" in ''|'#'*) continue ;; esac
        case "$conf_value" in
            \"*\") conf_value=${conf_value#\"}; conf_value=${conf_value%\"} ;;
            *) error '配置格式错误，请使用管理器生成的配置。'; return 1 ;;
        esac
        case "$conf_key" in
            SOCKS_PORT) [ -z "$PORT" ] || return 1; PORT=$conf_value ;;
            SOCKS_USER) [ -z "$USER_NAME" ] || return 1; USER_NAME=$conf_value ;;
            SOCKS_PASS) [ -z "$PASS" ] || return 1; PASS=$conf_value ;;
            *) error '配置包含未知字段。'; return 1 ;;
        esac
    done < "$CONF"
    validate
}

save_conf() (
    mkdir -p "$(dirname "$CONF")" || exit 1
    conf_tmp=$(mktemp "${CONF}.tmp.XXXXXX") || exit 1
    trap 'rm -f "$conf_tmp"' 0
    trap 'exit 1' HUP INT TERM
    {
        printf 'SOCKS_PORT="%s"\n' "$PORT"
        printf 'SOCKS_USER="%s"\n' "$USER_NAME"
        printf 'SOCKS_PASS="%s"\n' "$PASS"
    } > "$conf_tmp" || exit 1
    chmod 600 "$conf_tmp" && mv -f "$conf_tmp" "$CONF"
)

randhex() {
    od -An -N "$1" -tx1 /dev/urandom | tr -d ' \n'
}

# Exit 2 means the inspection itself failed, not that the port is free.
port_busy() {
    listeners=$(ss -H -lnt) || { error '无法检查监听端口。'; return 2; }
    printf '%s\n' "$listeners" | awk -v p="$1" '
        { n = split($4, a, ":"); if (a[n] == p) found = 1 }
        END { exit !found }
    '
}

port_free() {
    if port_busy "$1"; then
        error "TCP 端口 $1 已被占用。"
        return 1
    else
        port_result=$?
        [ "$port_result" -eq 1 ]
    fi
}

randport() {
    port_attempt=0
    while [ "$port_attempt" -lt 50 ]; do
        random_number=$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n') || return 1
        candidate=$((20000 + random_number % 40001))
        if port_busy "$candidate"; then
            port_attempt=$((port_attempt + 1))
        else
            port_result=$?
            [ "$port_result" -eq 1 ] || return 1
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    error '未能找到空闲端口，请手动选择。'
    return 1
}

ensure_network_tools() {
    command -v ss >/dev/null 2>&1 || apk add --no-cache iproute2
}

ensure_service_user() {
    if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
        getent group "$SERVICE_USER" >/dev/null 2>&1 || addgroup -S "$SERVICE_USER" || return 1
        adduser -S -D -H -s /sbin/nologin -G "$SERVICE_USER" "$SERVICE_USER" || return 1
    fi
    [ "$(id -u "$SERVICE_USER")" -ne 0 ] || { error '服务账号不能是 root。'; return 1; }
}

write_service() (
    service_tmp=$(mktemp "${INIT}.tmp.XXXXXX") || exit 1
    trap 'rm -f "$service_tmp"' 0
    trap 'exit 1' HUP INT TERM
    cat > "$service_tmp" <<'EOF' || exit 1
#!/sbin/openrc-run

name="fast-s5"
description="Authenticated TCP SOCKS5 proxy managed by fast-s5"
command="/usr/local/bin/microsocks"
command_args="-i 0.0.0.0 -p ${SOCKS_PORT} -u ${SOCKS_USER} -P ${SOCKS_PASS}"
command_user="fast-s5:fast-s5"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
required_files="/etc/conf.d/fast-s5"
output_log="/var/log/fast-s5.log"
error_log="/var/log/fast-s5.log"

depend() {
    need net
}

start_pre() {
    [ -n "${SOCKS_PORT:-}" ] && [ -n "${SOCKS_USER:-}" ] && [ -n "${SOCKS_PASS:-}" ] || return 1
    # start-stop-daemon opens logs after dropping privileges.
    checkpath -f -m 0600 -o fast-s5:fast-s5 "$output_log"
}
EOF
    chmod 755 "$service_tmp" && mv -f "$service_tmp" "$INIT"
)

build_proxy() (
    [ -x "$BIN" ] && exit 0
    apk add --no-cache git build-base ca-certificates || exit 1
    work=$(mktemp -d) || exit 1
    trap 'rm -rf "$work"' 0
    trap 'exit 1' HUP INT TERM
    git clone --depth 1 --branch "v$MICROSOCKS_VERSION" \
        https://github.com/rofl0r/microsocks.git "$work/src" || exit 1
    [ "$(git -C "$work/src" rev-parse HEAD)" = "$MICROSOCKS_COMMIT" ] || {
        error 'MicroSocks 源码版本校验失败。'; exit 1;
    }
    make -C "$work/src" || exit 1
    [ -x "$work/src/microsocks" ] || { error '编译失败。'; exit 1; }
    mkdir -p "$(dirname "$BIN")" || exit 1
    install -m 755 "$work/src/microsocks" "$BIN"
)

service_ready() {
    ready_attempt=0
    while [ "$ready_attempt" -lt 5 ]; do
        if rc-service "$SERVICE" status >/dev/null 2>&1 && port_busy "$PORT"; then
            return 0
        fi
        ready_attempt=$((ready_attempt + 1))
        sleep 1
    done
    error "服务未正常运行或未监听 $PORT，请查看 $LOG。"
    return 1
}

restart_proxy() {
    load_conf && ensure_network_tools || return 1
    [ -f "$INIT" ] || { error '服务未安装，请重新安装以恢复。'; return 1; }
    rc-service "$SERVICE" restart && service_ready
}

disable_autostart() {
    runlevel_services=$(rc-update show default) || return 1
    if printf '%s\n' "$runlevel_services" | awk -v s="$SERVICE" '
        $1 == s { found = 1 } END { exit !found }
    '; then
        rc-update del "$SERVICE" default || return 1
    fi
}

show_credentials() {
    load_conf || return 1
    test_host=${1:-IP}
    case "$test_host" in
        *[!a-zA-Z0-9.-]*) error '服务器地址请填写 IPv4 或域名。'; return 1 ;;
    esac
    printf '\n========== fast-s5 账号信息 ==========\n'
    printf '监听地址：0.0.0.0（所有 IPv4 网卡）\n端口：%s\n用户名：%s\n密码：%s\n' "$PORT" "$USER_NAME" "$PASS"
    printf '连接格式：socks5://%s:%s@%s:%s\n' "$USER_NAME" "$PASS" "$test_host" "$PORT"
    printf '\n在另一台机器上测试：\n'
    printf 'curl -x socks5://%s:%s@%s:%s http://cip.cc\n' "$USER_NAME" "$PASS" "$test_host" "$PORT"
    if [ "$test_host" = IP ]; then
        printf '将命令中的 IP 替换为服务器公网 IPv4 或域名；也可运行 sh fast-s5.sh credentials 服务器IP 生成完整命令。\n'
    fi
    printf '请妥善保存凭据；公网使用需开放对应 TCP 端口。\n'
}

install_proxy() {
    install_mode=${1:-interactive}
    if [ -e "$INIT" ]; then
        error '服务已存在，请使用 status、configure 或 restart；如需重装，请先卸载。'
        return 1
    fi
    ensure_network_tools || return 1
    had_conf=0
    if [ -f "$CONF" ]; then
        load_conf || return 1
        had_conf=1
        printf '发现保留配置，将使用原账号和端口恢复服务。\n'
    else
        PORT=$(randport) || return 1
        USER_NAME="px$(randhex 5)"
        PASS=$(randhex 16) || return 1
        if [ "$install_mode" != random ]; then
            read_value "端口 [随机值 $PORT]: " || return 1
            PORT=${REPLY:-$PORT}
            read_value "用户名 [随机值 $USER_NAME]: " || return 1
            USER_NAME=${REPLY:-$USER_NAME}
            read_secret '密码（回车生成随机密码，不回显）: ' || return 1
            PASS=${REPLY:-$PASS}
        fi
    fi
    validate && port_free "$PORT" || return 1
    if [ "$install_mode" != random ]; then
        confirm '确认安装并设置开机自启？' || return 0
    fi
    build_proxy && ensure_service_user || return 1
    save_conf && write_service || return 1
    if rc-service "$SERVICE" start && service_ready; then
        if rc-update add "$SERVICE" default; then
            printf '\n安装成功，已开启开机自启。\n'
            show_credentials
            return 0
        fi
    fi
    error '安装失败，正在移除本次创建的服务。'
    if ! rc-service "$SERVICE" stop; then
        error '停止失败，已保留配置及服务文件；请检查状态并手动停止后重试。'
        return 1
    fi
    disable_autostart || { error '取消开机自启失败，已保留服务文件，请手动检查。'; return 1; }
    rm -f "$INIT"
    if [ "$had_conf" -eq 0 ]; then rm -f "$CONF"; fi
    return 1
}

status_proxy() {
    [ -f "$INIT" ] || { error '服务未安装。'; return 1; }
    load_conf && ensure_network_tools || return 1
    status_result=0
    rc-service "$SERVICE" status || status_result=1
    printf '\nTCP 端口 %s 的监听情况：\n' "$PORT"
    listeners=$(ss -H -lntp) || return 1
    printf '%s\n' "$listeners" | awk -v p="$PORT" '{ n = split($4, a, ":"); if (a[n] == p) print }'
    port_busy "$PORT" || status_result=1
    printf '\n开机自启：\n'
    runlevel_services=$(rc-update show default) || return 1
    printf '%s\n' "$runlevel_services" | awk -v s="$SERVICE" '$1 == s { print; found = 1 } END { if (!found) print "未启用" }'
    return "$status_result"
}

change_proxy() {
    load_conf && ensure_network_tools || return 1
    [ -f "$INIT" ] || { error '服务未安装，请先恢复安装。'; return 1; }
    old_port=$PORT old_user=$USER_NAME old_pass=$PASS
    read_value '新端口（回车不变，r 随机）: ' || return 1
    case "$REPLY" in r|R) PORT=$(randport) || return 1 ;; '') ;; *) PORT=$REPLY ;; esac
    read_value '新用户名（回车不变，r 随机）: ' || return 1
    case "$REPLY" in r|R) USER_NAME="px$(randhex 5)" ;; '') ;; *) USER_NAME=$REPLY ;; esac
    read_secret '新密码（回车不变，r 随机，不回显）: ' || return 1
    case "$REPLY" in r|R) PASS=$(randhex 16) || return 1 ;; '') ;; *) PASS=$REPLY ;; esac
    validate || return 1
    if [ "$PORT" != "$old_port" ]; then port_free "$PORT" || return 1; fi
    confirm '确认修改并重启？' || return 0
    save_conf || return 1
    if rc-service "$SERVICE" restart && service_ready; then
        printf '修改成功；端口改变时请同步修改防火墙和路由器映射。\n'
        show_credentials
        return 0
    fi
    error '重启失败，正在回滚旧配置。'
    PORT=$old_port USER_NAME=$old_user PASS=$old_pass
    if ! save_conf; then
        error '旧配置写回失败，请检查磁盘空间和配置文件权限。'
        return 1
    fi
    if ! rc-service "$SERVICE" restart || ! service_ready; then
        error '旧配置已恢复，但服务未恢复，请检查日志。'
    fi
    return 1
}

test_proxy() {
    load_conf || return 1
    command -v curl >/dev/null 2>&1 || apk add --no-cache curl || return 1
    printf '测试本机代理出口（不验证公网端口映射）...\n'
    # Override NO_PROXY/ALL_PROXY so this really exercises the configured proxy.
    curl --fail --silent --show-error --noproxy '' \
        --connect-timeout 8 --max-time 20 \
        --proxy "socks5h://127.0.0.1:$PORT" \
        --proxy-user "$USER_NAME:$PASS" https://api.ipify.org || return 1
    printf '\n'
}

logs_proxy() {
    [ -f "$LOG" ] || { printf '暂无日志。\n'; return 0; }
    tail -n 50 "$LOG"
}

uninstall_proxy() {
    printf '1) 删除服务，保留配置和程序（可重新安装恢复）\n2) 删除服务、配置、程序和日志\n0) 返回\n'
    read_value '选择: ' || return 1
    uninstall_mode=$REPLY
    case "$uninstall_mode" in
        0) return 0 ;;
        1) confirm '确认移除服务并保留配置？' || return 0 ;;
        2) read_value '输入 DELETE 确认完全删除: ' || return 1
           [ "$REPLY" = DELETE ] || return 0 ;;
        *) error '无效选项。'; return 1 ;;
    esac
    if [ -f "$INIT" ]; then
        rc-service "$SERVICE" stop || { error '停止服务失败，取消删除。'; return 1; }
        disable_autostart || return 1
        rm -f "$INIT" || return 1
    fi
    if [ "$uninstall_mode" = 2 ]; then
        rm -f "$CONF" "$BIN" "$LOG" || return 1
        printf '已删除服务、配置、程序和日志。\n'
    else
        printf '服务已移除；重新安装将恢复原配置。\n'
    fi
}

usage() {
    cat <<'EOF'
fast-s5 — Alpine Linux / OpenRC SOCKS5 管理器

用法：sh fast-s5.sh [命令]
  menu               交互菜单（默认）
  install            交互安装；有保留配置时恢复服务
  install --random   无需输入，使用随机端口和账号安装；保留配置优先
  status             查看服务、监听端口和开机自启状态
  credentials [IP]   显示账号密码及另一台机器的 curl 测试命令
  configure          修改端口或账号；启动失败自动回滚
  restart            重启并检查服务
  test               通过本机 SOCKS5 查询出口 IP
  logs               显示最近 50 行日志
  uninstall          卸载（交互确认）
  help, --help, -h   显示帮助
EOF
}

check_environment() {
    [ "$(id -u)" -eq 0 ] || { error '请使用 root 运行。'; return 1; }
    [ -f /etc/alpine-release ] || { error '当前仅支持 Alpine Linux。'; return 1; }
    for dependency in apk rc-service rc-update openrc-run; do
        command -v "$dependency" >/dev/null 2>&1 || { error "缺少 $dependency，请在启用 OpenRC 的 Alpine 系统运行。"; return 1; }
    done
    mkdir "$LOCK" 2>/dev/null || {
        error "另一个管理器正在运行，或上次异常退出留下锁目录：$LOCK。确认无进程后可手动移除。"
        return 1
    }
    LOCK_HELD=1
    printf '%s\n' "$$" > "$LOCK/pid"
}

menu() {
    while :; do
        printf '\n===== fast-s5 · Alpine SOCKS5 管理器 =====\n1) 安装\n2) 查看状态\n3) 查看账号密码和远程测试命令\n4) 修改配置\n5) 重启服务\n6) 测试本机代理出口\n7) 查看日志\n8) 卸载\n0) 退出\n'
        read_value '请选择: ' || return 0
        case "$REPLY" in
            1) install_proxy ;; 2) status_proxy ;; 3) show_credentials ;;
            4) change_proxy ;; 5) restart_proxy ;; 6) test_proxy ;;
            7) logs_proxy ;; 8) uninstall_proxy ;; 0) return 0 ;;
            *) error '无效选项。' ;;
        esac || printf '操作未完成，请根据上述提示处理后重试。\n' >&2
    done
}

main() {
    case "${1:-menu}" in
        help|--help|-h) usage; return 0 ;;
        install)
            if [ "$#" -gt 2 ] || { [ "$#" -eq 2 ] && [ "$2" != --random ]; }; then
                usage >&2; return 1
            fi ;;
        credentials)
            [ "$#" -le 2 ] || { usage >&2; return 1; } ;;
        menu|status|configure|restart|test|logs|uninstall)
            [ "$#" -le 1 ] || { usage >&2; return 1; } ;;
        *) usage >&2; return 1 ;;
    esac
    trap cleanup 0
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    check_environment || return 1
    case "${1:-menu}" in
        menu) menu ;;
        install) if [ "${2:-}" = --random ]; then install_proxy random; else install_proxy; fi ;;
        status) status_proxy ;; credentials) show_credentials "${2:-}" ;;
        configure) change_proxy ;; restart) restart_proxy ;; test) test_proxy ;;
        logs) logs_proxy ;; uninstall) uninstall_proxy ;;
    esac
}

main "$@"
