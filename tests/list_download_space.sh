#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
UPDATES_UC="$FORKOP_LIB/components/updates.uc"
WORK_DIR="$(mktemp -d)"
TARGET_DIR="$WORK_DIR/target"
SOURCE_DIR="$WORK_DIR/source"
HTTP_PID=""

cleanup() {
  [ -z "$HTTP_PID" ] || kill "$HTTP_PID" >/dev/null 2>&1 || true
  umount "$TARGET_DIR" >/dev/null 2>&1 || true
  umount "$SOURCE_DIR" >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$TARGET_DIR" "$SOURCE_DIR"
mount -t tmpfs -o size=10m tmpfs "$TARGET_DIR" || fail "could not mount constrained target"
mount -t tmpfs -o size=5m tmpfs "$SOURCE_DIR" || fail "could not mount HTTP source"
dd if=/dev/zero of="$SOURCE_DIR/small" bs=1M count=1 2>/dev/null
dd if=/dev/zero of="$SOURCE_DIR/large" bs=1M count=3 2>/dev/null

uhttpd -f -h "$SOURCE_DIR" -p 127.0.0.1:18089 >/dev/null 2>&1 &
HTTP_PID=$!
sleep 1

download() {
  FORKOP_LIST_DOWNLOAD_MIN_FREE_BYTES=8388608 \
  FORKOP_LIB="$FORKOP_LIB" \
    ucode -L "$FORKOP_LIB" "$UPDATES_UC" download-list-file "$1" "$2"
}

download http://127.0.0.1:18089/small "$TARGET_DIR/small" ||
  fail "a download fitting above the temporary-space reserve was rejected"
[ "$(wc -c <"$TARGET_DIR/small")" -eq 1048576 ] || fail "small download was truncated"
rm -f "$TARGET_DIR/small"

if download http://127.0.0.1:18089/large "$TARGET_DIR/large"; then
  fail "an oversized stream crossed the temporary-space reserve"
fi
[ ! -e "$TARGET_DIR/large" ] || fail "failed oversized download left a partial file"
[ "$(df -Pk "$TARGET_DIR" | awk 'END { print $4 }')" -ge 8192 ] ||
  fail "failed oversized download consumed the temporary-space reserve"

printf 'bounded list download checks passed\n'
