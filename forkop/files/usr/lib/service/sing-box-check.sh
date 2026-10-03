#!/bin/sh
# Run a memory-heavy sing-box command without the managed runtime beside it.
# Downloads and publication stay with the caller; this only lends it the RAM.
LIB=${FORKOP_LIB:-/usr/lib/forkop}
STATE=${FORKOP_STATE_UC:-$LIB/service/state.uc}
DNS=${FORKOP_DNS_APPLY_UC:-$LIB/dns/apply.uc}
NFT=${FORKOP_NFT_APPLY_UC:-$LIB/nft/apply.uc}
NFT_TABLE=${NFT_TABLE_NAME:-ForkopTable}
RELOAD_LOCK=${FORKOP_RELOAD_LOCK_DIR:-/var/run/forkop.reload.lock}
CHECK_LOCK=${FORKOP_SING_BOX_CHECK_LOCK_DIR:-/var/run/forkop.sing-box-check.lock}
CONFIG=${FORKOP_CONFIG_NAME:-forkop}
CHECK_TIMEOUT=${FORKOP_SING_BOX_CHECK_TIMEOUT:-60}
case "$CHECK_TIMEOUT" in
    ''|*[!0-9]*) exit 1 ;;
esac
[ "$CHECK_TIMEOUT" -gt 0 ] || exit 1
state() {
    case "$1" in
        sing-box-process-count) ucode -L "$LIB" "$STATE" "$@" ;;
        *) ucode -L "$LIB" "$STATE" "$@" >/dev/null 2>&1 ;;
    esac
}
# stdout belongs to the checker (notably diagnostics tools fetch). Init
# scripts may print DHCP probes when restarting DNS; do not mix these in.
dns() { ucode -L "$LIB" "$DNS" "$@" >/dev/null 2>&1; }
nft_dns() { ucode -L "$LIB" "$NFT" "$1" "$NFT_TABLE" >/dev/null 2>&1; }
log() { logger -t forkop "[warn] sing-box check: $*"; }
reload_owned=0
check_owned=0
resume=0
restore_dns=0
dns_redirect_paused=0
child=
timer=
shutdown_before=$(uci -q get "$CONFIG.settings.shutdown_correctly")

start_timer() {
    owner=$$
    (
        # Use only /bin/sh and sleep; OpenWrt need not ship timeout.
        trap - EXIT HUP INT TERM USR1
        sleeper=
        trap 'kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null; exit 0' HUP INT TERM
        sleep "$CHECK_TIMEOUT" & sleeper=$!
        wait "$sleeper" || exit 0
        kill -USR1 "$owner" 2>/dev/null
    ) &
    timer=$!
}

runtime_ready() {
    remaining=15
    while ! state single-ready-sing-box-runtime; do
        [ "$remaining" -gt 0 ] || return 1
        sleep 1
        remaining=$((remaining - 1))
    done
}

restore_runtime_dns() {
    runtime_ready || return 1
    if [ "$restore_dns" = 1 ]; then
        dns configure force && dns wait-listener || return 1
    fi
    [ "$dns_redirect_paused" = 0 ] || nft_dns resume-source-dns-redirect
}

keep_native_dns() {
    dns restore force
    dns wait-listener
    [ "$dns_redirect_paused" = 0 ] || nft_dns pause-source-dns-redirect
}

cleanup() {
    result=$?
    trap - EXIT
    trap '' HUP INT TERM USR1
    if [ -n "$timer" ]; then
        kill "$timer" 2>/dev/null
        wait "$timer" 2>/dev/null
    fi
    # Never restart the runtime before the checker has actually exited.
    if [ -n "$child" ]; then
        # Only our disposable checker is killed. KILL also bounds cleanup
        # when the checker ignores TERM; its uncommitted output is rejected.
        kill -KILL "$child" 2>/dev/null
        wait "$child" 2>/dev/null
    fi
    if [ "$resume" = 1 ]; then
        shutdown_now=$(uci -q get "$CONFIG.settings.shutdown_correctly")
        if [ "$shutdown_before" != 1 ] && [ "$shutdown_now" = 1 ]; then
            log 'Forkop was stopped during the check; keeping native DNS'
            result=1
        elif state sing-box-current-owned-service-runtime || state start-managed-sing-box-runtime 15; then
            if { [ "$restore_dns" = 1 ] || [ "$dns_redirect_paused" = 1 ]; } && ! restore_runtime_dns; then
                log 'could not restore Forkop DNS; returning to native DNS'
                keep_native_dns
                result=1
            fi
        else
            log 'could not restart the previous runtime; keeping native DNS'
            result=1
        fi
    elif [ "$restore_dns" = 1 ] || [ "$dns_redirect_paused" = 1 ]; then
        # DNS may have been restored even when stop was refused.
        if state sing-box-current-owned-service-runtime; then
            if ! restore_runtime_dns; then
                keep_native_dns
                result=1
            fi
        fi
    fi
    [ "$check_owned" = 0 ] || state release-runtime-dir-lock "$CHECK_LOCK"
    [ "$reload_owned" = 0 ] || state release-runtime-dir-lock "$RELOAD_LOCK"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'log "command exceeded ${CHECK_TIMEOUT}s; restoring the previous runtime"; exit 124' USR1

# Reload/start may already own this lock in a parent process. Do not release
# that parent's lock, or wait for it while the parent waits for this command.
if ! state runtime-dir-lock-owned-by-ancestor "$RELOAD_LOCK" "$$"; then
    state acquire-runtime-dir-lock-wait-until-package-upgrade "$RELOAD_LOCK" "$$" 60 || exit 1
    reload_owned=1
fi
state acquire-runtime-dir-lock "$CHECK_LOCK" "$$" || exit 1
check_owned=1
count=$(state sing-box-process-count) || exit 1
case "$count" in
    0) ;;
    1)
        state sing-box-current-owned-service-runtime || exit 1
        if dns has-managed-state; then
            # A conflicting transaction belongs to an external DNS change.
            # Do not consume it and then overwrite that change on resume.
            dns default-config-complete || exit 1
            restore_dns=1
            dns restore force || exit 1
            dns wait-listener || exit 1
        fi
        # Without a valid DNS snapshot it is safer to reject the candidate
        # than stop a runtime on which dnsmasq still depends.
        dns independent-of-sing-box || exit 1
        dns_redirect_paused=1
        nft_dns pause-source-dns-redirect || exit 1
        resume=1
        state stop-managed-sing-box-runtime 15 || exit 1
        ;;
    *) log 'unexpected additional sing-box process; check deferred'; exit 1 ;;
esac
[ "$(state sing-box-process-count)" = 0 ] || exit 1
sing-box "$@" &
child=$!
start_timer
wait "$child"
result=$?
child=
exit "$result"
