#!/bin/sh
set -eu
umask 077
sid=$(ubus call session create '{"timeout":120}' | jsonfilter -e '@.ubus_rpc_session')
token=$(cat /proc/sys/kernel/random/uuid)
trap 'ubus call session destroy "{\"ubus_rpc_session\":\"$sid\"}" >/dev/null; rm -f /tmp/forkop-support-http-test.body' EXIT
ubus call session set "{\"ubus_rpc_session\":\"$sid\",\"values\":{\"username\":\"root\",\"token\":\"$token\"}}" >/dev/null
ubus call session grant "{\"ubus_rpc_session\":\"$sid\",\"scope\":\"access-group\",\"objects\":[[\"luci-app-forkop\",\"read\"],[\"luci-app-forkop\",\"write\"],[\"luci-base\",\"read\"],[\"luci-base\",\"write\"]]}" >/dev/null
url=http://127.0.0.1/cgi-bin/luci/admin/services/forkop/remote-support
code=$(curl -s -o /tmp/forkop-support-http-test.body -w '%{http_code}' -b "sysauth_http=$sid" "$url")
echo "GET status=$code"
[ "$code" = 405 ]
code=$(curl -s -o /tmp/forkop-support-http-test.body -w '%{http_code}' -b "sysauth_http=$sid" -d operation=status "$url")
echo "POST without CSRF status=$code"
[ "$code" = 403 ]
code=$(curl -s -o /tmp/forkop-support-http-test.body -w '%{http_code}' -b "sysauth_http=$sid" -d "operation=status&token=$token" "$url")
echo "Authenticated POST status=$code"
cat /tmp/forkop-support-http-test.body
[ "$code" = 200 ]
[ "$(jsonfilter -i /tmp/forkop-support-http-test.body -e '@.success')" = true ]
code=$(curl -s -o /tmp/forkop-support-http-test.body -w '%{http_code}' -b "sysauth_http=$sid" -d "operation=announce&session_id=wrong-session&token=$token" "$url")
[ "$code" = 200 ]
[ "$(jsonfilter -i /tmp/forkop-support-http-test.body -e '@.data.announcement_granted')" = false ]
echo 'Wrong-session announcement rejected'
# Read-only LuCI sessions must not be able to mutate the support service.
ubus call session revoke "{\"ubus_rpc_session\":\"$sid\",\"scope\":\"access-group\",\"objects\":[[\"luci-app-forkop\",\"write\"]]}" >/dev/null
code=$(curl -s -o /tmp/forkop-support-http-test.body -w '%{http_code}' -b "sysauth_http=$sid" -d "operation=stop&token=$token" "$url")
echo "Read-only mutation status=$code"
[ "$code" = 403 ]
code=$(curl -s -o /tmp/forkop-support-http-test.body -w '%{http_code}' -b "sysauth_http=$sid" -d "operation=announce&session_id=wrong-session&token=$token" "$url")
echo "Read-only announcement status=$code"
[ "$code" = 403 ]
code=$(curl -s -o /tmp/forkop-support-http-test.body -w '%{http_code}' -b "sysauth_http=$sid" -d "operation=remove&consent=remove-tailscale-package&token=$token" "$url")
echo "Read-only removal status=$code"
[ "$code" = 403 ]
