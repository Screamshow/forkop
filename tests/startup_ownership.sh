#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATE="$ROOT/forkop/files/usr/lib/service/state.uc"
INITD="$ROOT/forkop/files/usr/lib/service/initd.uc"
LIFECYCLE="$ROOT/forkop/files/usr/lib/service/lifecycle.uc"
WORK="$(mktemp -d)"
trap 'kill ${managed_pid:-} ${foreign_pid:-} ${foreign2_pid:-} 2>/dev/null || true; rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
cat >"$WORK/ubus" <<'SH'
#!/bin/sh
printf '{"sing-box":{"instances":{"main":{"running":true,"pid":%s}}}}\n' "${FORKOP_TEST_SERVICE_PID:-0}"
SH
cat >"$WORK/readlink" <<'SH'
#!/bin/sh
path=""
for argument in "$@"; do path="$argument"; done
case "$path" in
  /proc/[0-9]*/exe)
    pid="${path#/proc/}"; pid="${pid%/exe}"
    for expected in ${FORKOP_TEST_SINGBOX_PIDS:-}; do
      [ "$pid" = "$expected" ] && { printf '%s\n' /usr/bin/sing-box; exit 0; }
    done
    printf '%s\n' /usr/bin/not-sing-box
    ;;
  *) /usr/bin/readlink "$@" ;;
esac
SH
chmod 0755 "$WORK/ubus" "$WORK/readlink"

marker="$WORK/upgrade.marker"
start_managed() { sleep 60 & managed_pid=$!; }
start_foreign() { sleep 60 & foreign_pid=$!; }
start_foreign2() { sleep 60 & foreign2_pid=$!; }
state() { PATH="$WORK:$PATH" FORKOP_TEST_SERVICE_PID="${managed_pid:-0}" FORKOP_TEST_SINGBOX_PIDS="${managed_pid:-} ${foreign_pid:-} ${foreign2_pid:-}" ucode -L "$ROOT/forkop/files/usr/lib" "$STATE" "$@"; }

# Exact managed PID/starttime is captured atomically, then a bounded wait
# succeeds only after that same process has exited.
start_managed
state write-managed-upgrade-sing-box-marker "$marker" || fail "managed provenance was not captured"
grep -qx 'format=1' "$marker" || fail "marker format missing"
grep -qx "pid=$managed_pid" "$marker" || fail "marker PID mismatch"
kill "$managed_pid"
wait "$managed_pid" 2>/dev/null || true
state wait-managed-upgrade-sing-box-exit "$marker" 1 120 || fail "exited managed PID did not recover"
[ ! -e "$marker" ] || fail "successful marker was not consumed"

# PID/starttime provenance never authorizes an extra foreign process: capture
# itself is refused while ownership is ambiguous.
start_managed
start_foreign
if state write-managed-upgrade-sing-box-marker "$marker"; then
  fail "procd+foreign sing-box unexpectedly received provenance"
fi
[ ! -e "$marker" ] || fail "ambiguous capture left a marker"
kill "$managed_pid" "$foreign_pid"
wait "$managed_pid" 2>/dev/null || true
wait "$foreign_pid" 2>/dev/null || true
unset managed_pid foreign_pid

# Foreign-only and two-foreign layouts remain conflicts. The lifecycle's
# guarded start/restart paths consume this predicate before they can stop
# anything, which is the safety contract for delayed retry.
start_foreign
if ! state sing-box-process-conflict; then
  fail "foreign-only sing-box was not blocked"
fi
start_foreign2
if ! state sing-box-process-conflict; then
  fail "two foreign sing-box processes were not blocked"
fi
kill "$foreign_pid" "$foreign2_pid"
wait "$foreign_pid" 2>/dev/null || true
wait "$foreign2_pid" 2>/dev/null || true
unset foreign_pid foreign2_pid

# A marker that points at a live PID with mismatched starttime is rejected and
# consumed, modelling PID reuse without authorizing the replacement process.
start_managed
state write-managed-upgrade-sing-box-marker "$marker" || fail "marker setup failed"
sed 's/^start_ticks=.*/start_ticks=1/' "$marker" >"$marker.new"
mv "$marker.new" "$marker"
if state wait-managed-upgrade-sing-box-exit "$marker" 1 120; then
  fail "reused/mismatched PID marker was accepted"
fi
[ ! -e "$marker" ] || fail "rejected marker was not consumed"
kill "$managed_pid"
wait "$managed_pid" 2>/dev/null || true
unset managed_pid

# Delayed retry is a guarded start, never a destructive restart.
[ "$(ucode -L "$ROOT/forkop/files/usr/lib" "$INITD" retry-start-on-wan-up-action 0 1 1)" = start ] ||
  fail "retry action is not guarded start"
grep -Fq '[ SERVICE_INIT, "start", "triggered" ]' "$INITD" || fail "retry does not use start"
grep -Fq '[ SERVICE_INIT, "restart", "triggered" ]' "$INITD" && fail "retry still uses restart"
grep -Fq 'sing-box-process-conflict' "$LIFECYCLE" || fail "lifecycle ownership guard missing"
grep -Fq 'wait-managed-upgrade-sing-box-exit' "$LIFECYCLE" || fail "managed wait is not before lifecycle guard"

printf 'startup ownership checks passed\n'
