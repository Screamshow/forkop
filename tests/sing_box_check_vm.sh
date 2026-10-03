#!/bin/sh
# Stateful regression: use only an authorized, already running test VM.
set -eu
LIB=${FORKOP_LIB:-/usr/lib/forkop}
fixture=${1:?Supply a large valid SRS fixture}
work=$(mktemp -d /tmp/forkop-sequential-vm.XXXXXX)
reload_owned=0
reload_lock=${FORKOP_RELOAD_LOCK_DIR:-/var/run/forkop.reload.lock}
state() { ucode -L "$LIB" "$LIB/service/state.uc" "$@"; }
dns() { ucode -L "$LIB" "$LIB/dns/apply.uc" "$@"; }
nft_resume() { ucode -L "$LIB" "$LIB/nft/apply.uc" resume-source-dns-redirect "${NFT_TABLE_NAME:-ForkopTable}"; }
cleanup() {
    [ "$reload_owned" = 0 ] || state release-runtime-dir-lock "$reload_lock"
    dns restore force || true
    if ! state sing-box-current-owned-service-runtime; then
        state start-managed-sing-box-runtime 15 || true
    fi
    dns configure force || true
    dns wait-listener || true
    nft_resume || true
    rm -rf "$work"
}
trap cleanup EXIT
state sing-box-current-owned-service-runtime
if command -v opkg >/dev/null 2>&1; then
    opkg list-installed > "$work/packages.before"
else
    apk info > "$work/packages.before"
fi
ubus call service list > "$work/services.before"
uci export dhcp > "$work/dhcp.before"
kernel_before=$(dmesg | grep -ic 'out of memory\|oom-kill\|killed process' || true)
policy() {
    nft list table inet ForkopTable |
        sed -E 's/counter packets [0-9]+ bytes [0-9]+/counter packets X bytes Y/g' |
        md5sum | cut -d ' ' -f 1
}
policy_before=$(policy)
mkdir "$work/bin"
export TEST_REAL_SING_BOX=$(command -v sing-box)
export TEST_CHECK_LOG="$work/check.log" FORKOP_LIB="$LIB"
export TEST_HOLD_FILE="$work/holding"
cat > "$work/bin/sing-box" <<'SH'
#!/bin/sh
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/service/state.uc" sing-box-process-count > "$TEST_CHECK_LOG"
[ "$(cat "$TEST_CHECK_LOG")" = 0 ] || exit 91
ucode -L "$FORKOP_LIB" "$FORKOP_LIB/dns/apply.uc" independent-of-sing-box || exit 92
nslookup example.com 127.0.0.1 >> "$TEST_CHECK_LOG" 2>&1 || exit 93
if [ "${TEST_HOLD:-0}" = 1 ]; then
    touch "$TEST_HOLD_FILE"
    trap '' TERM
    exec sleep 60
fi
exec "$TEST_REAL_SING_BOX" "$@"
SH
chmod +x "$work/bin/sing-box"
# Reproduce a nested list/config check in an update which already owns reload.
state acquire-runtime-dir-lock "$reload_lock" "$$"
reload_owned=1
PATH="$work/bin:$PATH" sh "$LIB/service/sing-box-check.sh" rule-set match --format binary "$fixture" forkop-validation.invalid
state runtime-dir-lock-owned-by-ancestor "$reload_lock" "$$"
state release-runtime-dir-lock "$reload_lock"
reload_owned=0
state sing-box-current-owned-service-runtime
dns default-config-complete
nslookup example.com 127.0.0.1
printf broken > "$work/bad.srs"
if PATH="$work/bin:$PATH" sh "$LIB/service/sing-box-check.sh" rule-set match --format binary "$work/bad.srs" forkop-validation.invalid; then
    echo 'invalid candidate accepted' >&2; exit 1
fi
state sing-box-current-owned-service-runtime
dns default-config-complete
nslookup example.com 127.0.0.1
# Force only the restoration start to fail; the checker still parses a valid
# candidate. It must report failure and leave native DNS usable.
cat > "$work/init" <<'SH'
#!/bin/sh
[ "$1" != start ] || exit 1
exec /etc/init.d/sing-box "$@"
SH
chmod +x "$work/init"
if FORKOP_SING_BOX_INIT="$work/init" PATH="$work/bin:$PATH" sh "$LIB/service/sing-box-check.sh" rule-set match --format binary "$fixture" forkop-validation.invalid; then
    echo 'candidate accepted despite failed runtime restoration' >&2; exit 1
fi
[ "$(state sing-box-process-count)" = 0 ]
dns independent-of-sing-box
nslookup example.com 127.0.0.1
state start-managed-sing-box-runtime 15
dns configure force
dns wait-listener
nft_resume
state sing-box-current-owned-service-runtime
[ "$(state sing-box-process-count)" = 1 ]
# Hold a checker at its execution boundary. An unrelated start must refuse,
# and interruption must wait for the checker before restoring the runtime.
TEST_HOLD=1 PATH="$work/bin:$PATH" sh "$LIB/service/sing-box-check.sh" rule-set match --format binary "$fixture" forkop-validation.invalid &
helper=$!
while [ ! -f "$TEST_HOLD_FILE" ]; do
    kill -0 "$helper" || exit 1
    sleep 1
done
if state start-managed-sing-box-runtime 1; then
    kill -TERM "$helper"; wait "$helper" || true
    echo 'unrelated start bypassed the checker lock' >&2; exit 1
fi
[ "$(state sing-box-process-count)" = 0 ]
kill -TERM "$helper"
if wait "$helper"; then echo 'interrupted check succeeded' >&2; exit 1; fi
state sing-box-current-owned-service-runtime
dns default-config-complete
# Repeat with no external interruption: the deadline must kill a checker
# which ignores TERM, reject its result and restore the previous dataplane.
timeout_status=0
TEST_HOLD=1 FORKOP_SING_BOX_CHECK_TIMEOUT=2 PATH="$work/bin:$PATH" sh "$LIB/service/sing-box-check.sh" rule-set match --format binary "$fixture" forkop-validation.invalid || timeout_status=$?
[ "$timeout_status" = 124 ]
state single-ready-sing-box-runtime
dns default-config-complete
nslookup example.com 127.0.0.1
[ "$(policy)" = "$policy_before" ]
[ "$(dmesg | grep -ic 'out of memory\|oom-kill\|killed process' || true)" = "$kernel_before" ]
echo 'VM sequential check: native DNS, invalid SRS rollback, failed restart fallback, interruption/timeout recovery, unchanged nftables and no new OOM passed'
