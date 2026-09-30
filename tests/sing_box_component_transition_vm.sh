#!/bin/sh
set -eu

# Mutating integration test for an existing VMware OpenWrt VM. Start with a
# running tiny installation. Keeps package/service snapshots and action logs.
[ "${FORKOP_TEST_VM:-}" = 1 ] || { echo 'Set FORKOP_TEST_VM=1 on a test VM' >&2; exit 1; }
ubus call system board | grep -qi VMware || { echo 'VMware VM required' >&2; exit 1; }
work="$(mktemp -d /tmp/forkop-transition-test.XXXXXX)"
lib="${FORKOP_LIB:-/usr/lib/forkop}"
fixture="$(dirname "$0")/fixtures/fail_compressed_start_once.sh"
fail() { echo "FAIL: $* (logs: $work)" >&2; exit 1; }
run() { ucode -L "$lib" "$lib/components/action.uc" component-action sing_box "$1"; }
variant() { ucode -L "$lib" "$lib/singbox/runtime.uc" variant; }
wait_running() {
  for _ in $(seq 1 60); do
    status="$(forkop get_status)"
    if [ "$(printf '%s' "$status" | jsonfilter -e '@.running')" = 1 ] &&
       [ "$(printf '%s' "$status" | jsonfilter -e '@.dns_configured')" = 1 ] &&
       nslookup downloads.openwrt.org 127.0.0.1 >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}
snapshot() {
  if command -v apk >/dev/null; then apk info -v; else opkg list-installed; fi
  ubus call service list
  forkop get_status
  forkop get_sing_box_status
  sing-box version
}
verify_tiny() {
  [ "$(variant)" = tiny ] || fail 'tiny variant was not restored'
  wait_running || fail 'Forkop is not running on tiny'
  [ "$(sing-box version | head -n 1)" = "$baseline" ] || fail 'previous binary version changed'
}

snapshot >"$work/before.txt"
[ "$(variant)" = tiny ] || fail 'baseline must be tiny'
wait_running || fail 'baseline Forkop must be running'
baseline="$(sing-box version | head -n 1)"
cp "$fixture" "$work/fail-start"
chmod 755 "$work/fail-start"

echo 'Testing repeated Stop, tiny -> compressed -> tiny, then failed start rollback on this VM'
/etc/init.d/forkop stop >"$work/stop.txt" 2>&1 || fail 'first Stop failed'
/etc/init.d/forkop stop >>"$work/stop.txt" 2>&1 || fail 'second Stop failed'
/etc/init.d/forkop stop >>"$work/stop.txt" 2>&1 || fail 'third Stop failed'
/etc/init.d/forkop start >"$work/start.txt" 2>&1 || fail 'start after repeated Stop failed'
verify_tiny

snapshot >"$work/before-compressed.txt"
run install_extended_compressed >"$work/compressed.txt" 2>&1 || fail 'compressed transition failed'
[ "$(variant)" = extended-compressed ] || fail 'compressed marker missing'
wait_running || fail 'compressed Forkop is not running'
sing-box check -c /etc/sing-box/config.json >"$work/config-check.txt" 2>&1 || fail 'compressed config invalid'
nslookup example.com 127.0.0.1 >"$work/dns.txt" 2>&1 || fail 'compressed DNS failed'
snapshot >"$work/compressed-state.txt"
run install_tiny >"$work/tiny.txt" 2>&1 || fail 'tiny transition failed'
verify_tiny

snapshot >"$work/before-fault.txt"
if FORKOP_SERVICE_INIT="$work/fail-start" FORKOP_TEST_START_FAILURE_MARKER="$work/fault.marker" \
    run install_extended_compressed >"$work/rollback.txt" 2>&1; then
  fail 'injected startup failure reported success'
fi
[ -e "$work/fault.marker" ] || fail 'startup fault was not injected'
[ "$(tail -n 1 "$work/rollback.txt" | jsonfilter -e '@.success')" = false ] || fail 'rollback did not return structured failure'
grep -q 'previous sing-box variant was restored' "$work/rollback.txt" || fail 'rollback was not confirmed'
verify_tiny
nslookup example.com 127.0.0.1 >"$work/restored-dns.txt" 2>&1 || fail 'restored DNS failed'
snapshot >"$work/after.txt"
logread >"$work/system.log"
echo "VM component transition and rollback checks passed; logs: $work"
