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
  fail "startup must launch one automatic latency worker after it is safe"
[ "$(grep -Fc 'module_background(DIAGNOSTICS_UC, [ "automatic-latency-test", "resume" ])' "$LIFECYCLE_UC")" -eq 1 ] ||
  fail "startup must contain only one automatic latency worker hook"
grep -Fq 'Automatic latency test is deferred until the pending Forkop reload completes' "$LIFECYCLE_UC" ||
  fail "startup must defer automatic latency while reload.pending exists"
grep -Fq 'post-start list and rule-set pipeline completes' "$LIFECYCLE_UC" ||
  fail "startup must defer automatic latency until its list/rule-set pipeline completes"
grep -Fq 'post-start-latency' "$ROOT_DIR/forkop/files/usr/lib/singbox/ruleset_cache.uc" ||
  fail "post-start ruleset refresh must release the automatic latency barrier"
grep -Fq 'schedule_automatic_latency_after_runtime' "$LIFECYCLE_UC" ||
  fail "startup and pending reload must share one final-signature latency scheduler"
grep -Fq 'run_pending_reload_if_requested(PENDING_RELOAD_FILE, SERVICE_INIT)' "$ROOT_DIR/forkop/files/usr/lib/service/initd.uc" ||
  fail "initd must hand pending reloads off only after releasing the start action"
if sed -n '960,1010p' "$LIFECYCLE_UC" | grep -Fq 'automatic-latency-test'; then
  fail "start_impl must not launch a latency worker before startup/reload handoff"
fi
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
grep -Fq 'Automatic latency test is waiting for the pending Forkop reload before taking measurements' "$DIAGNOSTICS_UC" ||
  fail "automatic latency must not measure before a startup pending reload"
grep -Fq 'the final runtime will resume it' "$DIAGNOSTICS_UC" ||
  fail "the worker that handed off a pending reload must yield to its final-runtime replacement"
grep -Fq 'pending_reload_requested' "$DIAGNOSTICS_UC" ||
  fail "a pending reload must be distinguished from an unrelated reload interruption"
grep -Fq 'resuming automatically after sing-box is ready' "$DIAGNOSTICS_UC" ||
  fail "reload-interrupted automatic latency must resume without a manual restart"
if grep -Fq 'attempt < 20' "$DIAGNOSTICS_UC"; then
  fail "duplicate automatic latency tests must skip instead of queuing"
fi
grep -Fq 'automatic_latency_remove_marker(pending_signature)' "$DIAGNOSTICS_UC" ||
  fail "successful latency completion must remove its matching marker"
grep -Fq 'automatic_latency_record_failure(pending_signature)' "$DIAGNOSTICS_UC" ||
  fail "failed latency tests must retain a marker with retry state"
grep -Fq 'AUTOMATIC_LATENCY_RETRY_BASE_SECONDS' "$DIAGNOSTICS_UC" ||
  fail "Clash API failures must have a retry pause"
grep -Fq 'module_background(DIAGNOSTICS_UC, [ "automatic-latency-test", "resume" ])' "$DIAGNOSTICS_UC" ||
  fail "reload interruption must schedule its own resume worker"
grep -Fq 'the pending reload will resume it after sing-box is ready' "$DIAGNOSTICS_UC" ||
  fail "pending reload must own the single automatic test resume"

# The LuCI/manual bulk action stays available and is intentionally independent
# from the removed lifecycle scheduling.
grep -Fq 'if (action == "get_proxy_latencies")' "$DIAGNOSTICS_UC" ||
  fail "manual LuCI bulk latency test must remain available"
grep -Fq 'let owner_pid = current_pid();' "$ROOT_DIR/forkop/files/usr/lib/service/ui.uc" ||
  fail "manual LuCI latency lock must be owned by the live worker process"

printf 'latency/reload serialization checks passed\n'
