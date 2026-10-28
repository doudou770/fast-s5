#!/bin/sh
# All service commands and managed paths are isolated; no root needed.
# Account fixture changes intentionally stay local to each test/subshell.
# shellcheck disable=SC2329,SC2034,SC2030,SC2031
set -u
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
SANDBOX=$(mktemp -d) || exit 1
trap 'rm -rf "$SANDBOX"' 0
trap 'exit 1' HUP INT TERM
sed '/^main "\$@"$/d' "$ROOT/fast-s5.sh" > "$SANDBOX/library.sh" || exit 1
# shellcheck disable=SC1091
. "$SANDBOX/library.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_ok() { "$@" || fail "expected success: $*"; }
assert_fail() { if "$@"; then fail "expected failure: $*"; fi; }
assert_equal() { [ "$1" = "$2" ] || fail "values differ: $1 / $2"; }
fixture() {
    PORT=23456 USER_NAME=test_user PASS=0123456789abcdef0123456789abcdef
    assert_ok save_conf
}
mock_services() {
    FAKE_LISTENERS='' FAKE_SS_RESULT=0 FAKE_START_RESULT=0 FAKE_STOP_RESULT=0
    FAKE_RESTART_RESULT=0 FAKE_STATUS_RESULT=0 FAKE_UPDATE_RESULT=0 FAKE_AUTOSTART='fast-s5 | default'
    FAKE_READY_RESULT=0 FAKE_FAIL_NEW=0
    ss() { printf '%s\n' "$FAKE_LISTENERS"; return "$FAKE_SS_RESULT"; }
    export CASE_DIR INIT FAKE_START_RESULT FAKE_STOP_RESULT FAKE_RESTART_RESULT FAKE_STATUS_RESULT FAKE_UPDATE_RESULT FAKE_AUTOSTART FAKE_FAIL_NEW
    mkdir "$CASE_DIR/bin" || fail 'mock directory'
    cat > "$CASE_DIR/bin/rc-service" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$1" "$2" >> "$CASE_DIR/service.calls"
case "$2" in
    start)
        if [ "$FAKE_FAIL_NEW" = 1 ] && grep -F '3proxy-v1' "$INIT" >/dev/null 2>&1; then exit 1; fi
        if [ "$FAKE_START_RESULT" = 0 ]; then rm -f "$CASE_DIR/$1.stopped"; fi
        exit "$FAKE_START_RESULT" ;;
    stop)
        if [ "$FAKE_STOP_RESULT" = 0 ]; then touch "$CASE_DIR/$1.stopped"; fi
        exit "$FAKE_STOP_RESULT" ;;
    restart) exit "$FAKE_RESTART_RESULT" ;;
    status) [ ! -f "$CASE_DIR/$1.stopped" ] || exit 1; exit "$FAKE_STATUS_RESULT" ;;
    *) exit 1 ;;
esac
EOF
    cat > "$CASE_DIR/bin/rc-update" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CASE_DIR/update.calls"
if [ "$1" = show ]; then printf '%s\n' "$FAKE_AUTOSTART"; fi
exit "$FAKE_UPDATE_RESULT"
EOF
    chmod +x "$CASE_DIR/bin/rc-service" "$CASE_DIR/bin/rc-update" || fail 'mock permissions'
    PATH="$CASE_DIR/bin:$PATH"
    export PATH
    sleep() { :; }
    ensure_network_tools() { :; }
    secure_runtime() { chmod 600 "$1"; }
    build_proxy() { :; }
    ensure_service_user() { :; }
}
mock_install() {
    mock_services
    randport() { printf '23456\n'; }
    service_ready() { return "$FAKE_READY_RESULT"; }
    randhex() { printf '0123456789\n'; }
}
backend_fixture() {
    fixture
    assert_ok write_service
    assert_ok write_runtime
}
extra_fixture() (
    account_context 0123456789 || exit 1
    PORT=${1:-23456} USER_NAME=second_user PASS=Password02
    save_conf
)
test_validation() {
    for value in 1024 23456 65535; do assert_ok valid_port "$value"; done
    for value in '' 0 80 65536 999999999999999999999999 02345 +2345 '2;id'; do
        assert_fail valid_port "$value"
    done
    assert_ok valid_user 'user.name_1-2'
    assert_fail valid_user 'user name'
    assert_fail valid_user ''
    assert_ok valid_pass 'Abcdef0123456789_-'
    assert_ok valid_pass 'Abcd123456'
    assert_fail valid_pass 'Abcd12345'
    assert_fail valid_pass short
    assert_fail valid_pass '0123456789abcdef;id'
    long_value=$(printf '%0130d' 0)
    assert_fail valid_pass "$long_value"
    assert_fail valid_user "$long_value"
}


test_configuration() {
    fixture
    expected=$PASS
    PORT='' USER_NAME='' PASS=''
    assert_ok load_conf
    assert_equal "$PORT" 23456
    assert_equal "$USER_NAME" test_user
    assert_equal "$PASS" "$expected"
    # It must reject shell expressions without executing them.
    # shellcheck disable=SC2016
    printf 'SOCKS_PASS="$(touch %s)"\n' "$CASE_DIR/executed" >> "$CONF"
    assert_fail load_conf
    assert_fail test -e "$CASE_DIR/executed"
    printf 'SOCKS_PORT="23456"\nSOCKS_USER="test_user"\nSOCKS_PASS="0123456789abcdef"' > "$CONF"
    assert_ok load_conf
    assert_equal "$PASS" 0123456789abcdef
    printf 'SOCKS_PORT="23456"\nSOCKS_USER="test_user"\n' > "$CONF"
    assert_fail load_conf
}


test_port_inspection() {
    mock_services
    FAKE_LISTENERS='LISTEN 0 128 0.0.0.0:23456 0.0.0.0:*
LISTEN 0 128 [::]:34567 [::]:*'
    assert_ok port_busy 23456
    assert_ok port_busy 34567
    assert_fail port_busy 3456
    assert_fail port_free 23456
    assert_ok port_free 45678
    FAKE_SS_RESULT=1
    assert_fail port_free 45678
    assert_fail randport
}


test_random_free_port() {
    mock_services
    result=$(randport) || fail 'random port generation'
    assert_ok valid_port "$result"
    assert_ok test "$result" -ge 20000
    assert_ok test "$result" -le 60000
    FAKE_LISTENERS='unused'
    # Simulate every candidate being occupied, then prove retries are bounded.
    port_busy() { return 0; }
    assert_fail randport
}


test_input_end_preserves_configuration() {
    mock_services
    fixture
    : > "$INIT"
    cp "$CONF" "$CASE_DIR/original"
    assert_fail change_proxy < /dev/null
    assert_ok cmp "$CONF" "$CASE_DIR/original"
}


test_proxy_error_propagates() {
    fixture
    curl() {
        printf '%s\n' "$@" > "$CASE_DIR/curl.args"
        return 7
    }
    assert_fail test_proxy
    assert_ok grep -Fx -- '--noproxy' "$CASE_DIR/curl.args"
    assert_ok grep -Fx -- 'socks5h://127.0.0.1:23456' "$CASE_DIR/curl.args"
}


test_terminal_editing() {
    # Exercise the byte reader with both terminal erase conventions.
    stty() {
        printf '%s\n' "$*" >> "$CASE_DIR/stty.calls"
        if [ "$1" = -g ]; then printf 'saved-state\n'; fi
    }
    printf '12x\1773y\0104\n' > "$CASE_DIR/input"
    assert_ok read_terminal no < "$CASE_DIR/input" > "$CASE_DIR/visible"
    assert_equal "$REPLY" 1234
    assert_equal "$TERMINAL_STATE" ''
    printf '0123456789abcdeX\177fY\010\n' > "$CASE_DIR/input"
    assert_ok read_terminal yes < "$CASE_DIR/input" > "$CASE_DIR/hidden"
    assert_equal "$REPLY" 0123456789abcdef
    assert_equal "$(cat "$CASE_DIR/hidden")" ''
    printf 'discard\025keep\n' > "$CASE_DIR/input"
    assert_ok read_terminal no < "$CASE_DIR/input" > /dev/null
    assert_equal "$REPLY" keep
    printf 'ab\033[D\177c\n' > "$CASE_DIR/input"
    assert_ok read_terminal no < "$CASE_DIR/input" > /dev/null
    assert_equal "$REPLY" ac
    printf 'unfinished\004' > "$CASE_DIR/input"
    assert_fail read_terminal yes < "$CASE_DIR/input"
    assert_equal "$TERMINAL_STATE" ''
    assert_equal "$(tail -n 1 "$CASE_DIR/stty.calls")" saved-state
}


test_remote_test_command() {
    fixture
    assert_ok show_credentials 203.0.113.10 > "$CASE_DIR/credentials"
    assert_ok grep -Fx -- 'curl -x socks5://test_user:0123456789abcdef0123456789abcdef@203.0.113.10:23456 http://cip.cc' "$CASE_DIR/credentials"
    assert_ok show_credentials > "$CASE_DIR/credentials"
    assert_ok grep -Fx -- 'curl -x socks5://test_user:0123456789abcdef0123456789abcdef@IP:23456 http://cip.cc' "$CASE_DIR/credentials"
    assert_fail show_credentials 'example.com;id'
}


test_random_credentials() {
    for i in 1 2 3 4 5; do
        value=$(random_credential) || fail random
        assert_equal "${#value}" 10
        case "$value" in *[!a-zA-Z0-9]*) fail 'non-alphanumeric credential' ;; esac
    done
}
test_shared_runtime() {
    mock_install
    backend_fixture
    assert_ok extra_fixture
    account_context abcdef0123 || fail context
    PORT=34567 USER_NAME=third_user PASS=Password03
    assert_ok save_conf
    assert_ok write_runtime
    assert_equal "$(grep -c '^socks ' "$RUNTIME")" 2
    assert_ok grep -Fx 'allow test_user,second_user * * * CONNECT' "$RUNTIME"
    assert_ok grep -Fx 'allow third_user * * * CONNECT' "$RUNTIME"
    assert_equal "$(grep -c '^deny \*$' "$RUNTIME")" 2
    assert_equal "$(grep -c '^socks -u2 ' "$RUNTIME")" 2
    assert_fail grep -F 'second_user' "$BASE_INIT"
    assert_ok sh -n "$BASE_INIT"
}
test_duplicate_user() {
    mock_install
    backend_fixture
    account_context 0123456789 || fail context
    PORT=23456 USER_NAME=test_user PASS=Password02
    assert_fail validate_unique
    assert_ok save_conf
    cp "$RUNTIME" "$CASE_DIR/original"
    assert_fail write_runtime
    assert_ok cmp "$RUNTIME" "$CASE_DIR/original"
}
test_owned_port() {
    mock_services
    backend_fixture
    printf '4242\n' > "$PIDFILE"
    FAKE_LISTENERS='LISTEN 0 128 0.0.0.0:23456 0.0.0.0:* users:(("fast-s5-proxy",pid=4242,fd=3))'
    assert_ok port_available 23456
    assert_ok service_ready
    FAKE_LISTENERS='LISTEN 0 128 0.0.0.0:23456 0.0.0.0:* users:(("other",pid=42420,fd=3))'
    assert_fail port_available 23456
    assert_fail service_ready
    FAKE_SS_RESULT=1
    assert_fail port_available 23456
}
test_quick_add_port() {
    mock_install
    backend_fixture
    printf '34567\n' > "$CASE_DIR/input"
    assert_ok add_user quick < "$CASE_DIR/input"
    assert_ok select_account "$(account_record 0123456789 | cut -d ' ' -f 1)"
    assert_ok load_conf
    assert_equal "$PORT" 34567
    assert_equal "${#USER_NAME}" 10
    assert_equal "${#PASS}" 10
    assert_ok grep -Fx 'fast-s5 restart' "$CASE_DIR/service.calls"
    assert_fail test -e "$BASE_INIT.user-0123456789"
}
test_quick_add_shared() {
    mock_install
    backend_fixture
    printf '\n' > "$CASE_DIR/input"
    assert_ok add_user quick < "$CASE_DIR/input"
    assert_equal "$(account_record 0123456789 | cut -d ' ' -f 2)" 23456
    assert_equal "$(grep -c '^socks ' "$RUNTIME")" 1
}
test_quick_add_random_port() {
    mock_install
    backend_fixture
    randport() { printf '45678\n'; }
    printf 'r\n' > "$CASE_DIR/input"
    assert_ok add_user quick < "$CASE_DIR/input"
    assert_equal "$(account_record 0123456789 | cut -d ' ' -f 2)" 45678
}
test_add_failures() {
    mock_install
    backend_fixture
    cp "$CONF" "$CASE_DIR/original"
    FAKE_LISTENERS='LISTEN 0 128 0.0.0.0:34567 0.0.0.0:* users:(("other",pid=99,fd=3))'
    assert_fail add_user random 34567
    assert_fail test -e "$BASE_CONF.user-0123456789"
    FAKE_LISTENERS='' FAKE_RESTART_RESULT=1
    assert_fail add_user random
    assert_fail test -e "$BASE_CONF.user-0123456789"
    assert_ok cmp "$CONF" "$CASE_DIR/original"
    assert_equal "$(grep -c '^users ' "$RUNTIME")" 1
    FAKE_STOP_RESULT=1
    assert_fail add_user random
    assert_ok test -e "$BASE_CONF.user-0123456789"
    assert_ok grep -Fx '# fast-s5 port 23456' "$RUNTIME"
}
test_change_and_rollback() {
    mock_install
    backend_fixture
    assert_ok extra_fixture 34567
    assert_ok write_runtime
    printf '34567\nrenamed\n\ny\n' > "$CASE_DIR/input"
    assert_ok change_proxy < "$CASE_DIR/input"
    assert_ok load_conf
    assert_equal "$PORT" 34567
    assert_equal "$USER_NAME" renamed
    assert_equal "$PASS" 0123456789abcdef0123456789abcdef
    assert_equal "$(grep -c '^socks ' "$RUNTIME")" 1
    cp "$CONF" "$CASE_DIR/original"
    cp "$RUNTIME" "$CASE_DIR/runtime.original"
    FAKE_RESTART_RESULT=1
    printf '45678\nbad_change\nPassword05\ny\n' > "$CASE_DIR/input"
    assert_fail change_proxy < "$CASE_DIR/input"
    assert_ok cmp "$CONF" "$CASE_DIR/original"
    assert_ok cmp "$RUNTIME" "$CASE_DIR/runtime.original"
}
test_delete_shared_user() {
    mock_install
    backend_fixture
    assert_ok extra_fixture
    assert_ok write_runtime
    printf 'y\n' > "$CASE_DIR/input"
    assert_ok delete_user test_user < "$CASE_DIR/input"
    assert_fail test -e "$BASE_CONF"
    assert_ok test -f "$BASE_CONF.user-0123456789"
    assert_ok grep -Fx 'allow second_user * * * CONNECT' "$RUNTIME"
    assert_ok test -f "$BASE_INIT"
    assert_ok delete_user second_user < "$CASE_DIR/input"
    assert_fail test -e "$BASE_INIT"
    assert_fail test -e "$RUNTIME"
    assert_equal "$(account_ids)" ''
}
test_delete_failure() {
    mock_install
    backend_fixture
    assert_ok extra_fixture
    assert_ok write_runtime
    cp "$CONF" "$CASE_DIR/original"
    cp "$RUNTIME" "$CASE_DIR/runtime.original"
    FAKE_RESTART_RESULT=1
    printf 'y\n' > "$CASE_DIR/input"
    assert_fail delete_user test_user < "$CASE_DIR/input"
    assert_ok cmp "$CONF" "$CASE_DIR/original"
    assert_ok cmp "$RUNTIME" "$CASE_DIR/runtime.original"
}
test_install_and_restore() {
    mock_install
    assert_ok install_accounts random < /dev/null
    assert_ok load_conf
    assert_equal "${#USER_NAME}" 10
    assert_equal "${#PASS}" 10
    original_user=$USER_NAME
    assert_ok extra_fixture
    assert_ok write_runtime
    cp "$CONF" "$CASE_DIR/original"
    assert_fail install_accounts random
    printf '1\ny\n' > "$CASE_DIR/input"
    assert_ok uninstall_proxy < "$CASE_DIR/input"
    assert_fail test -e "$INIT"
    assert_ok install_accounts random
    assert_ok cmp "$CONF" "$CASE_DIR/original"
    assert_equal "$(grep -c '^socks ' "$RUNTIME")" 1
    assert_ok grep -Fx "allow $original_user,second_user * * * CONNECT" "$RUNTIME"
}
test_install_failures() {
    mock_install
    build_proxy() { return 1; }
    assert_fail install_accounts random
    assert_fail test -e "$CONF"
    build_proxy() { :; }
    FAKE_START_RESULT=1
    assert_fail install_accounts random
    assert_fail test -e "$CONF"
    assert_fail test -e "$INIT"
    fixture
    cp "$CONF" "$CASE_DIR/original"
    assert_fail install_accounts random
    assert_ok cmp "$CONF" "$CASE_DIR/original"
    assert_fail test -e "$INIT"
}
test_autostart_failure() {
    mock_install
    FAKE_UPDATE_RESULT=1
    assert_fail install_accounts random
    assert_ok test -f "$CONF"
    assert_ok test -f "$INIT"
}
test_uninstall() {
    mock_install
    backend_fixture
    assert_ok extra_fixture
    : > "$BIN"
    : > "$LEGACY_BIN"
    : > "$LOG"
    FAKE_STOP_RESULT=1
    printf '2\nDELETE\n' > "$CASE_DIR/input"
    assert_fail uninstall_proxy < "$CASE_DIR/input"
    assert_ok test -f "$INIT"
    assert_ok test -f "$CONF"
    assert_ok test -f "$BIN"
    FAKE_STOP_RESULT=0 FAKE_AUTOSTART=''
    assert_ok uninstall_proxy < "$CASE_DIR/input"
    assert_equal "$(account_ids)" ''
    assert_fail test -e "$BIN"
    assert_fail test -e "$RUNTIME"
    assert_fail test -e "$LOG"
}
legacy_fixture() {
    fixture
    assert_ok extra_fixture 34567
    printf '#!/sbin/openrc-run\ncommand="/usr/local/bin/microsocks"\n' > "$INIT"
    cp "$INIT" "$INIT.user-0123456789"
    FAKE_AUTOSTART='fast-s5 | default
fast-s5.user-0123456789 | default'
}
test_migration() {
    mock_install
    legacy_fixture
    cp "$CONF" "$CASE_DIR/original"
    assert_ok ensure_backend
    assert_ok cmp "$CONF" "$CASE_DIR/original"
    assert_ok grep -F '3proxy-v1' "$INIT"
    assert_fail test -e "$INIT.user-0123456789"
    assert_ok grep -Fx 'fast-s5.user-0123456789 stop' "$CASE_DIR/service.calls"
    assert_equal "$(grep -c '^socks ' "$RUNTIME")" 2
    backup=$(echo "$CASE_DIR"/runtime/migration.*)
    assert_ok cmp "$backup/default.conf" "$CONF"
    assert_ok grep -F 'microsocks' "$backup/0123456789.init"
}
test_migration_rollback() {
    mock_install
    legacy_fixture
    FAKE_FAIL_NEW=1
    cp "$INIT" "$CASE_DIR/init.original"
    cp "$CONF" "$CASE_DIR/original"
    assert_fail ensure_backend
    assert_ok cmp "$INIT" "$CASE_DIR/init.original"
    assert_ok cmp "$INIT.user-0123456789" "$CASE_DIR/init.original"
    assert_ok cmp "$CONF" "$CASE_DIR/original"
    assert_fail test -e "$RUNTIME"
    assert_ok grep -Fx 'add fast-s5.user-0123456789 default' "$CASE_DIR/update.calls"
    assert_ok grep -Fx 'fast-s5.user-0123456789 start' "$CASE_DIR/service.calls"
}
test_unknown_service() {
    mock_install
    fixture
    printf '#!/bin/sh\n# foreign service\n' > "$INIT"
    cp "$INIT" "$CASE_DIR/original"
    assert_fail ensure_backend
    assert_ok cmp "$INIT" "$CASE_DIR/original"
    rm "$CONF"
    assert_fail install_accounts random
    assert_ok cmp "$INIT" "$CASE_DIR/original"
}
mock_build_commands() {
    FAKE_BUILD_RESULT=0 FAKE_BUILD_ARTIFACT=1 FAKE_BUILD_COMMIT=$PROXY_COMMIT
    apk() { printf 'mock dependencies\n'; }
    git() {
        if [ "$1" = clone ]; then
            for mock_arg do source_path=$mock_arg; done
            mkdir -p "$source_path/src" "$source_path/bin" || return 1
            printf '# Linux build settings\n' > "$source_path/Makefile.Linux"
        else
            printf '%s\n' "$FAKE_BUILD_COMMIT"
        fi
    }
    make() {
        printf '%s\n' "$*" > "$CASE_DIR/make.args"
        printf 'upstream.c: warning: sample warning\n' >&2
        if [ "$FAKE_BUILD_RESULT" -ne 0 ]; then
            printf 'upstream.c: error: sample build failure\n' >&2
            return "$FAKE_BUILD_RESULT"
        fi
        if [ "$FAKE_BUILD_ARTIFACT" -eq 1 ]; then
            printf '#!/bin/sh\nexit 0\n' > "$2/../bin/3proxy"
            chmod +x "$2/../bin/3proxy" || return 1
        fi
    }
}
test_build_warning_and_reuse() {
    mock_build_commands
    assert_ok build_proxy > "$CASE_DIR/build.output" 2>&1
    assert_ok test -x "$BIN"
    assert_ok grep -F 'warning: sample warning' "$BUILD_LOG"
    assert_fail grep -F 'warning: sample warning' "$CASE_DIR/build.output"
    assert_ok grep -F '代理程序构建完成' "$CASE_DIR/build.output"
    assert_ok grep -F '../bin/3proxy PLUGINS=' "$CASE_DIR/make.args"
    cp "$BUILD_LOG" "$CASE_DIR/build.original"
    apk() { fail 'reused binary must not build'; }
    assert_ok build_proxy
    assert_ok cmp "$BUILD_LOG" "$CASE_DIR/build.original"
}
test_build_failure_reporting() {
    mock_build_commands
    FAKE_BUILD_RESULT=2
    assert_fail build_proxy > "$CASE_DIR/build.output" 2>&1
    assert_fail test -e "$BIN"
    assert_ok grep -F 'error: sample build failure' "$BUILD_LOG"
    assert_ok grep -F 'error: sample build failure' "$CASE_DIR/build.output"
    assert_ok grep -F "$BUILD_LOG" "$CASE_DIR/build.output"
    assert_fail grep -F '代理程序构建完成' "$CASE_DIR/build.output"
    FAKE_BUILD_RESULT=0 FAKE_BUILD_ARTIFACT=0
    assert_fail build_proxy > "$CASE_DIR/build.output" 2>&1
    assert_fail test -e "$BIN"
    assert_ok grep -F '编译未生成可执行程序' "$CASE_DIR/build.output"
    FAKE_BUILD_COMMIT=wrong_commit
    rm -f "$CASE_DIR/make.args"
    assert_fail build_proxy > "$CASE_DIR/build.output" 2>&1
    assert_ok grep -F '源码版本校验失败' "$CASE_DIR/build.output"
    assert_fail test -e "$CASE_DIR/make.args"
}
test_menu_and_cli() {
    check_environment() { :; }
    add_user() { printf 'add %s %s\n' "$1" "${2:-}" >> "$CASE_DIR/menu.calls"; }
    delete_user() { printf 'delete\n' >> "$CASE_DIR/menu.calls"; }
    list_users() { printf 'list\n' >> "$CASE_DIR/menu.calls"; }
    printf '9\n10\n11\n0\n' > "$CASE_DIR/input"
    assert_ok main menu < "$CASE_DIR/input" > "$CASE_DIR/menu.output"
    assert_equal "$(cat "$CASE_DIR/menu.calls")" "$(printf 'add quick \ndelete\nlist')"
    assert_equal "$(grep -Fc '_____         _' "$CASE_DIR/menu.output")" 1
    assert_equal "$(grep -Fc '===== fast-s5 · Alpine SOCKS5 管理器 =====' "$CASE_DIR/menu.output")" 4
    assert_ok main add-user --port 23456 > /dev/null
    assert_ok grep -Fx 'add random 23456' "$CASE_DIR/menu.calls"
    assert_fail main add-user --port 80
}
passed=0
for test_name in validation configuration port_inspection random_free_port \
    input_end_preserves_configuration proxy_error_propagates terminal_editing remote_test_command \
    random_credentials shared_runtime duplicate_user owned_port quick_add_port quick_add_shared \
    quick_add_random_port add_failures change_and_rollback delete_shared_user delete_failure \
    install_and_restore install_failures autostart_failure uninstall migration migration_rollback \
    unknown_service build_warning_and_reuse build_failure_reporting menu_and_cli; do
    CASE_DIR="$SANDBOX/$test_name"
    mkdir "$CASE_DIR" || exit 1
    CONF="$CASE_DIR/fast-s5.conf" INIT="$CASE_DIR/fast-s5.init" BIN="$CASE_DIR/fast-s5-proxy"
    RUNTIME="$CASE_DIR/runtime/3proxy.cfg" PIDFILE="$CASE_DIR/fast-s5.pid"
    LEGACY_BIN="$CASE_DIR/microsocks" LOG="$CASE_DIR/fast-s5.log" LOCK="$CASE_DIR/lock"
    BUILD_LOG="$CASE_DIR/build.log"
    init_account_paths
    if ("test_$test_name") > "$CASE_DIR/output" 2>&1; then
        printf 'PASS: %s\n' "$test_name"
        passed=$((passed + 1))
    else
        cat "$CASE_DIR/output" >&2
        exit 1
    fi
done
printf '%s regression tests passed.\n' "$passed"
