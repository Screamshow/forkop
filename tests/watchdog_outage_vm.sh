#!/bin/sh
set -eu
uci set forkop.settings.download_lists_via_proxy=0
uci commit forkop
/etc/init.d/forkop start
remaining=60
while [ ! -s /var/run/forkop/watchdog.ready ] && [ "$remaining" -gt 0 ]; do
    sleep 1
    remaining=$((remaining - 1))
done
test -s /var/run/forkop/watchdog.ready
FORKOP_WATCHDOG_GRACE_SECONDS=0 FORKOP_WATCHDOG_INTERVAL_SECONDS=1 FORKOP_WATCHDOG_FAILURE_SECONDS=2 \
    ucode -L /usr/lib/forkop /usr/lib/forkop/service/watchdog.uc &
watchdog_pid=$!
trap 'kill "$watchdog_pid" 2>/dev/null || true' EXIT
/etc/init.d/sing-box stop
remaining=20
while [ -s /var/run/forkop/watchdog.ready ] && [ "$remaining" -gt 0 ]; do
    sleep 1
    remaining=$((remaining - 1))
done
test ! -s /var/run/forkop/watchdog.ready
# Wait for the rest of stop_main to finish its dnsmasq restoration.
sleep 6
if uci -q get dhcp.@dnsmasq[0].server | grep -q '127.0.0.42'; then
    echo 'FAIL: dnsmasq still points at stopped sing-box' >&2
    exit 1
fi
echo 'PASS: real runtime outage stops Forkop and restores dnsmasq DNS'
