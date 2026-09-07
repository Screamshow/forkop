#!/bin/sh
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIFECYCLE_UC="$ROOT_DIR/forkop/files/usr/lib/service/lifecycle.uc"
DIAGNOSTICS_UC="$ROOT_DIR/forkop/files/usr/lib/diagnostics/runtime.uc"
UPDATES_UC="$ROOT_DIR/forkop/files/usr/lib/components/updates.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -Fq 'refresh-rulesets-after-start' "$LIFECYCLE_UC" ||
  fail "cold-start rule-set refresh must remain enabled without a latency test"
if grep -Fq 'module_background(DIAGNOSTICS_UC, [ "automatic-latency-test" ])' "$LIFECYCLE_UC"; then
  fail "ordinary lifecycle reloads must not schedule automatic latency tests"
fi
[ "$(grep -Fc 'module_background([ DIAGNOSTICS_UC, "automatic-latency-test" ])' "$UPDATES_UC")" -eq 1 ] ||
  fail "only subscription updates may schedule an automatic latency test"
grep -Fq '"acquire-runtime-dir-lock-wait", RELOAD_LOCK_DIR, owner_pid' "$DIAGNOSTICS_UC" ||
  fail "automatic latency test must serialize against Forkop reload"
grep -Fq '"single-ready-sing-box-runtime"' "$DIAGNOSTICS_UC" ||
  fail "automatic latency test must require one ready sing-box process"
grep -Fq 'function single_ready_sing_box_runtime()' "$ROOT_DIR/forkop/files/usr/lib/service/state.uc" ||
  fail "service state must expose the single ready sing-box predicate"
grep -Fq 'Automatic latency test is already scheduled or running; skipping duplicate' "$DIAGNOSTICS_UC" ||
  fail "duplicate automatic latency requests must coalesce"
grep -Fq 'completed % batch_size == 0' "$DIAGNOSTICS_UC" ||
  fail "automatic latency warm-up must yield between bounded batches"
grep -Fq 'run-pending-reload-if-requested' "$DIAGNOSTICS_UC" ||
  fail "automatic latency warm-up must yield to pending reloads between batches"
if grep -Fq 'attempt < 20' "$DIAGNOSTICS_UC"; then
  fail "duplicate automatic latency tests must skip instead of queuing"
fi

# The LuCI/manual bulk action stays available and is intentionally independent
# from the removed lifecycle scheduling.
grep -Fq 'if (action == "get_proxy_latencies")' "$DIAGNOSTICS_UC" ||
  fail "manual LuCI bulk latency test must remain available"
grep -Fq 'let owner_pid = current_pid();' "$ROOT_DIR/forkop/files/usr/lib/service/ui.uc" ||
  fail "manual LuCI latency lock must be owned by the live worker process"

printf 'latency/reload serialization checks passed\n'
