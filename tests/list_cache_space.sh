#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
UPDATES_UC="$FORKOP_LIB/components/updates.uc"
WORK_DIR="$(mktemp -d)"
FLASH_DIR="$WORK_DIR/flash"
RUNTIME_GENERATION="$WORK_DIR/runtime-generation"

cleanup() {
  umount "$FLASH_DIR" >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$FLASH_DIR" "$RUNTIME_GENERATION"
mount -t tmpfs -o size=10m tmpfs "$FLASH_DIR" ||
  fail "could not create the constrained cache filesystem"

cat >"$WORK_DIR/uci.state" <<'EOF_UCI'
forkop.settings=settings
forkop.alpha=section
forkop.alpha.enabled=1
forkop.alpha.action=connection
forkop.alpha.remote_domain_lists=https://lists.test/alpha.txt
EOF_UCI

write_ruleset() {
  target="$1"
  bytes="$2"
  printf '{"version":3,"rules":[]}\n' >"$target"
  current="$(wc -c <"$target")"
  remaining=$((bytes - current))
  if [ "$remaining" -gt 0 ]; then
    dd if=/dev/zero bs=1 count="$remaining" 2>/dev/null | tr '\000' ' ' >>"$target"
  fi
}

write_generation() {
  bytes="$1"
  rm -rf "$RUNTIME_GENERATION"
  mkdir -p "$RUNTIME_GENERATION"
  write_ruleset "$RUNTIME_GENERATION/alpha-remote-domains-ruleset.json" "$bytes"
  printf 'cached.example\n' >"$RUNTIME_GENERATION/source-1"
  signature="$(FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" ucode -L "$FORKOP_LIB" "$FORKOP_LIB/service/state.uc" list-update-signature)"
  ruleset_size="$(wc -c <"$RUNTIME_GENERATION/alpha-remote-domains-ruleset.json")"
  source_size="$(wc -c <"$RUNTIME_GENERATION/source-1")"
  ruleset_md5="$(md5sum "$RUNTIME_GENERATION/alpha-remote-domains-ruleset.json" | cut -d' ' -f1)"
  source_md5="$(md5sum "$RUNTIME_GENERATION/source-1" | cut -d' ' -f1)"
  cat >"$RUNTIME_GENERATION/manifest.json" <<EOF_MANIFEST
{"format":"2","generation":"gen-space-$bytes","signature":"$signature","files":[{"name":"alpha-remote-domains-ruleset.json","kind":"ruleset","size":$ruleset_size,"md5":"$ruleset_md5"},{"name":"source-1","kind":"source","url":"https://lists.test/alpha.txt","source_format":"plain","size":$source_size,"md5":"$source_md5"}]}
EOF_MANIFEST
}

persist() {
  FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  FORKOP_PERSISTENT_LIST_CACHE_DIR="$FLASH_DIR/list-cache" \
  FORKOP_RULESET_CACHE_DIR="$FLASH_DIR/ruleset-cache" \
  FORKOP_PERSISTENT_LIST_CACHE_MANIFEST="$FLASH_DIR/list-cache/manifest.json" \
  FORKOP_LIST_UPDATE_STATE_FILE="$FLASH_DIR/list-cache/last-success.timestamp" \
  FORKOP_RUNTIME_LIST_GENERATION_DIR="$RUNTIME_GENERATION" \
  FORKOP_PERSISTENT_LIST_CACHE_MAX_BYTES=8388608 \
  FORKOP_PERSISTENT_LIST_CACHE_MIN_FREE_BYTES=8388608 \
  FORKOP_LIB="$FORKOP_LIB" \
    ucode -L "$FORKOP_LIB" "$UPDATES_UC" persist-list-cache "$1"
}

write_generation 1048576
persist 100 || fail "1 MiB cache did not fit on a 10 MiB filesystem with an 8 MiB reserve"
first_md5="$(md5sum "$FLASH_DIR/list-cache/alpha-remote-domains-ruleset.json" | cut -d' ' -f1)"

write_generation 3145728
if persist 200; then
  fail "3 MiB replacement was committed despite the 8 MiB free-space reserve"
fi

[ "$first_md5" = "$(md5sum "$FLASH_DIR/list-cache/alpha-remote-domains-ruleset.json" | cut -d' ' -f1)" ] ||
  fail "rejected replacement damaged the previous cache"
[ "$(cat "$FLASH_DIR/list-cache/last-success.timestamp")" = 100 ] ||
  fail "rejected replacement changed the previous cache timestamp"

available_kib="$(df -Pk "$FLASH_DIR" | awk 'END { print $4 }')"
[ "$available_kib" -ge 8192 ] || fail "successful test left less than the required flash reserve"

printf 'constrained flash cache checks passed\n'
