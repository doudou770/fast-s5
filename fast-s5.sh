#!/bin/sh
# fast-s5: Alpine Linux / OpenRC SOCKS5 manager.
# Account values are loaded inside each operation, including isolated subshells.
# shellcheck disable=SC2030,SC2031
set -u
umask 077
LC_ALL=C
export LC_ALL

SERVICE=fast-s5
BIN=/usr/local/bin/fast-s5-proxy
RUNTIME=/etc/fast-s5/3proxy.cfg
PIDFILE=/run/fast-s5.pid
LEGACY_BIN=/usr/local/bin/microsocks
CONF=/etc/conf.d/fast-s5
INIT=/etc/init.d/fast-s5
LOG=/var/log/fast-s5.log
LOCK=/run/fast-s5.lock
SERVICE_USER=fast-s5
PROXY_VERSION=0.9.5
PROXY_COMMIT=f23fc4fc4458606a257a9f26bc37251fc60e1cc7
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
    [ "${#1}" -ge 10 ] && [ "${#1}" -le 128 ]
}

validate() {
    if ! valid_port "$PORT" || ! valid_user "$USER_NAME" || ! valid_pass "$PASS"; then
        error '端口须为 1024–65535（无前导零）；用户名 1–64 位（字母、数字、_ . -）；密码 10–128 位（字母、数字、_ -）。'
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

# Reject bytes >=248 so each of the 62 characters has equal probability.
random_credential() {
    credential=$(od -An -N64 -tu1 /dev/urandom | awk '
        BEGIN { chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789" }
        { for (i = 1; i <= NF; i++) if ($i < 248) {
            printf "%s", substr(chars, ($i % 62) + 1, 1)
            if (++count == 10) exit
        } }
    ') || return 1
    [ "${#credential}" -eq 10 ] || { error '随机凭据生成失败。'; return 1; }
    printf '%s\n' "$credential"
}

# Keep the original account's paths; extra accounts have stable record IDs.
init_account_paths() {
    BASE_SERVICE=$SERVICE BASE_CONF=$CONF BASE_INIT=$INIT BASE_LOG=$LOG
}

account_context() {
    SERVICE=$BASE_SERVICE CONF=$BASE_CONF INIT=$BASE_INIT LOG=$BASE_LOG
    if [ "$1" != default ]; then
        case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac
        [ "${#1}" -eq 10 ] || return 1
        CONF="$BASE_CONF.user-$1"
    fi
}

account_ids() {
    [ ! -f "$BASE_CONF" ] || printf 'default\n'
    for account_file in "$BASE_CONF".user-*; do
        [ -f "$account_file" ] || continue
        account_id=${account_file#"$BASE_CONF.user-"}
        case "$account_id" in ''|*[!0-9a-f]*) continue ;; esac
        [ "${#account_id}" -ne 10 ] || printf '%s\n' "$account_id"
    done
}

account_record() (
    account_context "$1" && load_conf || exit 1
    printf '%s %s\n' "$USER_NAME" "$PORT"
)

validate_unique() {
    for unique_id in $(account_ids); do
        unique_conf=$BASE_CONF
        [ "$unique_id" = default ] || unique_conf="$BASE_CONF.user-$unique_id"
        [ "$unique_conf" != "$CONF" ] || continue
        unique_record=$(account_record "$unique_id") || return 1
        if [ "${unique_record% *}" = "$USER_NAME" ]; then
            error '用户名已存在，请使用其他用户名。'; return 1
        fi
    done
}

port_reserved() {
    for reserved_id in $(account_ids); do
        reserved_record=$(account_record "$reserved_id") || return 2
        [ "${reserved_record##* }" != "$1" ] || return 0
    done
    return 1
}

list_users() {
    list_ids=$(account_ids)
    [ -n "$list_ids" ] || { error '没有账号，请先安装。'; return 1; }
    printf '\n用户名\tTCP 端口\t服务名\n'
    for list_id in $list_ids; do
        list_record=$(account_record "$list_id") || return 1
        printf '%s\t%s\t%s\n' "${list_record% *}" "${list_record##* }" "$BASE_SERVICE"
    done
}

select_account() {
    list_users || return 1
    if [ -n "${1:-}" ]; then
        selected_name=$1
    else
        read_value '输入要操作的用户名（回车取消）: ' || return 1
        selected_name=$REPLY
        [ -n "$selected_name" ] || return 2
    fi
    for selected_id in $(account_ids); do
        selected_record=$(account_record "$selected_id") || return 1
        if [ "${selected_record% *}" = "$selected_name" ]; then
            account_context "$selected_id"
            return $?
        fi
    done
    error '找不到该用户名。'
    return 1
}

account_action() (
    # Direct commands retain the original account default when no name is given.
    account_function=$1 account_name=${2:-}
    if [ -n "$account_name" ]; then
        select_account "$account_name" || exit 1
    else
        account_context default || exit 1
    fi
    "$account_function" "${3:-}"
)

menu_account_action() (
    select_account || { select_result=$?; [ "$select_result" -eq 2 ]; exit $?; }
    "$1"
)

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
        if port_reserved "$candidate"; then
            port_attempt=$((port_attempt + 1))
            continue
        else
            reserved_result=$?
            [ "$reserved_result" -eq 1 ] || return 1
        fi
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
    service_tmp=$(mktemp "${BASE_INIT}.tmp.XXXXXX") || exit 1
    trap 'rm -f "$service_tmp"' 0
    trap 'exit 1' HUP INT TERM
    cat > "$service_tmp" <<EOF || exit 1
#!/sbin/openrc-run
# fast-s5 backend: 3proxy-v1
name="fast-s5"
description="Authenticated multi-user SOCKS5 proxy managed by fast-s5"
command="$BIN"
command_args="$RUNTIME"
command_user="fast-s5:fast-s5"
command_background="yes"
pidfile="$PIDFILE"
required_files="$RUNTIME"
output_log="$BASE_LOG"
error_log="\$output_log"
depend() { need net; }
start_pre() {
    checkpath -f -m 0600 -o fast-s5:fast-s5 "\$output_log"
}
EOF
    chmod 755 "$service_tmp" && mv -f "$service_tmp" "$BASE_INIT"
)

build_proxy() (
    [ -x "$BIN" ] && exit 0
    apk add --no-cache git build-base linux-headers ca-certificates || exit 1
    work=$(mktemp -d) || exit 1
    trap 'rm -rf "$work"' 0
    trap 'exit 1' HUP INT TERM
    git clone --depth 1 --branch "$PROXY_VERSION" https://github.com/3proxy/3proxy.git "$work/src" || exit 1
    [ "$(git -C "$work/src" rev-parse HEAD)" = "$PROXY_COMMIT" ] || {
        error '3proxy 源码版本校验失败。'; exit 1;
    }
    make -C "$work/src" -f Makefile.Linux PLUGINS='' || exit 1
    [ -x "$work/src/bin/3proxy" ] || { error '编译失败。'; exit 1; }
    mkdir -p "$(dirname "$BIN")" || exit 1
    install -m 755 "$work/src/bin/3proxy" "$BIN"
)

account_credentials() (
    account_context "$1" && load_conf || exit 1
    printf '%s %s %s\n' "$USER_NAME" "$PASS" "$PORT"
)

secure_runtime() {
    chmod 750 "$(dirname "$RUNTIME")" && chown "root:$SERVICE_USER" "$(dirname "$RUNTIME")" &&
        chmod 640 "$1" && chown "root:$SERVICE_USER" "$1"
}

write_runtime() (
    mkdir -p "$(dirname "$RUNTIME")" || exit 1
    runtime_tmp=$(mktemp "${RUNTIME}.tmp.XXXXXX") || exit 1
    records_tmp=$(mktemp "${RUNTIME}.records.XXXXXX") || { rm -f "$runtime_tmp"; exit 1; }
    trap 'rm -f "$runtime_tmp" "$records_tmp"' 0
    trap 'exit 1' HUP INT TERM
    for runtime_id in $(account_ids); do
        account_credentials "$runtime_id" >> "$records_tmp" || exit 1
    done
    [ -s "$records_tmp" ] || { error '没有账号，不能生成服务配置。'; exit 1; }
    # Each port has one listener and an explicit list of permitted users.
    awk '
        BEGIN { print "# Generated by fast-s5\nlog\ntimeouts 1 5 30 60 180 1800 15 60" }
        {
            if (seen_user[$1]++) { bad = 1; exit }
            print "users " $1 ":CL:" $2
            if (!($3 in names)) order[++n] = $3
            names[$3] = names[$3] (names[$3] ? "," : "") $1
        }
        END {
            if (bad) exit 1
            for (i = 1; i <= n; i++) {
                p = order[i]
                print "# fast-s5 port " p
                print "flush\nauth strong"
                print "allow " names[p] " * * * CONNECT"
                print "deny *"
                print "socks -u2 -i0.0.0.0 -p" p
            }
        }
    ' "$records_tmp" > "$runtime_tmp" || { error '用户名重复，无法生成配置。'; exit 1; }
    secure_runtime "$runtime_tmp" && mv -f "$runtime_tmp" "$RUNTIME"
)

runtime_ports() {
    [ -f "$RUNTIME" ] || return 1
    awk '$1 == "#" && $2 == "fast-s5" && $3 == "port" { print $4 }' "$RUNTIME"
}

managed_port() {
    [ -f "$BASE_INIT" ] && [ -f "$PIDFILE" ] && [ -f "$RUNTIME" ] || return 1
    grep -Fx "# fast-s5 port $1" "$RUNTIME" >/dev/null || return 1
    rc-service "$BASE_SERVICE" status >/dev/null 2>&1 || return 1
    managed_pid=$(cat "$PIDFILE") || return 1
    case "$managed_pid" in ''|0|*[!0-9]*) return 1 ;; esac
    managed_listeners=$(ss -H -lntp) || return 1
    printf '%s\n' "$managed_listeners" | awk -v p="$1" -v pid="$managed_pid" '
        { n = split($4, a, ":"); if (a[n] == p && index($0, "pid=" pid ",")) found = 1 }
        END { exit !found }
    '
}

port_available() {
    if port_busy "$1"; then
        managed_port "$1" || { error "TCP 端口 $1 被其他进程占用，不能使用。"; return 1; }
    else
        available_result=$?
        [ "$available_result" -eq 1 ] || return 1
    fi
}

service_ready() {
    ready_attempt=0
    while [ "$ready_attempt" -lt 5 ]; do
        ready_ok=1
        ready_ports=$(runtime_ports) || return 1
        [ -n "$ready_ports" ] || return 1
        for ready_port in $ready_ports; do managed_port "$ready_port" || ready_ok=0; done
        [ "$ready_ok" -ne 1 ] || return 0
        ready_attempt=$((ready_attempt + 1))
        sleep 1
    done
    error "共享服务未正常监听所有端口，请查看 $BASE_LOG。"
    return 1
}

disable_autostart() {
    runlevel_services=$(rc-update show default) || return 1
    if printf '%s\n' "$runlevel_services" | awk -v s="$SERVICE" '
        $1 == s { found = 1 } END { exit !found }
    '; then rc-update del "$SERVICE" default || return 1; fi
}

# Return 2 if the new service cannot be stopped: keep all files for recovery.
apply_runtime() (
    mkdir -p "$(dirname "$RUNTIME")" || exit 1
    runtime_old=$(mktemp "${RUNTIME}.rollback.XXXXXX") || exit 1
    trap 'rm -f "$runtime_old"' 0
    had_runtime=0
    if [ -f "$RUNTIME" ]; then cp -p "$RUNTIME" "$runtime_old" || exit 1; had_runtime=1; fi
    write_runtime || exit 1
    if rc-service "$BASE_SERVICE" "${1:-restart}" && service_ready; then exit 0; fi
    error '应用配置失败，正在恢复原服务配置。'
    if ! rc-service "$BASE_SERVICE" stop; then
        # Preserve the old runtime as well if the running state is uncertain.
        trap - 0
        error "停止失败，已保留账号文件、当前配置及旧配置 $runtime_old，请手动排查。"
        exit 2
    fi
    if [ "$had_runtime" -eq 1 ]; then
        mv -f "$runtime_old" "$RUNTIME" || exit 2
        if ! rc-service "$BASE_SERVICE" start || ! service_ready; then
            error '原服务配置已恢复，但服务启动失败，请查看日志。'
        fi
    else
        rm -f "$RUNTIME" || exit 2
    fi
    exit 1
)

legacy_init_path() {
    if [ "$1" = default ]; then printf '%s\n' "$BASE_INIT"; else printf '%s.user-%s\n' "$BASE_INIT" "$1"; fi
}

legacy_service_name() {
    if [ "$1" = default ]; then printf '%s\n' "$BASE_SERVICE"; else printf '%s.user-%s\n' "$BASE_SERVICE" "$1"; fi
}

restore_legacy() (
    restore_dir=$1
    rm -f "$BASE_INIT" "$RUNTIME" || exit 1
    restore_result=0
    while read -r restore_id restore_running restore_enabled; do
        restore_path=$(legacy_init_path "$restore_id")
        restore_name=$(legacy_service_name "$restore_id")
        cp -p "$restore_dir/$restore_id.init" "$restore_path" || { restore_result=1; continue; }
        if [ "$restore_enabled" = 1 ]; then rc-update add "$restore_name" default || restore_result=1; fi
        if [ "$restore_running" = 1 ] && ! rc-service "$restore_name" status >/dev/null 2>&1; then
            rc-service "$restore_name" start || restore_result=1
        fi
    done < "$restore_dir/services"
    exit "$restore_result"
)

migrate_legacy() (
    mkdir -p "$(dirname "$RUNTIME")" || exit 1
    migration_dir=$(mktemp -d "$(dirname "$RUNTIME")/migration.XXXXXX") || exit 1
    chmod 700 "$migration_dir" || exit 1
    : > "$migration_dir/services"
    migration_autostart=$(rc-update show default) || exit 1
    migration_ids=$(account_ids)
    [ -f "$BASE_CONF" ] || migration_ids="default $migration_ids"
    for migration_id in $migration_ids; do
        migration_path=$(legacy_init_path "$migration_id")
        [ -f "$migration_path" ] || continue
        grep -F microsocks "$migration_path" >/dev/null || { error "无法识别旧服务 $migration_path，已取消迁移。"; exit 1; }
        cp -p "$migration_path" "$migration_dir/$migration_id.init" || exit 1
        migration_conf=$BASE_CONF
        [ "$migration_id" = default ] || migration_conf="$BASE_CONF.user-$migration_id"
        [ ! -f "$migration_conf" ] || cp -p "$migration_conf" "$migration_dir/$migration_id.conf" || exit 1
        migration_running=0 migration_enabled=0
        migration_name=$(legacy_service_name "$migration_id")
        rc-service "$migration_name" status >/dev/null 2>&1 && migration_running=1
        if printf '%s\n' "$migration_autostart" | awk -v s="$migration_name" '$1 == s { f=1 } END { exit !f }'; then migration_enabled=1; fi
        printf '%s %s %s\n' "$migration_id" "$migration_running" "$migration_enabled" >> "$migration_dir/services"
    done
    # Build/validate before stopping any existing proxy.
    write_runtime || exit 1
    printf '正在迁移到支持同端口多用户的共享服务；备份：%s\n' "$migration_dir"
    while read -r migration_id migration_running migration_enabled; do
        migration_name=$(legacy_service_name "$migration_id")
        if { [ "$migration_running" = 1 ] && ! rc-service "$migration_name" stop; } ||
            { [ "$migration_enabled" = 1 ] && ! rc-update del "$migration_name" default; }; then
            restore_legacy "$migration_dir" || error "旧服务恢复未完成，请使用备份 $migration_dir 排查。"
            exit 1
        fi
    done < "$migration_dir/services"
    while read -r migration_id migration_running migration_enabled; do
        if ! rm -f "$(legacy_init_path "$migration_id")"; then
            restore_legacy "$migration_dir" || error "旧服务恢复未完成，请使用备份 $migration_dir 排查。"
            exit 1
        fi
    done < "$migration_dir/services"
    if write_service && rc-service "$BASE_SERVICE" start && service_ready && rc-update add "$BASE_SERVICE" default; then
        printf '迁移成功，原账号和端口已保留。\n'
        exit 0
    fi
    if ! rc-service "$BASE_SERVICE" stop; then
        error "迁移失败且新服务停止失败，已保留所有配置与备份 $migration_dir，请手动排查。"
        exit 1
    fi
    SERVICE=$BASE_SERVICE
    disable_autostart || { error "无法取消新服务自启，请使用备份 $migration_dir 排查。"; exit 1; }
    restore_legacy "$migration_dir" || error "旧服务恢复未完成，请使用备份 $migration_dir 排查。"
    error '迁移失败，已尝试恢复旧服务。'
    exit 1
)

ensure_backend() {
    build_proxy && ensure_service_user || return 1
    backend_legacy=0
    for backend_id in default $(account_ids); do
        backend_path=$(legacy_init_path "$backend_id")
        [ -f "$backend_path" ] || continue
        if ! grep -F '# fast-s5 backend: 3proxy-v1' "$backend_path" >/dev/null; then backend_legacy=1; fi
    done
    if [ "$backend_legacy" -eq 1 ]; then migrate_legacy; return $?; fi
    if [ -f "$BASE_INIT" ] && [ -f "$RUNTIME" ]; then return 0; fi
    if write_service && apply_runtime start && rc-update add "$BASE_SERVICE" default; then return 0; fi
    error '恢复服务失败，账号配置已保留。'
    if ! rc-service "$BASE_SERVICE" stop; then error '停止失败，已保留服务文件，请手动检查。'; return 1; fi
    SERVICE=$BASE_SERVICE
    disable_autostart || { error '取消自启失败，已保留服务文件。'; return 1; }
    rm -f "$BASE_INIT" "$RUNTIME"
    return 1
}

show_credentials() {
    load_conf || return 1
    test_host=${1:-IP}
    case "$test_host" in *[!a-zA-Z0-9.-]*) error '服务器地址请填写 IPv4 或域名。'; return 1 ;; esac
    printf '\n========== fast-s5 账号信息 ==========\n'
    printf '监听地址：0.0.0.0（所有 IPv4 网卡）\n端口：%s\n用户名：%s\n密码：%s\n' "$PORT" "$USER_NAME" "$PASS"
    printf '连接格式：socks5://%s:%s@%s:%s\n' "$USER_NAME" "$PASS" "$test_host" "$PORT"
    printf '\n在另一台机器上测试：\n'
    printf 'curl -x socks5://%s:%s@%s:%s http://cip.cc\n' "$USER_NAME" "$PASS" "$test_host" "$PORT"
    if [ "$test_host" = IP ]; then
        printf '将 IP 替换为服务器公网地址；或运行 sh fast-s5.sh credentials 服务器IP %s 生成完整命令。\n' "$USER_NAME"
    fi
    printf '请妥善保存凭据；公网使用需开放对应 TCP 端口。\n'
}

install_accounts() {
    if [ -f "$BASE_INIT" ] && grep -F '# fast-s5 backend: 3proxy-v1' "$BASE_INIT" >/dev/null; then
        error '服务已存在，请从菜单添加用户或管理已有账号。'; return 1
    fi
    ensure_network_tools || return 1
    if [ -n "$(account_ids)" ]; then
        printf '将恢复所有保留账号；旧版服务会迁移为支持同端口多用户的共享服务。\n'
        if [ "${1:-}" != random ]; then confirm '确认安装 / 恢复？' || return 0; fi
        ensure_backend
        return $?
    fi
    [ ! -e "$BASE_INIT" ] || { error '存在没有账号记录的服务文件，请先检查或卸载旧服务。'; return 1; }
    account_context default || return 1
    PORT=$(randport) || return 1
    USER_NAME=$(random_credential) && PASS=$(random_credential) || return 1
    if [ "${1:-}" != random ]; then
        read_value "端口 [随机值 $PORT]: " || return 1; PORT=${REPLY:-$PORT}
        read_value "用户名 [随机值 $USER_NAME]: " || return 1; USER_NAME=${REPLY:-$USER_NAME}
        read_secret '密码（回车使用 10 位随机密码，不回显）: ' || return 1; PASS=${REPLY:-$PASS}
    fi
    validate && port_free "$PORT" || return 1
    if [ "${1:-}" != random ]; then confirm '确认安装并设置开机自启？' || return 0; fi
    build_proxy && ensure_service_user && save_conf || return 1
    if write_service && apply_runtime start && rc-update add "$BASE_SERVICE" default; then
        printf '安装成功，已开启开机自启。\n'; show_credentials; return 0
    fi
    error '安装未完成，正在停止服务并清理。'
    if ! rc-service "$BASE_SERVICE" stop; then error '停止失败，已保留管理文件。'; return 1; fi
    SERVICE=$BASE_SERVICE
    disable_autostart || { error '取消自启失败，已保留管理文件。'; return 1; }
    rm -f "$BASE_INIT" "$RUNTIME" "$CONF"
    return 1
}

default_port() {
    for default_id in $(account_ids); do
        default_record=$(account_record "$default_id") || return 1
        printf '%s\n' "${default_record##* }"
        return 0
    done
    return 1
}

add_user() (
    [ -n "$(account_ids)" ] || { error '请先安装 fast-s5。'; exit 1; }
    add_mode=${1:-interactive}
    PORT=${2:-$(default_port)}
    [ -n "$PORT" ] || exit 1
    USER_NAME=$(random_credential) && PASS=$(random_credential) || exit 1
    if [ "$add_mode" != random ]; then
        list_users || exit 1
        read_value "端口 [回车共用 $PORT，r 随机新端口]: " || exit 1
        case "$REPLY" in r|R) ensure_network_tools || exit 1; PORT=$(randport) || exit 1 ;; '') ;; *) PORT=$REPLY ;; esac
        if [ "$add_mode" != quick ]; then
            read_value "用户名 [随机值 $USER_NAME]: " || exit 1; USER_NAME=${REPLY:-$USER_NAME}
            read_secret '密码（回车使用 10 位随机密码，不回显）: ' || exit 1; PASS=${REPLY:-$PASS}
        fi
    fi
    add_attempt=0
    while [ "$add_attempt" -lt 50 ]; do
        add_id=$(randhex 5) || exit 1
        account_context "$add_id" || exit 1
        [ -e "$CONF" ] || break
        add_attempt=$((add_attempt + 1))
    done
    [ "$add_attempt" -lt 50 ] || { error '无法生成唯一账号编号。'; exit 1; }
    validate && validate_unique || exit 1
    if [ "$add_mode" = interactive ]; then confirm '确认添加用户并短暂重启共享服务？' || exit 0; fi
    ensure_network_tools && ensure_backend && port_available "$PORT" || exit 1
    save_conf || exit 1
    if apply_runtime; then
        printf '用户添加成功。\n'; show_credentials; exit 0
    else add_result=$?; fi
    if [ "$add_result" -eq 1 ]; then rm -f "$CONF" || exit 1; fi
    exit 1
)

delete_user() (
    select_account "${1:-}" || { select_result=$?; [ "$select_result" -eq 2 ]; exit $?; }
    load_conf || exit 1
    confirm "确认删除用户 $USER_NAME（端口 $PORT）并短暂重启共享服务？" || exit 0
    ensure_network_tools && ensure_backend || exit 1
    delete_backup=$(mktemp "${CONF}.delete.XXXXXX") || exit 1
    cp -p "$CONF" "$delete_backup" || { rm -f "$delete_backup"; exit 1; }
    rm -f "$CONF" || { rm -f "$delete_backup"; exit 1; }
    if [ -z "$(account_ids)" ]; then
        if rc-service "$BASE_SERVICE" stop && disable_autostart && rm -f "$BASE_INIT" "$RUNTIME"; then
            rm -f "$delete_backup"; printf '最后一个用户已删除，服务已停止。\n'; exit 0
        fi
        mv -f "$delete_backup" "$CONF" || exit 1
        if [ -f "$BASE_INIT" ]; then
            rc-service "$BASE_SERVICE" start || error '恢复账号后，服务启动失败，请查看日志。'
        fi
        error '删除未完成，已保留账号配置，请检查服务状态。'
        exit 1
    fi
    if apply_runtime; then
        rm -f "$delete_backup"; printf '用户 %s 已删除，其余账号继续使用原端口。\n' "$USER_NAME"; exit 0
    fi
    mv -f "$delete_backup" "$CONF" || { error "恢复账号文件失败，请检查 $delete_backup。"; exit 1; }
    error '删除失败，已恢复账号文件。'
    exit 1
)

change_proxy() {
    load_conf || return 1
    old_port=$PORT old_user=$USER_NAME old_pass=$PASS
    read_value '新端口（回车不变，r 随机，可填其他账号的端口）: ' || return 1
    case "$REPLY" in r|R) ensure_network_tools || return 1; PORT=$(randport) || return 1 ;; '') ;; *) PORT=$REPLY ;; esac
    read_value '新用户名（回车不变，r 随机）: ' || return 1
    case "$REPLY" in r|R) USER_NAME=$(random_credential) || return 1 ;; '') ;; *) USER_NAME=$REPLY ;; esac
    read_secret '新密码（回车不变，r 随机，不回显）: ' || return 1
    case "$REPLY" in r|R) PASS=$(random_credential) || return 1 ;; '') ;; *) PASS=$REPLY ;; esac
    validate && validate_unique || return 1
    confirm '确认修改并短暂重启共享服务？' || return 0
    ensure_network_tools && ensure_backend && port_available "$PORT" || return 1
    save_conf || return 1
    if apply_runtime; then printf '修改成功。\n'; show_credentials; return 0; else change_result=$?; fi
    if [ "$change_result" -eq 1 ]; then
        PORT=$old_port USER_NAME=$old_user PASS=$old_pass
        save_conf || { error '恢复账号文件失败，请手动检查。'; return 1; }
    fi
    return 1
}

restart_proxy() {
    ensure_network_tools && ensure_backend && apply_runtime
}

status_proxy() {
    load_conf && ensure_network_tools || return 1
    [ -f "$BASE_INIT" ] || { error '共享服务未安装，请使用 install 恢复。'; return 1; }
    rc-service "$BASE_SERVICE" status || return 1
    printf '用户 %s，TCP 端口 %s；所有用户共享 fast-s5 服务。\n' "$USER_NAME" "$PORT"
    managed_port "$PORT"
}

test_proxy() {
    load_conf || return 1
    command -v curl >/dev/null 2>&1 || apk add --no-cache curl || return 1
    printf '测试本机代理出口（不验证公网端口映射）...\n'
    curl --fail --silent --show-error --noproxy '' --connect-timeout 8 --max-time 20 \
        --proxy "socks5h://127.0.0.1:$PORT" --proxy-user "$USER_NAME:$PASS" https://api.ipify.org || return 1
    printf '\n'
}

logs_proxy() {
    [ -f "$BASE_LOG" ] || { printf '暂无日志。\n'; return 0; }
    printf '共享服务日志（包含所有用户）：\n'
    tail -n 50 "$BASE_LOG"
}

uninstall_proxy() (
    printf '卸载范围：所有 fast-s5 用户。\n1) 删除服务，保留账号配置和程序\n2) 删除服务、账号配置、程序和日志\n0) 返回\n'
    read_value '选择: ' || exit 1
    uninstall_mode=$REPLY
    case "$uninstall_mode" in
        0) exit 0 ;;
        1) confirm '确认移除所有服务并保留账号配置？' || exit 0 ;;
        2) read_value '输入 DELETE 确认完全删除: ' || exit 1; [ "$REPLY" = DELETE ] || exit 0 ;;
        *) error '无效选项。'; exit 1 ;;
    esac
    uninstall_ids=$(account_ids)
    [ -f "$BASE_CONF" ] || uninstall_ids="default $uninstall_ids"
    for uninstall_id in $uninstall_ids; do
        uninstall_path=$(legacy_init_path "$uninstall_id")
        [ -f "$uninstall_path" ] || continue
        SERVICE=$(legacy_service_name "$uninstall_id")
        if ! { rc-service "$SERVICE" stop && disable_autostart && rm -f "$uninstall_path"; }; then
            error '卸载未完成，已保留账号配置及程序，请排查后重试。'; exit 1;
        fi
    done
    rm -f "$RUNTIME" || exit 1
    if [ "$uninstall_mode" = 2 ]; then
        for uninstall_id in $uninstall_ids; do
            account_context "$uninstall_id" || exit 1
            rm -f "$CONF" "${BASE_LOG%.log}.user-$uninstall_id.log" || exit 1
        done
        rm -f "$BIN" "$LEGACY_BIN" "$BASE_LOG" || exit 1
        printf '服务、账号配置、程序和日志已删除；已有迁移备份保留。\n'
    else printf '服务已移除；install 可恢复全部保留账号。\n'; fi
)

usage() {
    cat <<'EOF'
fast-s5 — Alpine Linux / OpenRC SOCKS5 管理器

用法：sh fast-s5.sh [命令]
  menu                    交互菜单（默认）
  install [--random]       安装 / 恢复；旧版服务自动迁移
  users                   列出用户名和端口
  add-user                交互添加用户，可选择已有端口
  add-user --random       共用已有端口，随机生成 10 位账号和密码
  add-user --port 端口     指定端口，随机生成账号和密码
  delete-user [用户]      删除用户，删除前确认
  credentials [IP] [用户] 显示账号和远程 curl 测试命令
  configure [用户]         修改账号 / 端口；失败时尝试回滚
  status [用户]            查看共享服务和账号端口状态
  restart                  重启共享服务，影响所有账号
  test [用户]              测试指定账号的本机代理出口
  logs                     最近 50 行共享服务日志
  uninstall                卸载全部用户（交互确认）
  help, --help, -h          帮助

同一端口可配置多个账号；增删或修改账号会短暂重启共享服务。
账号命令省略用户名时操作首次安装的账号。
EOF
}

check_environment() {
    [ "$(id -u)" -eq 0 ] || { error '请使用 root 运行。'; return 1; }
    [ -f /etc/alpine-release ] || { error '当前仅支持 Alpine Linux。'; return 1; }
    for dependency in apk rc-service rc-update openrc-run; do
        command -v "$dependency" >/dev/null 2>&1 || { error "缺少 $dependency，请在启用 OpenRC 的 Alpine 系统运行。"; return 1; }
    done
    mkdir "$LOCK" 2>/dev/null || { error "管理器正在运行，或留下锁目录 $LOCK；确认无进程后可手动移除。"; return 1; }
    LOCK_HELD=1
    printf '%s\n' "$$" > "$LOCK/pid"
}

show_banner() {
    cat <<'EOF'

  _____         _        ____  ____
 |  ___|_ _ ___| |_      / ___|| ___|
 | |_ / _` / __| __|____ \___ \|___ \
 |  _| (_| \__ \ ||_____| ___) |___) |
 |_|  \__,_|___/\__|    |____/|____/

EOF
}

menu() {
    while :; do
        printf '\n===== fast-s5 · Alpine SOCKS5 管理器 =====\n1) 安装 / 恢复\n2) 查看状态\n3) 查看账号密码和远程测试命令\n4) 修改配置\n5) 重启共享服务\n6) 测试本机代理出口\n7) 查看共享日志\n8) 卸载所有用户\n9) 快速添加用户（可输入端口）\n10) 删除用户\n11) 用户列表\n0) 退出\n'
        read_value '请选择: ' || return 0
        case "$REPLY" in
            1) install_accounts ;; 2) menu_account_action status_proxy ;; 3) menu_account_action show_credentials ;;
            4) menu_account_action change_proxy ;; 5) restart_proxy ;; 6) menu_account_action test_proxy ;;
            7) logs_proxy ;; 8) uninstall_proxy ;; 9) add_user quick ;; 10) delete_user ;; 11) list_users ;; 0) return 0 ;;
            *) error '无效选项。' ;;
        esac || printf '操作未完成，请根据提示处理后重试。\n' >&2
    done
}

main() {
    case "${1:-menu}" in
        help|--help|-h) usage; return 0 ;;
        install)
            if [ "$#" -gt 2 ] || { [ "$#" -eq 2 ] && [ "$2" != --random ]; }; then usage >&2; return 1; fi ;;
        add-user)
            case "$#:${2:-}" in 1:|2:--random) ;; 3:--port) valid_port "$3" || { usage >&2; return 1; } ;; *) usage >&2; return 1 ;; esac ;;
        credentials) [ "$#" -le 3 ] || { usage >&2; return 1; } ;;
        status|configure|test|delete-user) [ "$#" -le 2 ] || { usage >&2; return 1; } ;;
        menu|users|restart|logs|uninstall) [ "$#" -le 1 ] || { usage >&2; return 1; } ;;
        *) usage >&2; return 1 ;;
    esac
    trap cleanup 0
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    check_environment || return 1
    init_account_paths
    show_banner
    case "${1:-menu}" in
        menu) menu ;;
        install) if [ "${2:-}" = --random ]; then install_accounts random; else install_accounts; fi ;;
        add-user) case "${2:-}" in --random) add_user random ;; --port) add_user random "$3" ;; *) add_user ;; esac ;;
        users) list_users ;; delete-user) delete_user "${2:-}" ;;
        credentials) account_action show_credentials "${3:-}" "${2:-}" ;;
        status) account_action status_proxy "${2:-}" ;; configure) account_action change_proxy "${2:-}" ;;
        restart) restart_proxy ;; test) account_action test_proxy "${2:-}" ;;
        logs) logs_proxy ;; uninstall) uninstall_proxy ;;
    esac
}

main "$@"
