#!/bin/sh
# Regression tests: all managed paths live in a disposable directory.
# Functions and variables below are used by the dynamically sourced manager.
# shellcheck disable=SC2329,SC2034
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
SANDBOX=$(mktemp -d) || exit 1
trap 'rm -rf "$SANDBOX"' 0
trap 'exit 1' HUP INT TERM
# Load definitions without running the privileged entry point.
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
    ss() { printf '%s\n' "$FAKE_LISTENERS"; return "$FAKE_SS_RESULT"; }
    export CASE_DIR FAKE_START_RESULT FAKE_STOP_RESULT FAKE_RESTART_RESULT FAKE_STATUS_RESULT FAKE_UPDATE_RESULT FAKE_AUTOSTART
    mkdir "$CASE_DIR/bin" || fail 'mock command directory'
    cat > "$CASE_DIR/bin/rc-service" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$1" "$2" >> "$CASE_DIR/service.calls"
case "$2" in
    start) exit "$FAKE_START_RESULT" ;;
    stop) exit "$FAKE_STOP_RESULT" ;;
    restart) exit "$FAKE_RESTART_RESULT" ;;
    status) exit "$FAKE_STATUS_RESULT" ;;
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
}

mock_install() {
    mock_services
    build_proxy() { :; }
    ensure_service_user() { :; }
    randport() { printf '23456\n'; }
    service_ready() { return "${FAKE_READY_RESULT:-0}"; }
}

test_validation() {
    for value in 1024 23456 65535; do assert_ok valid_port "$value"; done
    for value in '' 0 80 65536 999999999999999999999999 02345 +2345 '2;id'; do
        assert_fail valid_port "$value"
    done
    assert_ok valid_user 'user.name_1-2'
    assert_fail valid_user 'user name'
    assert_fail valid_user ''
    assert_ok valid_pass 'Abcdef0123456789_-'
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

test_blank_password_kept() {
    mock_services
    fixture
    : > "$INIT"
    expected=$PASS
    FAKE_LISTENERS='LISTEN 0 128 0.0.0.0:23456 0.0.0.0:*'
    printf '\n\n\ny\n' > "$CASE_DIR/input"
    assert_ok change_proxy < "$CASE_DIR/input"
    assert_ok load_conf
    assert_equal "$PASS" "$expected"
}

test_failed_change_rolls_back() {
    mock_services
    fixture
    : > "$INIT"
    FAKE_RESTART_RESULT=1
    printf '34567\nnew_user\nnew_password_123456\ny\n' > "$CASE_DIR/input"
    assert_fail change_proxy < "$CASE_DIR/input"
    assert_ok load_conf
    assert_equal "$PORT" 23456
    assert_equal "$USER_NAME" test_user
    assert_equal "$PASS" 0123456789abcdef0123456789abcdef
    assert_equal "$(wc -l < "$CASE_DIR/service.calls" | tr -d ' ')" 2
}

test_missing_listener_rolls_back() {
    mock_services
    fixture
    : > "$INIT"
    printf '34567\n\n\ny\n' > "$CASE_DIR/input"
    assert_fail change_proxy < "$CASE_DIR/input"
    assert_ok load_conf
    assert_equal "$PORT" 23456
}

test_input_end_preserves_configuration() {
    mock_services
    fixture
    : > "$INIT"
    cp "$CONF" "$CASE_DIR/original"
    assert_fail change_proxy < /dev/null
    assert_ok cmp "$CONF" "$CASE_DIR/original"
}

test_install_and_restore() {
    mock_install
    assert_ok install_proxy random < /dev/null
    assert_ok test -f "$INIT"
    assert_ok load_conf
    cp "$CONF" "$CASE_DIR/original"
    assert_ok sh -n "$INIT"
    assert_fail install_proxy random < /dev/null
    printf '1\ny\n' > "$CASE_DIR/input"
    assert_ok uninstall_proxy < "$CASE_DIR/input"
    assert_fail test -e "$INIT"
    assert_ok cmp "$CONF" "$CASE_DIR/original"
    assert_ok install_proxy random < /dev/null
    assert_ok cmp "$CONF" "$CASE_DIR/original"
}

test_build_failure_does_not_install() {
    mock_install
    build_proxy() { return 1; }
    assert_fail install_proxy random < /dev/null
    assert_fail test -e "$CONF"
    assert_fail test -e "$INIT"
    assert_fail test -e "$CASE_DIR/service.calls"
}

test_install_failure_cleanup() {
    mock_install
    FAKE_START_RESULT=1
    assert_fail install_proxy random < /dev/null
    assert_fail test -e "$CONF"
    assert_fail test -e "$INIT"
    fixture
    cp "$CONF" "$CASE_DIR/original"
    assert_fail install_proxy random < /dev/null
    assert_ok cmp "$CONF" "$CASE_DIR/original"
    assert_fail test -e "$INIT"
}

test_uninstall_stop_failure_preserves_files() {
    mock_services
    fixture
    : > "$INIT"
    : > "$BIN"
    FAKE_STOP_RESULT=1
    printf '2\nDELETE\n' > "$CASE_DIR/input"
    assert_fail uninstall_proxy < "$CASE_DIR/input"
    assert_ok test -f "$INIT"
    assert_ok test -f "$CONF"
    assert_ok test -f "$BIN"
}

test_uninstall_without_autostart() {
    mock_services
    fixture
    : > "$INIT"
    : > "$BIN"
    : > "$LOG"
    FAKE_AUTOSTART=''
    printf '2\nDELETE\n' > "$CASE_DIR/input"
    assert_ok uninstall_proxy < "$CASE_DIR/input"
    assert_fail test -e "$CONF"
    assert_fail test -e "$INIT"
    assert_fail test -e "$BIN"
    assert_fail test -e "$LOG"
}

test_autostart_failure_does_not_report_success() {
    mock_install
    FAKE_UPDATE_RESULT=1
    assert_fail install_proxy random < /dev/null
    # If autostart cannot be removed either, retain files for manual recovery.
    assert_ok test -f "$CONF"
    assert_ok test -f "$INIT"
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

passed=0
for test_name in validation configuration port_inspection random_free_port \
    blank_password_kept failed_change_rolls_back missing_listener_rolls_back \
    input_end_preserves_configuration install_and_restore build_failure_does_not_install \
    install_failure_cleanup uninstall_stop_failure_preserves_files uninstall_without_autostart \
    autostart_failure_does_not_report_success proxy_error_propagates terminal_editing remote_test_command; do
    CASE_DIR="$SANDBOX/$test_name"
    mkdir "$CASE_DIR" || exit 1
    CONF="$CASE_DIR/fast-s5.conf" INIT="$CASE_DIR/fast-s5.init" BIN="$CASE_DIR/microsocks"
    LOG="$CASE_DIR/fast-s5.log" LOCK="$CASE_DIR/lock"
    if ("test_$test_name") > "$CASE_DIR/output" 2>&1; then
        printf 'PASS: %s\n' "$test_name"
        passed=$((passed + 1))
    else
        cat "$CASE_DIR/output" >&2
        exit 1
    fi
done
printf '%s regression tests passed.\n' "$passed"
