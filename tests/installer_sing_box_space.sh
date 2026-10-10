#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
# Source only storage helpers, without executing the installer.
source <(sed -n '/^package_payload_size_kb() {/,/^}/p' "$ROOT_DIR/install.sh")
# A tiny compressed archive must still budget its full extracted payload.
mkdir -p "$TMP_DIR/data/usr/bin" "$TMP_DIR/package"
dd if=/dev/zero of="$TMP_DIR/data/usr/bin/sing-box" bs=1024 count=2048 status=none
tar -czf "$TMP_DIR/package/data.tar.gz" -C "$TMP_DIR/data" .
tar -czf "$TMP_DIR/tiny.ipk" -C "$TMP_DIR/package" .
PKG_IS_APK=0
[ "$(package_payload_size_kb "$TMP_DIR/tiny.ipk")" = 2048 ] || fail 'compressed IPK underestimated'
printf invalid > "$TMP_DIR/broken.ipk"
if package_payload_size_kb "$TMP_DIR/broken.ipk" >/dev/null 2>&1; then fail 'broken IPK accepted'; fi
apk() { printf 'info:\n  installed-size: 999999999\npaths:\n        size: 2097152\n        size: 1\n'; }
PKG_IS_APK=1
[ "$(package_payload_size_kb "$TMP_DIR/tiny.apk")" = 2049 ] || fail 'APK payload rounding wrong'
apk() { printf 'info:\n  installed-size: invalid\n'; }
if package_payload_size_kb "$TMP_DIR/tiny.apk" >/dev/null 2>&1; then fail 'invalid APK size accepted'; fi
echo 'installer sing-box storage checks passed'
