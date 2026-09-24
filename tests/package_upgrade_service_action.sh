#!/bin/sh
set -eu

if [ "${1:-}" = "--fake-apk-ancestor" ]; then
    printf apk > /proc/self/comm
    owner=$$
    sh -c 'set -e; ucode -L "$FORKOP_LIB" "$FORKOP_TEST_PACKAGE_UC" prerm upgrade; :'
    [ "$(cat "$FORKOP_PACKAGE_UPGRADE_QUIESCE_FILE")" = "$owner" ]
    exit $?
fi

root_dir=$(cd "$(dirname "$0")/.." && pwd)
lib_dir="$root_dir/forkop/files/usr/lib"
ui_uc=${FORKOP_TEST_UI_UC:-$lib_dir/service/ui.uc}
package_uc=${FORKOP_TEST_PACKAGE_UC:-$lib_dir/service/package.uc}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export FORKOP_UI_STATE_DIR="$work/ui-state"
export FORKOP_UI_SERVICE_ACTION_DIR="$work/ui-state/service-actions"
export FORKOP_UI_SERVICE_ACTION_LOCK_DIR="$work/ui-state/service-actions.lock"
export FORKOP_UI_LATENCY_ACTION_DIR="$work/ui-state/latency-actions"
export FORKOP_UI_COMPONENT_ACTION_DIR="$work/ui-state/component-actions"
export FORKOP_UI_SUBSCRIPTION_ACTION_DIR="$work/ui-state/subscription-actions"
export FORKOP_PACKAGE_UPGRADE_QUIESCE_FILE="$work/package-upgrade.quiesce"
export FORKOP_PACKAGE_UPGRADE_STATE="$work/package-was-running"
export FORKOP_LIB=${FORKOP_TEST_LIB_DIR:-$lib_dir}
export FORKOP_TEST_PACKAGE_UC="$package_uc"
export FORKOP_INIT=/bin/true
export FORKOP_RT_TABLES="$work/rt_tables"
export FORKOP_PACKAGE_TEST_MODE=1
export FORKOP_UPGRADE_RESTORE_WAIT_SECONDS=1

ui() { ucode -L "$FORKOP_LIB" "$ui_uc" "$@"; }
pkg() { ucode -L "$FORKOP_LIB" "$package_uc" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

printf '100 forkop\n' > "$work/rt_tables"
job=$(ui service-action-begin-if-idle start test) || fail 'could not create active start'
[ -n "$job" ] || fail 'missing job id'
if pkg prerm upgrade >/dev/null 2>&1; then
    fail 'prerm should time out while start is active'
fi
[ ! -e "$FORKOP_PACKAGE_UPGRADE_QUIESCE_FILE" ] || fail 'quiesce marker remained after timeout'
[ ! -e "$FORKOP_PACKAGE_UPGRADE_STATE" ] || fail 'restore marker remained after timeout'
ui service-action-finish "$job" true done 0 >/dev/null || fail 'could not finish action'
ui begin-package-upgrade-quiesce "$$" >/dev/null || fail 'updater could not claim transition'
if ui service-action-begin-if-idle reload test >/dev/null 2>&1; then
    fail 'service action was allowed after upgrade transition claim'
fi
pkg prerm upgrade >/dev/null 2>&1 || fail 'prerm should proceed after start finishes'
[ "$(cat "$FORKOP_PACKAGE_UPGRADE_QUIESCE_FILE")" = "$$" ] || fail 'package hook did not take ownership'
[ -e "$FORKOP_PACKAGE_UPGRADE_STATE" ] || fail 'package hook did not capture running state after the action finished'
if ui service-action-begin-if-idle restart test >/dev/null 2>&1; then
    fail 'service action was allowed while package hook owns transition'
fi
sh "$0" --fake-apk-ancestor || fail 'package hook did not select the apk ancestor as transition owner'
echo 'PASS: package upgrade waits for active service action and blocks concurrent starts'
