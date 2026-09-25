#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$ROOT_DIR/forkop/files/usr/lib"
STATE_UC="$LIB_DIR/service/state.uc"
PACKAGE_UC="$LIB_DIR/service/package.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

awk '
  /cat > "\$helper_path" <<\x27EOF\x27/ { copying = 1; next }
  copying && /^EOF$/ { exit }
  copying { print }
' "$ROOT_DIR/install.sh" > "$WORK_DIR/installer-helper.uc"
[ -s "$WORK_DIR/installer-helper.uc" ]

state() { ucode -L "$LIB_DIR" "$STATE_UC" "$@"; }
package() { ucode -L "$LIB_DIR" "$PACKAGE_UC" "$@"; }
installer() { ucode "$WORK_DIR/installer-helper.uc" "$@"; }
expect_identity() {
  local path="$1" expected="$2"
  for owner in state package installer; do
    if "$owner" sing-box-exe-path-fixture "$path"; then
      [ "$expected" = yes ] || { echo "accepted $path in $owner" >&2; exit 1; }
    else
      [ "$expected" = no ] || { echo "rejected $path in $owner" >&2; exit 1; }
    fi
  done
}
observe() {
  local actual expected="$1"
  shift
  actual="$(state stopped-owned-pid-observation-fixture "$@")"
  [ "$actual" = "$expected" ] || { echo "expected $expected, got $actual" >&2; exit 1; }
}
verify_runtime() {
  local expected="$1" actual
  shift
  if actual="$(state verified-sing-box-runtime-fixture "$@")"; then
    [ "$actual" = "$expected" ] || { echo "expected provenance $expected, got $actual" >&2; exit 1; }
  else
    [ "$expected" = reject ] || { echo "rejected expected provenance $expected" >&2; exit 1; }
  fi
}

expect_identity /usr/bin/sing-box yes
expect_identity '/usr/bin/sing-box (deleted)' yes
expect_identity '/usr/bin/sing-box ' no
expect_identity /usr/bin/not-sing-box no
expect_identity '/usr/bin/sing-box (deleted) extra' no
expect_identity '/usr/bin/sing-box (deleted) (deleted)' no
[ "$(state sing-box-exe-kind-fixture /usr/bin/sing-box)" = current ]
[ "$(state sing-box-exe-kind-fixture '/usr/bin/sing-box (deleted)')" = deleted ]
[ "$(state sing-box-exe-kind-fixture '/usr/bin/sing-box ')" = other ]

# The deleted child remains counted as the sole owned process, then its exact
# PID/start time must disappear and procd must clear the PID before replacement.
observe wait 100 100 1 1 42
observe wait 100 gone 0 0 42
observe exited 100 gone 0 0 0

# Identity loss during exit is allowed only for the same PID/start time.
observe wait 100 100 0 0 42
observe extra 100 100 0 1 42
observe reused 100 101 1 1 42
observe extra 100 100 1 2 42
observe extra 100 gone 0 1 0

# Procd's final PID and the process start time must still refer to the first
# verified child. A handoff or reuse cannot lend its identity to another PID.
verify_runtime 42:100 42 100 1 1 42 100 1
verify_runtime reject 42 100 1 1 43 100 1
verify_runtime reject 42 100 1 1 42 101 1
verify_runtime reject 42 100 1 1 42 101 0
verify_runtime reject 42 100 1 2 42 100 1

# A controlled replacement accepts the deleted child as owned until it exits,
# then a new sole procd-owned PID must point at the installed executable.
observe exited 100 gone 0 0 0
verify_runtime 43:200 43 200 1 1 43 200 1
[ "$(state sing-box-exe-kind-fixture /usr/bin/sing-box)" = current ]

echo 'sing-box deleted identity and stop transition checks passed'
