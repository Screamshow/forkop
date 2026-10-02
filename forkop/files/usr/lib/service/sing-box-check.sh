#!/bin/sh
# Run a memory-heavy sing-box command without the managed runtime beside it.
# Downloads and publication stay with the caller; this only lends it the RAM.
LIB=${FORKOP_LIB:-/usr/lib/forkop}
STATE=${FORKOP_STATE_UC:-$LIB/service/state.uc}
DNS=${FORKOP_DNS_APPLY_UC:-$LIB/dns/apply.uc}
RELOAD_LOCK=${FORKOP_RELOAD_LOCK_DIR:-/var/run/forkop.reload.lock}
CHECK_LOCK=${FORKOP_SING_BOX_CHECK_LOCK_DIR:-/var/run/forkop.sing-box-check.lock}
CONFIG=${FORKOP_CONFIG_NAME:-forkop}
state() {
    case "$1" in
        sing-box-process-count) ucode -L "$LIB" "$STATE" "$@" ;;
        *) ucode -L "$LIB" "$STATE" "$@" >/dev/null 2>&1 ;;
    esac
}
# stdout belongs to the checker (notably diagnostics tools fetch). Init
# scripts may print DHCP probes when restarting DNS; do not mix these in.
dns() { ucode -L "$LIB" "$DNS" "$@" >/dev/null 2>&1; }
log() { logger -t forkop "[warn] sing-box check: $*"; }
reload_owned=0
check_owned=0
resume=0
restore_dns=0
child=
shutdown_before=$(uci -q get "$CONFIG.settings.shutdown_correctly")

runtime_ready() {
    remaining=15
    while ! state single-ready-sing-box-runtime; do
        [ "$remaining" -gt 0 ] || return 1
        sleep 1
        remaining=$((remaining - 1))
    done
}

cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    # Never restart the runtime before the checker has actually exited.
    if [ -n "$child" ]; then
        kill "$child" 2>/dev/null
        wait "$child" 2>/dev/null
    fi
    if [ "$resume" = 1 ]; then
        shutdown_now=$(uci -q get "$CONFIG.settings.shutdown_correctly")
        if [ "$shutdown_before" != 1 ] && [ "$shutdown_now" = 1 ]; then
            log 'Forkop was stopped during the check; keeping native DNS'
            result=1
        elif state sing-box-current-owned-service-runtime || state start-managed-sing-box-runtime 15; then
            if [ "$restore_dns" = 1 ] && ! { runtime_ready && dns configure force && dns wait-listener; }; then
                log 'could not restore Forkop DNS; returning to native DNS'
                dns restore force
                dns wait-listener
                result=1
            fi
        else
            log 'could not restart the previous runtime; keeping native DNS'
            result=1
        fi
    elif [ "$restore_dns" = 1 ]; then
        # DNS may have been restored even when stop was refused.
        if state sing-box-current-owned-service-runtime; then
            { runtime_ready && dns configure force && dns wait-listener; } || result=1
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
        resume=1
        state stop-managed-sing-box-runtime 15 || exit 1
        ;;
    *) log 'unexpected additional sing-box process; check deferred'; exit 1 ;;
esac
[ "$(state sing-box-process-count)" = 0 ] || exit 1
sing-box "$@" &
child=$!
wait "$child"
result=$?
child=
exit "$result"
