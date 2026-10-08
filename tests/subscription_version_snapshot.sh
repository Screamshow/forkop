#!/bin/sh
set -eu
ROOT="${FORKOP_TEST_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
SOURCE="${FORKOP_TEST_SUBSCRIPTION_CACHE:-$ROOT/forkop/files/usr/lib/subscription/cache.uc}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
{
    cat <<'UC'
function as_string(v) { return v == null ? "" : "" + v; }
let calls = 0;
let version = "1.14.2-x-1.0.1";
function get_sing_box_version() { calls++; return version; }
let default_subscription_user_agent = null;
UC
    sed -n '/^function get_subscription_user_agent(/,/^}/p' "$SOURCE"
    cat <<'UC'
if (get_subscription_user_agent("custom/1") != "custom/1" || calls != 0) die("custom UA detection\n");
for (let n = 0; n < 3; n++)
    if (get_subscription_user_agent("") != "sing-box/1.14.2-x-1.0.1") die("default UA\n");
if (calls != 1) die("duplicate detection\n");
default_subscription_user_agent = null;
version = "1.14.2-extended";
if (get_subscription_user_agent("") != "sing-box/1.14.2-extended" || calls != 2) die("new operation\n");
default_subscription_user_agent = null;
version = "";
if (get_subscription_user_agent("") != "sing-box/unknown") die("missing core\n");
version = "1.14.2-x-1.0.1";
if (get_subscription_user_agent("") != "sing-box/1.14.2-x-1.0.1" || calls != 4) die("missing core retry\n");
print("Subscription version snapshot passed\n");
UC
} > "$WORK/check.uc"
ucode "$WORK/check.uc"
for fn in update_subscription_source prepare_subscription_caches subscription_bootstrap_retry_result; do
    sed -n "/^function $fn(/,+1p" "$SOURCE" | grep -q 'default_subscription_user_agent = null' || exit 1
done
