#!/bin/sh

set -eu

URL="http://127.0.0.1/cgi-bin/luci/admin/services/forkop/support-report"
sid=""

cleanup() {
  if [ -n "$sid" ]; then
    ubus call session destroy "{\"ubus_rpc_session\":\"$sid\"}" >/dev/null 2>&1 || true
  fi
  rm -f /tmp/forkop-report-unauth.out /tmp/forkop-report.headers /tmp/forkop-report.txt.gz
}

trap cleanup EXIT

unauth_status="$(curl -sS -o /tmp/forkop-report-unauth.out -w '%{http_code}' "$URL")"
[ "$unauth_status" = "403" ] || {
  echo "expected unauthenticated HTTP 403, got $unauth_status" >&2
  exit 1
}

sid="$(ubus call session create '{"timeout":300}' | jsonfilter -e '@.ubus_rpc_session')"

ubus call session set "{\"ubus_rpc_session\":\"$sid\",\"values\":{\"token\":\"test-token\",\"username\":\"root\"}}" >/dev/null
ubus call session grant "{\"ubus_rpc_session\":\"$sid\",\"scope\":\"access-group\",\"objects\":[[\"luci-app-forkop\",\"read\"]]}" >/dev/null

auth_status="$(curl -sS \
  -D /tmp/forkop-report.headers \
  -o /tmp/forkop-report.txt.gz \
  -b "sysauth_http=$sid" \
  -w '%{http_code}' \
  "$URL")"

[ "$auth_status" = "200" ] || {
  echo "expected authenticated HTTP 200, got $auth_status" >&2
  exit 1
}

grep -qi '^Content-Type: application/gzip' /tmp/forkop-report.headers
grep -qi '^Content-Disposition: attachment; filename="forkop-support-report.txt.gz"' /tmp/forkop-report.headers
gzip -t /tmp/forkop-report.txt.gz
gzip -dc /tmp/forkop-report.txt.gz | grep -q 'CONFIDENTIAL SUPPORT REPORT'

printf 'support report HTTP download passed: %s bytes\n' "$(wc -c </tmp/forkop-report.txt.gz)"
