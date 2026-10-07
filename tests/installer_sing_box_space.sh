#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
# Source only storage helpers, without executing the installer.
source <(awk '/^package_reclaimable_space_kb\(\)/ {copy=1} /^download_sing_box_tiny_package\(\)/ {copy=0} copy' "$ROOT_DIR/install.sh")
sing_box_credit_supported ext4 || fail 'ext4 rejected'
sing_box_credit_supported f2fs unsupported || fail 'uncompressed F2FS rejected'
for filesystem in ubifs jffs2 squashfs overlay unknown; do
  if sing_box_credit_supported "$filesystem"; then fail "$filesystem received logical size credit"; fi
done
for compression in supported enabled ''; do
  if sing_box_credit_supported f2fs "$compression"; then fail 'unknown/compressible F2FS received credit'; fi
done
# A tiny compressed archive must still budget its full extracted payload.
mkdir -p "$TMP_DIR/data/usr/bin" "$TMP_DIR/package"
dd if=/dev/zero of="$TMP_DIR/data/usr/bin/sing-box" bs=1024 count=2048 status=none
tar -czf "$TMP_DIR/package/data.tar.gz" -C "$TMP_DIR/data" .
tar -czf "$TMP_DIR/tiny.ipk" -C "$TMP_DIR/package" .
PKG_IS_APK=0
[ "$(sing_box_payload_size_kb "$TMP_DIR/tiny.ipk")" = 2048 ] || fail 'compressed IPK underestimated'
printf invalid > "$TMP_DIR/broken.ipk"
if sing_box_payload_size_kb "$TMP_DIR/broken.ipk" >/dev/null 2>&1; then fail 'broken IPK accepted'; fi
apk() { printf 'info:\n  installed-size: 2097153\n'; }
PKG_IS_APK=1
[ "$(sing_box_payload_size_kb "$TMP_DIR/tiny.apk")" = 2049 ] || fail 'APK payload rounding wrong'
apk() { printf 'info:\n  installed-size: invalid\n'; }
if sing_box_payload_size_kb "$TMP_DIR/tiny.apk" >/dev/null 2>&1; then fail 'invalid APK size accepted'; fi
echo 'installer sing-box storage checks passed'
