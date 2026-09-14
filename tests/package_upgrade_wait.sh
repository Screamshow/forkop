#!/bin/sh
set -eu

PACKAGE_UC="${1:-/usr/lib/forkop/service/package.uc}"
FORKOP_INIT="${FORKOP_INIT:-/etc/init.d/forkop}"
WORK_DIR="/root/forkop-package-upgrade-wait-test.$$"
WAS_RUNNING=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

cleanup() {
    pkill -f "$WORK_DIR/sing-box" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
    if [ "$WAS_RUNNING" = 1 ]; then
        "$FORKOP_INIT" start >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

command -v ucode >/dev/null 2>&1 || fail "ucode is required"
[ -f "$PACKAGE_UC" ] || fail "package.uc was not supplied"

if "$FORKOP_INIT" status >/dev/null 2>&1; then
    WAS_RUNNING=1
    "$FORKOP_INIT" stop >/dev/null 2>&1 || fail "unable to stop Forkop test runtime"
    sleep 2
fi

mkdir -p "$WORK_DIR/cache"
cp /usr/bin/ucode "$WORK_DIR/sing-box"
chmod 0755 "$WORK_DIR/sing-box"
cp /etc/config/forkop "$WORK_DIR/forkop.conf"

cat >"$WORK_DIR/init" <<'EOF_INIT'
#!/bin/sh
printf '%s\n' "$1" >>"$FORKOP_TEST_INIT_LOG"
exit 0
EOF_INIT
chmod 0755 "$WORK_DIR/init"

run_postinst() {
    FORKOP_INIT="$WORK_DIR/init" \
    FORKOP_CONFIG_PATH="$WORK_DIR/forkop.conf" \
    FORKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/was-running" \
    FORKOP_PACKAGE_UPGRADE_QUIESCE_FILE="$WORK_DIR/quiesce" \
    FORKOP_COMPONENT_UPDATE_CHECK_CACHE_DIR="$WORK_DIR/cache" \
    FORKOP_COMPONENT_UPDATE_CHECK_STATE_FILE="$WORK_DIR/component-state" \
    FORKOP_TEST_INIT_LOG="$WORK_DIR/init.log" \
    FORKOP_UPGRADE_SING_BOX_WAIT_SECONDS="${1:-15}" \
    ucode -L /usr/lib/forkop "$PACKAGE_UC" postinst
}

# A normal upgrade must wait for the old executable to disappear and then
# perform exactly one start.
touch "$WORK_DIR/was-running" "$WORK_DIR/quiesce"
("$WORK_DIR/sing-box" -e 'system("sleep 3")' &)
started="$(date +%s)"
run_postinst 10 || fail "postinst rejected a normally exiting old sing-box"
elapsed="$(( $(date +%s) - started ))"
[ "$elapsed" -ge 2 ] || fail "postinst did not wait for the old sing-box"
[ "$elapsed" -le 6 ] || fail "postinst wait exceeded the expected bound"
[ "$(grep -c '^start$' "$WORK_DIR/init.log")" = 1 ] || fail "postinst did not start exactly once"
[ ! -e "$WORK_DIR/was-running" ] || fail "successful postinst retained the upgrade marker"
[ ! -e "$WORK_DIR/quiesce" ] || fail "successful postinst retained the quiesce marker"

# A stuck executable must fail closed: do not start a replacement and retain
# the hand-off markers so the failed upgrade remains diagnosable/recoverable.
: >"$WORK_DIR/init.log"
touch "$WORK_DIR/was-running" "$WORK_DIR/quiesce"
("$WORK_DIR/sing-box" -e 'system("sleep 4")' &)
started="$(date +%s)"
if run_postinst 1 >/dev/null 2>&1; then
    fail "postinst accepted a sing-box that exceeded the wait timeout"
fi
elapsed="$(( $(date +%s) - started ))"
[ "$elapsed" -ge 1 ] || fail "timeout path returned before its configured bound"
[ ! -s "$WORK_DIR/init.log" ] || fail "timeout path attempted to start Forkop"
[ -e "$WORK_DIR/was-running" ] || fail "timeout path lost the upgrade marker"
[ -e "$WORK_DIR/quiesce" ] || fail "timeout path lost the quiesce marker"

printf 'package upgrade sing-box wait checks passed\n'
