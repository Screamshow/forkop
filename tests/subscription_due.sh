#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
LIB=${FORKOP_LIB:-$ROOT_DIR/forkop/files/usr/lib}
check() {
    expected=$1; shift
    status=0
    ucode -L "$LIB/*.uc" "$LIB/subscription/cache.uc" update-due-status-fixture "$@" || status=$?
    [ "$status" = "$expected" ] || { echo "FAIL: $* expected $expected got $status"; exit 1; }
}
# 0 = due, 1 = wait, 2 = invalid. Last successful refresh is at 100000.
check 0 103599 100000 3600
check 0 114399 100000 14400
check 0 103540 100000 3600
check 1 103539 100000 3600
check 1 110800 100000 14400
check 1 100001 100000 3600
check 1 99999 100000 3600
check 1 100059 100000 60
check 0 100060 100000 60
check 0 103600 100000 3600
check 0 120000 100000 14400
check 0 100000 0 14400
check 0 100000 invalid 14400
check 2 invalid 100000 3600
check 2 100000 100000 0
check 2 100000 100000 invalid
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
printf '100000\n' > "$WORK/timestamp"
cat > "$WORK/fixture.json" <<'EOF'
{"sections":[{".name":"VPN","enabled":"1","action":"connection","subscription_urls":["https://example.invalid/sub"],"subscription_update_enabled":"1"}],"settings":{"update_interval":"4h"}}
EOF
# The default subscription interval is 4h. Its public due-status entry point
# must agree with the cache worker, while list updates remain exact.
status=0
ucode -L "$LIB/*.uc" "$LIB/components/updates.uc" subscription-update-section-due-status-fixture "$WORK/fixture.json" VPN "$WORK/timestamp" 114399 || status=$?
[ "$status" = 0 ] || { echo 'FAIL: default 4h subscription entry point'; exit 1; }
status=0
ucode -L "$LIB/*.uc" "$LIB/components/updates.uc" list-update-due-status-fixture "$WORK/fixture.json" "$WORK/timestamp" 114399 || status=$?
[ "$status" = 1 ] || { echo 'FAIL: unrelated list timing changed'; exit 1; }
echo 'PASS: subscription due boundaries and entry points (18 cases)'
