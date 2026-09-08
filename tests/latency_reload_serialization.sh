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
grep -Fq 'module_background(DIAGNOSTICS_UC, [ "automatic-latency-test", "resume" ])' "$LIFECYCLE_UC" ||
  fail "successful startup must resume a persistent pending latency test"
[ "$(grep -Fc 'module_background(DIAGNOSTICS_UC, [ "automatic-latency-test", "resume" ])' "$LIFECYCLE_UC")" -eq 1 ] ||
  fail "startup must contain only one pending-test resume hook"
[ "$(grep -Fc 'module_background([ DIAGNOSTICS_UC, "automatic-latency-test", "new" ])' "$UPDATES_UC")" -eq 1 ] ||
  fail "subscription changes must launch one new automatic latency worker"
grep -Fq 'AUTOMATIC_LATENCY_PENDING_FILE' "$UPDATES_UC" ||
  fail "subscription changes must use a persistent pending marker"
grep -Fq 'write_state_file(AUTOMATIC_LATENCY_PENDING_FILE' "$UPDATES_UC" ||
  fail "pending marker must be written atomically"
grep -Fq 'final_proxy_set_changed = proxy_signature_after != "" && proxy_signature_after != proxy_signature_before' "$UPDATES_UC" ||
  fail "latency scheduling must compare the final usable proxy set"
grep -Fq '"acquire-runtime-dir-lock-wait", RELOAD_LOCK_DIR, owner_pid' "$DIAGNOSTICS_UC" ||
  fail "automatic latency test must serialize against Forkop reload"
grep -Fq '"single-ready-sing-box-runtime"' "$DIAGNOSTICS_UC" ||
  fail "automatic latency test must require one ready sing-box process"
grep -Fq 'function single_ready_sing_box_runtime()' "$ROOT_DIR/forkop/files/usr/lib/service/state.uc" ||
  fail "service state must expose the single ready sing-box predicate"
grep -Fq 'Automatic latency test is already scheduled or running; coalescing the duplicate request' "$DIAGNOSTICS_UC" ||
  fail "duplicate automatic latency requests must coalesce"
grep -Fq 'completed % batch_size == 0' "$DIAGNOSTICS_UC" ||
  fail "automatic latency warm-up must yield between bounded batches"
grep -Fq 'run-pending-reload-if-requested' "$DIAGNOSTICS_UC" ||
  fail "automatic latency warm-up must yield to pending reloads between batches"
if grep -Fq 'attempt < 20' "$DIAGNOSTICS_UC"; then
  fail "duplicate automatic latency tests must skip instead of queuing"
fi
grep -Fq 'automatic_latency_remove_marker(pending_signature)' "$DIAGNOSTICS_UC" ||
  fail "successful latency completion must remove its matching marker"
grep -Fq 'automatic_latency_record_failure(pending_signature)' "$DIAGNOSTICS_UC" ||
  fail "failed latency tests must retain a marker with retry state"
grep -Fq 'AUTOMATIC_LATENCY_RETRY_BASE_SECONDS' "$DIAGNOSTICS_UC" ||
  fail "Clash API failures must have a retry pause"
grep -Fq 'pending marker was retained for the next start' "$DIAGNOSTICS_UC" ||
  fail "reload interruption must retain and report the pending marker"

# The LuCI/manual bulk action stays available and is intentionally independent
# from the removed lifecycle scheduling.
grep -Fq 'if (action == "get_proxy_latencies")' "$DIAGNOSTICS_UC" ||
  fail "manual LuCI bulk latency test must remain available"
grep -Fq 'let owner_pid = current_pid();' "$ROOT_DIR/forkop/files/usr/lib/service/ui.uc" ||
  fail "manual LuCI latency lock must be owned by the live worker process"

printf 'latency/reload serialization checks passed\n'
