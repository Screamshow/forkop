#!/bin/sh
# Mutates only the named test VM: remove/reinstall tailscale over the LuCI API.
# Run after capturing package/service state, with the main client stopped/disabled.
set -eu
umask 077
if /etc/init.d/tailscale enabled || pgrep -x tailscaled >/dev/null 2>&1; then
    echo 'refusing test with an enabled or running main Tailscale client'; exit 1
fi
apk info -e tailscale >/dev/null
test_dir=$(mktemp -d /tmp/forkop-support-remove-test.XXXXXX)
apk list --installed > "$test_dir/packages.before"
ubus call service list > "$test_dir/services.before"
sid=$(ubus call session create '{"timeout":180}' | jsonfilter -e '@.ubus_rpc_session')
token=$(cat /proc/sys/kernel/random/uuid)
cleanup() {
    ubus call session destroy "{\"ubus_rpc_session\":\"$sid\"}" >/dev/null
    /etc/init.d/tailscale disable >/dev/null 2>&1 || true
    rm -rf "$test_dir"
}
trap cleanup EXIT
ubus call session set "{\"ubus_rpc_session\":\"$sid\",\"values\":{\"username\":\"root\",\"token\":\"$token\"}}" >/dev/null
ubus call session grant "{\"ubus_rpc_session\":\"$sid\",\"scope\":\"access-group\",\"objects\":[[\"luci-app-forkop\",\"read\"],[\"luci-app-forkop\",\"write\"],[\"luci-base\",\"read\"],[\"luci-base\",\"write\"]]}" >/dev/null
url=http://127.0.0.1/cgi-bin/luci/admin/services/forkop/remote-support
request() {
    curl -s -o "$test_dir/body" -w '%{http_code}' -b "sysauth_http=$sid" -d "$1&token=$token" "$url"
}
wait_idle() {
    count=0
    while :; do
        [ "$(request operation=status)" = 200 ]
        active=$(jsonfilter -i "$test_dir/body" -e '@.data.active')
        [ "$active" = true ] || break
        count=$((count + 1)); [ "$count" -lt 90 ]
        sleep 1
    done
    [ "$(jsonfilter -i "$test_dir/body" -e '@.data.phase')" = stopped ]
}
[ "$(request operation=remove)" = 400 ]
echo 'removal without explicit consent rejected'
/etc/init.d/tailscale enable
[ "$(request operation=status)" = 200 ]
[ "$(jsonfilter -i "$test_dir/body" -e '@.data.removable')" = false ]
[ "$(request 'operation=remove&consent=remove-tailscale-package')" = 400 ]
/etc/init.d/tailscale disable
echo 'enabled main client removal rejected'
[ "$(request 'operation=remove&consent=remove-tailscale-package')" = 200 ]
sleep 1
wait_idle
if apk info -e tailscale >/dev/null 2>&1; then echo 'package still installed'; exit 1; fi
apk list --installed > "$test_dir/packages.removed"
grep -v '^tailscale-' "$test_dir/packages.before" > "$test_dir/packages.expected"
cmp "$test_dir/packages.expected" "$test_dir/packages.removed"
echo 'HTTP removal passed; all other packages preserved'
[ "$(request operation=install)" = 200 ]
sleep 1
wait_idle
apk list --installed > "$test_dir/packages.after"
cmp "$test_dir/packages.before" "$test_dir/packages.after"
if /etc/init.d/tailscale enabled; then echo 'unexpected autostart'; exit 1; fi
echo 'HTTP reinstall passed; exact package baseline restored, autostart disabled'
