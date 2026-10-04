#!/bin/sh
set -eu
lib=/usr/lib/forkop
dir=/root/forkop1161-test/cancel-fixture
mkdir -p "$dir/bin"
fail() { echo "FAIL: $*" >&2; exit 1; }
clean() {
    for name in sleep.pid curl.pid; do
        [ ! -s "$dir/$name" ] || kill "$(cat "$dir/$name")" 2>/dev/null || true
    done
    [ -z "${updater:-}" ] || kill "$updater" 2>/dev/null || true
}
trap clean EXIT
/etc/init.d/forkop stop
cat > "$dir/bin/curl" <<'CURL'
#!/bin/sh
echo "$$" > /root/forkop1161-test/cancel-fixture/curl.pid
sleep 300 &
echo "$!" > /root/forkop1161-test/cancel-fixture/sleep.pid
wait
CURL
chmod +x "$dir/bin/curl"
rm -f "$dir/curl.pid" "$dir/sleep.pid"
rm -rf /etc/forkop/list-cache /tmp/sing-box/list-generation /tmp/sing-box/rulesets
echo 'CASE: cancel an actual list updater while it uses the managed preparation runtime'
PATH="$dir/bin:$PATH" ucode -L "$lib" "$lib/service/initd.uc" start-service test "$$" >/dev/null 2>&1 &
updater=$!
remaining=30
while [ ! -s "$dir/curl.pid" ] && [ "$remaining" -gt 0 ]; do sleep 1; remaining=$((remaining - 1)); done
test -s "$dir/curl.pid" || fail 'updater did not reach a download'
ucode -L "$lib" "$lib/service/state.uc" sing-box-current-owned-service-runtime || fail 'managed preparation runtime was not started'
test ! -e /var/run/forkop/watchdog.ready || fail 'partial runtime was declared ready'
ucode -L "$lib" "$lib/components/updates.uc" stop-list-update
wait "$updater" 2>/dev/null || true
ucode -L "$lib" "$lib/service/initd.uc" cancel-scheduled-start-retry
test ! -e /var/run/forkop_list_update.pid || fail 'updater PID left behind'
test ! -e /var/run/forkop/watchdog.ready || fail 'cancelled startup became ready'
pidof sing-box >/dev/null && fail 'cancelled updater left sing-box alive'
echo 'PASS: actual updater cancelled and its managed preparation runtime removed'
