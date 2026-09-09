#!/bin/sh
set -eu

# Stateful OpenWrt fixture for the stop -> exact-PID-exit -> start contract.
# The helper uses real /proc start ticks. Fake ubus/readlink/init.d model only
# the Forkop-owned service boundary, so no user process is ever touched.

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATE="${FORKOP_STATE_UC:-$ROOT/forkop/files/usr/lib/service/state.uc}"
LIB="${FORKOP_LIB:-$ROOT/forkop/files/usr/lib}"
LIFECYCLE="$ROOT/forkop/files/usr/lib/service/lifecycle.uc"
UPDATES="$ROOT/forkop/files/usr/lib/components/updates.uc"
WORK="$(mktemp -d)"
managed_pid=""
extra_pid=""
new_pid=""

fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  for pid in "$managed_pid" "$extra_pid" "$new_pid"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# Every managed config transition stops and proves old-runtime exit before it
# publishes config.json. This covers normal/pending list reload, subscriptions,
# DNS fallback/restore, and full/manual restart.
grep -Fq 'controlled_replace_managed_sing_box_runtime(timeout)' "$STATE" ||
  fail "managed config reload is not routed through the controlled replacement"
! grep -Fq '[ "/etc/init.d/sing-box", "reload" ]' "$STATE" ||
  fail "state module retains an unsafe direct sing-box reload"
grep -Fq '"start-managed-sing-box-runtime"' "$LIFECYCLE" ||
  fail "lifecycle start does not verify a sole managed runtime"
grep -Fq '"stop-managed-sing-box-runtime"' "$LIFECYCLE" ||
  fail "full/manual restart does not wait for exact managed runtime exit"
! grep -Fq '"reload-sing-box-runtime"' "$LIFECYCLE" ||
  fail "lifecycle publishes managed config before a guarded stop/start"
! grep -Fq '"reload-sing-box-runtime"' "$UPDATES" ||
  fail "subscription update publishes managed config before a guarded stop/start"
awk '
  /stop-managed-sing-box-runtime/ { stopped = NR }
  /commit-config-stage/ && stopped >= NR { bad = 1 }
  END { exit bad ? 1 : 0 }
' "$LIFECYCLE" || fail "normal/list transition does not stop before committing config"
grep -Fq '"stop-managed-sing-box-runtime", transition_timeout' "$UPDATES" ||
  fail "subscription update does not stop before rebuilding config"
grep -Fq '"stop-managed-sing-box-runtime", transition_timeout' "$LIFECYCLE" ||
  fail "DNS transition does not stop before patching config"

mkdir -p "$WORK/bin"
export TEST_PROCD_PID_FILE="$WORK/procd.pid"
export TEST_SINGBOX_PIDS_FILE="$WORK/singbox.pids"
export TEST_ACTION_LOG="$WORK/actions.log"
export TEST_OLD_PID_FILE="$WORK/old.pid"
export TEST_STOP_MODE=""
export TEST_STOP_DELAY=0

cat >"$WORK/bin/ubus" <<'SH'
#!/bin/sh
pid="$(cat "$TEST_PROCD_PID_FILE" 2>/dev/null || true)"
case "$pid" in ''|*[!0-9]*) printf '{}\n' ;; *) printf '{"sing-box":{"instances":{"main":{"running":true,"pid":%s}}}}\n' "$pid" ;; esac
SH
cat >"$WORK/bin/readlink" <<'SH'
#!/bin/sh
path=""
for arg in "$@"; do path="$arg"; done
case "$path" in
  /proc/[0-9]*/exe)
    pid="${path#/proc/}"; pid="${pid%/exe}"
    if grep -qx "$pid" "$TEST_SINGBOX_PIDS_FILE" 2>/dev/null; then
      printf '%s\n' /usr/bin/sing-box
    else
      printf '%s\n' /usr/bin/not-sing-box
    fi
    ;;
  *) exec /usr/bin/readlink "$@" ;;
esac
SH
cat >"$WORK/bin/logger" <<'SH'
#!/bin/sh
exit 0
SH
cat >"$WORK/bin/sing-box-init" <<'SH'
#!/bin/sh
set -eu
case "${1:-}" in
  stop)
    echo stop >>"$TEST_ACTION_LOG"
    old="$(cat "$TEST_OLD_PID_FILE")"
    case "${TEST_STOP_MODE:-}" in
      timeout) exit 0 ;;
      respawn)
        sleep 60 & replacement=$!
        printf '%s\n' "$replacement" >"$TEST_SINGBOX_PIDS_FILE"
        printf '%s\n' "$replacement" >"$TEST_PROCD_PID_FILE"
        kill "$old" 2>/dev/null || true
        exit 0
        ;;
      pid-mismatch)
        # Model a PID whose /proc identity no longer matches the captured
        # managed provenance. The helper must not start another instance.
        : >"$TEST_SINGBOX_PIDS_FILE"
        exit 0
        ;;
      delayed)
        (
          sleep "${TEST_STOP_DELAY:-1}"
          kill "$old" 2>/dev/null || true
          : >"$TEST_SINGBOX_PIDS_FILE"
          : >"$TEST_PROCD_PID_FILE"
        ) &
        exit 0
        ;;
      *)
        kill "$old" 2>/dev/null || true
        : >"$TEST_SINGBOX_PIDS_FILE"
        : >"$TEST_PROCD_PID_FILE"
        exit 0
        ;;
    esac
    ;;
  start)
    old="$(cat "$TEST_OLD_PID_FILE" 2>/dev/null || true)"
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
      echo start-before-old-exit >>"$TEST_ACTION_LOG"
      exit 1
    fi
    echo start >>"$TEST_ACTION_LOG"
    sleep 60 & replacement=$!
    printf '%s\n' "$replacement" >"$TEST_SINGBOX_PIDS_FILE"
    printf '%s\n' "$replacement" >"$TEST_PROCD_PID_FILE"
    exit 0
    ;;
  *) exit 1 ;;
esac
SH
chmod 0755 "$WORK/bin/ubus" "$WORK/bin/readlink" "$WORK/bin/logger" "$WORK/bin/sing-box-init"

state() {
  PATH="$WORK/bin:$PATH" FORKOP_SING_BOX_INIT="$WORK/bin/sing-box-init" \
    ucode -L "$LIB" "$STATE" "$@"
}
start_managed() {
  sleep 60 & managed_pid=$!
  printf '%s\n' "$managed_pid" >"$TEST_OLD_PID_FILE"
  printf '%s\n' "$managed_pid" >"$TEST_SINGBOX_PIDS_FILE"
  printf '%s\n' "$managed_pid" >"$TEST_PROCD_PID_FILE"
}
clear_processes() {
  for pid in "$managed_pid" "$extra_pid" "$new_pid"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  managed_pid=""; extra_pid=""; new_pid=""
  : >"$TEST_SINGBOX_PIDS_FILE"; : >"$TEST_PROCD_PID_FILE"; : >"$TEST_ACTION_LOG"
}

# A deliberately slow old process must be gone before init.d start is called.
start_managed
TEST_STOP_MODE=delayed TEST_STOP_DELAY=1 state controlled-replace-managed-sing-box-runtime 4 ||
  fail "slow managed replacement failed"
grep -qx 'stop' "$TEST_ACTION_LOG" || fail "slow replacement did not stop the old runtime"
grep -qx 'start' "$TEST_ACTION_LOG" || fail "slow replacement did not start the replacement"
! grep -q 'start-before-old-exit' "$TEST_ACTION_LOG" || fail "replacement started before exact old PID exit"
! kill -0 "$managed_pid" 2>/dev/null || fail "old managed PID remained after successful replacement"
new_pid="$(cat "$TEST_PROCD_PID_FILE")"
grep -qx "$new_pid" "$TEST_SINGBOX_PIDS_FILE" || fail "new runtime is not the sole managed process"
clear_processes

# A timeout must not launch a new runtime or kill the still-running old PID.
start_managed
if TEST_STOP_MODE=timeout state controlled-replace-managed-sing-box-runtime 1; then
  fail "old PID timeout unexpectedly succeeded"
fi
kill -0 "$managed_pid" 2>/dev/null || fail "timeout killed the old managed PID"
! grep -qx 'start' "$TEST_ACTION_LOG" || fail "timeout launched a replacement runtime"
clear_processes

# A changed PID identity (including PID reuse / starttime mismatch) is not an
# exit confirmation. It must fail closed before a replacement is launched.
start_managed
if TEST_STOP_MODE=pid-mismatch state controlled-replace-managed-sing-box-runtime 2; then
  fail "PID identity mismatch unexpectedly succeeded"
fi
kill -0 "$managed_pid" 2>/dev/null || fail "PID identity mismatch killed the original process"
! grep -qx 'start' "$TEST_ACTION_LOG" || fail "PID identity mismatch launched a replacement"
clear_processes

# A procd replacement during the bounded stop wait is unexpected: do not
# create another process on top of it.
start_managed
if TEST_STOP_MODE=respawn state controlled-replace-managed-sing-box-runtime 2; then
  fail "procd respawn race unexpectedly succeeded"
fi
! grep -qx 'start' "$TEST_ACTION_LOG" || fail "respawn race launched another runtime"
new_pid="$(cat "$TEST_PROCD_PID_FILE")"
kill -0 "$new_pid" 2>/dev/null || fail "fixture respawn did not remain observable"
clear_processes

# Ambiguous ownership is rejected before init.d stop; neither managed nor
# foreign process may be touched.
start_managed
sleep 60 & extra_pid=$!
printf '%s\n%s\n' "$managed_pid" "$extra_pid" >"$TEST_SINGBOX_PIDS_FILE"
if state controlled-replace-managed-sing-box-runtime 2; then
  fail "procd-owned plus foreign runtime unexpectedly transitioned"
fi
[ ! -s "$TEST_ACTION_LOG" ] || fail "ambiguous ownership reached init.d stop"
kill -0 "$managed_pid" 2>/dev/null || fail "ambiguous transition killed managed runtime"
kill -0 "$extra_pid" 2>/dev/null || fail "ambiguous transition killed foreign runtime"
clear_processes

# Foreign-only and two-foreign layouts are blocked before any service action.
sleep 60 & extra_pid=$!
printf '%s\n' "$extra_pid" >"$TEST_SINGBOX_PIDS_FILE"
if state controlled-replace-managed-sing-box-runtime 2; then
  fail "foreign-only runtime unexpectedly transitioned"
fi
[ ! -s "$TEST_ACTION_LOG" ] || fail "foreign-only layout reached init.d stop"
sleep 60 & new_pid=$!
printf '%s\n%s\n' "$extra_pid" "$new_pid" >"$TEST_SINGBOX_PIDS_FILE"
if state controlled-replace-managed-sing-box-runtime 2; then
  fail "two foreign runtimes unexpectedly transitioned"
fi
[ ! -s "$TEST_ACTION_LOG" ] || fail "two-foreign layout reached init.d stop"

printf '%s\n' 'controlled sing-box transition checks passed'
