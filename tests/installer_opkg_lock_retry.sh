#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d /tmp/forkop-lock-test.XXXXXX)"
trap 'rm -rf "$work"' EXIT
sed -n '/^opkg_with_lock_retry() (/,/^)/p' "$ROOT/install.sh" > "$work/functions.sh"
. "$work/functions.sh"
opkg() {
    count=$(cat "$work/calls")
    count=$((count + 1))
    echo "$count" > "$work/calls"
    printf '%s\n' "$*" > "$work/args"
    if [ "$count" -le "$failures" ]; then
        printf '%s\n' "$output" >&2
        return 255
    fi
    echo success
}
sleep() { echo wait >> "$work/waits"; }
reset() { echo 0 > "$work/calls"; : > "$work/waits"; }
output='opkg_conf_load: Could not lock /var/lock/opkg.lock: Resource temporarily unavailable.'
failures=2
reset
opkg_with_lock_retry install 'package with spaces.ipk' > "$work/output" 2>&1
[ "$(cat "$work/calls")" = 3 ]
[ "$(wc -l < "$work/waits" | tr -d ' ')" = 2 ]
[ "$(cat "$work/args")" = 'install package with spaces.ipk' ]
grep -q success "$work/output"
failures=100
reset
status=0
opkg_with_lock_retry update > "$work/output" 2>&1 || status=$?
[ "$status" = 255 ]
[ "$(cat "$work/calls")" = 16 ]
[ "$(wc -l < "$work/waits" | tr -d ' ')" = 15 ]
output='postinst failed'
reset
status=0
opkg_with_lock_retry install mock > "$work/output" 2>&1 || status=$?
[ "$status" = 255 ]
[ "$(cat "$work/calls")" = 1 ]
[ ! -s "$work/waits" ]
failures=0
reset
opkg_with_lock_retry remove mock > "$work/output" 2>&1
[ "$(cat "$work/calls")" = 1 ]
[ ! -s "$work/waits" ]
echo 'installer opkg lock retry tests passed'
