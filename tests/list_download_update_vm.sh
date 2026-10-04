#!/bin/sh
set -eu
peer=$1
lib=/usr/lib/forkop
fail() { echo "FAIL: $*" >&2; exit 1; }
backup=/root/forkop1161-test/update-config.backup
cp /etc/config/forkop "$backup"
trap 'cp "$backup" /etc/config/forkop; uci revert forkop || true' EXIT
/etc/init.d/forkop stop
uci -q delete forkop.voice.community_lists || true
uci add_list forkop.voice.remote_domain_lists="http://$peer:19091/domains.txt"
uci add_list forkop.voice.remote_subnet_lists="http://$peer:19091/subnets.txt"
uci commit forkop

echo 'CASE: lifecycle downloads domain and subnet lists through managed selected section'
ucode -L "$lib" "$lib/service/initd.uc" start-service test "$$" || fail 'managed cold start failed'
grep -q 'example.com' /tmp/sing-box/rulesets/voice-remote-domains-ruleset.json || fail 'domain list not imported'
grep -q '203.0.113.0/24' /tmp/sing-box/rulesets/voice-remote-subnets-ruleset.json || fail 'subnet list not imported'
test "$(uci get forkop.settings.download_lists_via_proxy)" = 1 || fail 'download setting changed'
test -z "$(find /var/run/forkop -maxdepth 1 -name 'list-download-transport.*')" || fail 'transport leaked'
cp /etc/forkop/list-cache/manifest.json /root/forkop1161-test/manifest-good.json
echo 'PASS: both list types downloaded via selected connection; settings preserved'
echo 'CASE: existing managed runtime serves regular list updates'
/etc/init.d/forkop start
remaining=90
while [ ! -s /var/run/forkop/watchdog.ready ] && [ "$remaining" -gt 0 ]; do sleep 1; remaining=$((remaining - 1)); done
test -s /var/run/forkop/watchdog.ready || fail 'custom-list startup failed'
runtime_pid=$(pidof sing-box)
ucode -L "$lib" "$lib/components/updates.uc" list-update || fail 'running-runtime update failed'
test "$runtime_pid" = "$(pidof sing-box)" || fail 'unchanged list update replaced runtime'
test -z "$(find /var/run/forkop -maxdepth 1 -name 'list-download-transport.*')" || fail 'second transport leaked'
echo 'PASS: healthy runtime reused, unchanged generation does not restart it'
echo 'CASE: failing source preserves the committed generation'
uci add_list forkop.voice.remote_domain_lists="http://$peer:19091/missing.txt"
uci commit forkop
if FORKOP_LIST_UPDATE_PREPARE_ONLY=1 ucode -L "$lib" "$lib/components/updates.uc" list-update; then fail 'missing source accepted'; fi
cmp /etc/forkop/list-cache/manifest.json /root/forkop1161-test/manifest-good.json || fail 'good cache replaced on failure'
grep -q 'example.com' /tmp/sing-box/rulesets/voice-remote-domains-ruleset.json || fail 'active generation lost'
test -z "$(find /var/run/forkop -maxdepth 1 -name 'list-download-transport.*')" || fail 'failed transport leaked'
echo 'PASS: failure preserves last-known-good cache and cleans transport'
