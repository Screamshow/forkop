#!/bin/sh
set -eu
lib=${FORKOP_TEST_LIB:-/usr/lib/forkop}
run() { ucode -L "$lib" "$lib/components/action.uc" "$@"; }
expect_tag() {
    actual=$(run sing-box-previous-release-tag-fixture "$1")
    [ "$actual" = "$2" ] || { echo "Wrong previous release for $1" >&2; exit 1; }
}
expect_tag 1.14.0.2.7.1-r0 v1.14.0-extended-2.7.1
expect_tag 1.14.0.2.7.1-r12 v1.14.0-extended-2.7.1
expect_tag 1.14.0-extended-2.7.1 v1.14.0-extended-2.7.1
expect_tag 1.14.0-extended-2.7.1-1 v1.14.0-extended-2.7.1
expect_tag v1.13.18-extended-2.6.5 v1.13.18-extended-2.6.5
expect_tag 1.14.1-r0 ''
expect_tag 1.14.0.2.7.1-r0/../latest ''
expect_tag 1.14.0-extended-2.7.1-rc1 ''
if [ "${FORKOP_TEST_RESOLVE_PREVIOUS:-0}" = 1 ]; then
    resolved=$(run sing-box-previous-release-fixture 1.14.0.2.7.1-r0)
    [ "$(printf '%s' "$resolved" | jsonfilter -e '@.tag')" = v1.14.0-extended-2.7.1 ]
    printf '%s' "$resolved" | jsonfilter -e '@.asset_name' | grep -q '1.14.0-extended-2.7.1'
fi
echo 'Previous Extended release selection passed'
