#!/bin/sh
set -eu

# OpenWrt regression: a short-lived CLI executable must not strand reload,
# while a persistent extra process must still block ownership authorization.
lib="${FORKOP_LIB:-/usr/lib/forkop}"
work="$(mktemp -d)"
child=""
cleanup() {
    if [ -n "$child" ]; then
        kill "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT
state() { ucode -L "$lib" "$lib/service/state.uc" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
state sing-box-single-owned-service-runtime || fail 'baseline is not owned'
expected="$(state sing-box-service-runtime-pid)"
cp /bin/busybox "$work/sing-box"
ln -s sing-box "$work/busybox"

# Keep a deterministic short-lived executable with the same basename alive
# long enough to overlap the scan, without running a second proxy or listener.
"$work/busybox" sh -c 'sleep 2; exit 0' &
child=$!
[ "$(state sing-box-process-count)" = 2 ] || fail 'transient was not observed'
if state sing-box-process-conflict; then
    fail 'transient CLI process caused a lasting ownership rejection'
fi
wait "$child"
child=""

"$work/busybox" sh -c 'sleep 2; exit 0' &
child=$!
[ "$(state sing-box-process-count)" = 2 ] || fail 'UI transient was not observed'
ucode -L "$lib" "$lib/service/ui.uc" get-ui-state > "$work/ui.json"
wait "$child"
child=""
[ "$(jsonfilter -i "$work/ui.json" -e '@.service.forkop.restart_blocked')" = 0 ] ||
    fail 'LuCI retained the transient restart block'
[ "$(jsonfilter -i "$work/ui.json" -e '@.service.forkop.running')" = 1 ] ||
    fail 'LuCI returned stale stopped state after ownership settled'

"$work/busybox" sh -c 'sleep 30; exit 0' &
child=$!
[ "$(state sing-box-process-count)" = 2 ] || fail 'persistent extra process was not observed'
state sing-box-process-conflict || fail 'persistent extra process was accepted'
kill "$child"
wait "$child" 2>/dev/null || true
child=""
[ "$(state sing-box-service-runtime-pid)" = "$expected" ] || fail 'service PID changed'
state sing-box-single-owned-service-runtime || fail 'baseline did not recover'
echo 'transient and persistent sing-box ownership checks passed'
