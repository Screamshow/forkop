#!/usr/bin/env bash
set -euo pipefail

# Stateful OpenWrt regression for the lifecycle single-process invariant.
# It is intentionally run against an installed, already healthy Forkop
# instance; it never kills a process it did not start itself.

FORKOP_LIB="${FORKOP_LIB:-/usr/lib/forkop}"
STATE_UC="$FORKOP_LIB/service/state.uc"
WORK_DIR="$(mktemp -d)"
DUPLICATE_PID=""

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
state() { ucode -L "$FORKOP_LIB" "$STATE_UC" "$@"; }
process_count() { state sing-box-process-count | tr -d '[:space:]'; }
table_policy_hash() {
  nft list table inet ForkopTable |
    sed -E 's/counter packets [0-9]+ bytes [0-9]+/counter packets X bytes Y/g' |
    md5sum | awk '{print $1}'
}

cleanup() {
  if [ -n "$DUPLICATE_PID" ] && kill -0 "$DUPLICATE_PID" 2>/dev/null; then
    kill "$DUPLICATE_PID" 2>/dev/null || true
    wait "$DUPLICATE_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

[ -r "$STATE_UC" ] || fail "Forkop state module is missing"
command -v sing-box >/dev/null || fail "sing-box is not installed"

expected_pid="$(state sing-box-service-runtime-pid)" || fail "procd has no Forkop sing-box PID"
[ -n "$(nft list table inet ForkopTable 2>/dev/null)" ] || fail "healthy baseline has no ForkopTable"
table_hash="$(table_policy_hash)"
[ "$(process_count)" = "1" ] || fail "healthy baseline does not have exactly one sing-box process"
state sing-box-single-owned-service-runtime || fail "healthy PID is not the sole procd-owned sing-box"
state single-ready-sing-box-runtime || fail "healthy sing-box readiness failed"
state wait-forkop-stable-start forkop ForkopTable 0x04000000 0 2 ||
  fail "healthy Forkop state was not accepted"

cat >"$WORK_DIR/duplicate.json" <<'EOF'
{
  "log": { "level": "error" },
  "inbounds": [{ "type": "mixed", "tag": "duplicate-test", "listen": "127.0.0.1", "listen_port": 19081 }],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": { "final": "direct" }
}
EOF

sing-box check -c "$WORK_DIR/duplicate.json" >/dev/null
sing-box run -c "$WORK_DIR/duplicate.json" >"$WORK_DIR/duplicate.log" 2>&1 &
DUPLICATE_PID="$!"

for _ in 1 2 3 4 5; do
  [ "$(process_count)" = "2" ] && break
  sleep 1
done
[ "$(process_count)" = "2" ] || fail "test-owned second sing-box process did not remain running"
[ "$(state sing-box-service-runtime-pid)" = "$expected_pid" ] ||
  fail "duplicate test changed the procd-owned sing-box PID"
if state single-ready-sing-box-runtime; then
  fail "duplicate sing-box process was accepted as ready"
fi
if state forkop-running forkop ForkopTable 0x04000000; then
  fail "duplicate sing-box process was accepted as running"
fi
if state wait-forkop-stable-start forkop ForkopTable 0x04000000 0 1; then
  fail "duplicate sing-box process was accepted as stable"
fi
if /usr/bin/forkop reload on_config_change >/dev/null 2>&1; then
  fail "lifecycle accepted reload while sing-box ownership was ambiguous"
fi
[ "$(state sing-box-service-runtime-pid)" = "$expected_pid" ] ||
  fail "duplicate rejection restarted the procd-owned sing-box"
[ "$(table_policy_hash)" = "$table_hash" ] ||
  fail "duplicate rejection changed the active nft policy"

kill "$DUPLICATE_PID"
wait "$DUPLICATE_PID" 2>/dev/null || true
DUPLICATE_PID=""
for _ in 1 2 3 4 5; do
  [ "$(process_count)" = "1" ] && break
  sleep 1
done
[ "$(process_count)" = "1" ] || fail "test-owned duplicate did not exit"
state wait-forkop-stable-start forkop ForkopTable 0x04000000 0 4 ||
  fail "Forkop did not recover its accepted state after duplicate exit"

printf 'sing-box single-process lifecycle checks passed\n'
