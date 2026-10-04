#!/bin/sh
# Integration test on an explicitly prepared, backed-up OpenWrt VM only.
set -eu
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
wait_ready() {
    remaining=90
    while [ "$remaining" -gt 0 ]; do
        [ ! -s /var/run/forkop/watchdog.ready ] || return 0
        sleep 1
        remaining=$((remaining - 1))
    done
    return 1
}
/etc/init.d/forkop stop
if [ "${FORKOP_TEST_INSTALLED:-0}" != 1 ]; then
cp -R "$ROOT_DIR/forkop/files/usr/lib/." /usr/lib/forkop/
cp "$ROOT_DIR/forkop/files/usr/bin/forkop" /usr/bin/forkop
cp "$ROOT_DIR/forkop/files/etc/init.d/forkop" /etc/init.d/forkop
chmod +x /usr/bin/forkop /etc/init.d/forkop
sed -i 's/__COMPILED_VERSION_VARIABLE__/1.16.1/g' /usr/lib/forkop/core/constants.uc
fi
cp "$ROOT_DIR/forkop/files/etc/config/forkop" /etc/config/forkop
uci set forkop.settings.dns_server='1.1.1.1'
uci set forkop.settings.bootstrap_dns_server='1.1.1.1'
uci set forkop.settings.component_update_check_enabled='0'
uci set forkop.settings.enable_yacd='0'
uci set forkop.voice=section
uci set forkop.voice.enabled='1'
uci set forkop.voice.action='connection'
test_outbound=${FORKOP_TEST_OUTBOUND:-}
[ -n "$test_outbound" ] || test_outbound='{"type":"direct","tag":"test-direct"}'
uci add_list forkop.voice.outbound_jsons="$test_outbound"
if [ "${FORKOP_TEST_PROXY:-0}" = 1 ]; then
    uci set forkop.settings.download_lists_via_proxy='1'
    uci set forkop.settings.download_lists_via_proxy_section='voice'
fi
uci add_list forkop.voice.community_lists='discord'
uci commit forkop
# Clear only the VM test's list caches to model a fresh installation.
rm -rf /etc/forkop/list-cache /tmp/sing-box/list-generation /tmp/sing-box/rulesets
export FORKOP_WATCHDOG_INTERVAL_SECONDS=1 FORKOP_WATCHDOG_GRACE_SECONDS=0 FORKOP_WATCHDOG_FAILURE_SECONDS=2
echo 'CASE: clean install with Discord, standard downloader'
ucode -L /usr/lib/forkop /usr/lib/forkop/service/initd.uc start-service test "$$" || fail 'cold start failed'
wait_ready || fail 'cold start did not become ready'
test -s /tmp/sing-box/rulesets/voice-community-subnets-lists-ruleset.json || fail 'Discord not materialized'
test -s /etc/forkop/list-cache/manifest.json || fail 'persistent cache missing'
test -s /var/run/forkop/watchdog.ready || fail 'watchdog not armed'
test -z "$(find /var/run/forkop -maxdepth 1 -name 'list-download-transport.*')" || fail 'temporary connection leaked'
pidof sing-box >/dev/null || fail 'sing-box not running'
nslookup example.com 127.0.0.42 >/dev/null || fail 'DNS failed'
echo 'PASS: cold start downloaded Discord and DNS works'
echo 'CASE: cached restart without list network access'
/etc/init.d/forkop stop
mkdir -p "$ROOT_DIR/test-bin"
real_curl="$(command -v curl)"
# Variables below belong to the generated curl wrapper.
# shellcheck disable=SC2016
printf '#!/bin/sh\nfor arg do\n case "$arg" in https://*) exit 99;; esac\ndone\nexec "%s" "$@"\n' "$real_curl" > "$ROOT_DIR/test-bin/curl"
chmod +x "$ROOT_DIR/test-bin/curl"
original_path="$PATH"
export PATH="$ROOT_DIR/test-bin:$PATH"
ucode -L /usr/lib/forkop /usr/lib/forkop/service/initd.uc start-service test "$$" || fail 'cached offline start failed'
wait_ready || fail 'cached runtime did not become ready'
pidof sing-box >/dev/null || fail 'cached runtime missing'
echo 'PASS: cached start does not require downloads'
/etc/init.d/forkop stop
echo 'CASE: clean start with unavailable list source'
rm -rf /etc/forkop/list-cache /tmp/sing-box/list-generation /tmp/sing-box/rulesets
printf 'sing_box_config\n' > /var/run/forkop/start.failure
if ucode -L /usr/lib/forkop /usr/lib/forkop/service/initd.uc start-service test "$$"; then fail 'missing lists accepted'; fi
test ! -e /var/run/forkop/watchdog.ready || fail 'watchdog armed after failure'
test -z "$(find /var/run/forkop -maxdepth 1 -name 'list-download-transport.*')" || fail 'failed connection leaked'
test ! -e /var/run/forkop/start.failure || fail 'network error retained a stale permanent failure'
ucode -L /usr/lib/forkop /usr/lib/forkop/service/initd.uc cancel-scheduled-start-retry
before_watchdog_errors="$(logread -e forkop | grep -c 'sing-box remained unavailable' || true)"
ucode -L /usr/lib/forkop /usr/lib/forkop/service/watchdog.uc &
watchdog_pid=$!
sleep 5
kill "$watchdog_pid"
after_watchdog_errors="$(logread -e forkop | grep -c 'sing-box remained unavailable' || true)"
[ "$before_watchdog_errors" = "$after_watchdog_errors" ] || fail 'watchdog reported an outage after failed start'
echo 'PASS: failed download stops before config; watchdog remains unarmed'
export PATH="$original_path"
echo 'CASE: recovery after network restoration'
ucode -L /usr/lib/forkop /usr/lib/forkop/service/initd.uc start-service test "$$" || fail 'recovery failed'
wait_ready || fail 'recovery did not become ready'
test -s /var/run/forkop/watchdog.ready || fail 'watchdog did not re-arm'
pidof sing-box >/dev/null || fail 'recovered runtime missing'
echo 'PASS: recovery without editing section settings'
echo 'CASE: restart and incomplete-runtime reload re-arm watchdog'
forkop restart
test -s /var/run/forkop/watchdog.ready || fail 'restart left watchdog unarmed'
/etc/init.d/sing-box stop
forkop reload
test -s /var/run/forkop/watchdog.ready || fail 'reload recovery left watchdog unarmed'
echo 'PASS: restart and reload recovery keep watchdog armed'
echo 'CASE: watchdog still restores DNS after a real runtime outage'
ucode -L /usr/lib/forkop /usr/lib/forkop/service/watchdog.uc &
outage_watchdog_pid=$!
/etc/init.d/sing-box stop
remaining=30
while [ -s /var/run/forkop/watchdog.ready ] && [ "$remaining" -gt 0 ]; do
    sleep 1
    remaining=$((remaining - 1))
done
test ! -s /var/run/forkop/watchdog.ready || fail 'watchdog did not stop failed runtime'
kill "$outage_watchdog_pid"
echo 'PASS: watchdog handles a real outage after successful start'
