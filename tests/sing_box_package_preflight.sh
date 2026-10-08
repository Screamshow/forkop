#!/bin/sh
set -eu

# Run on OpenWrt with FORKOP_TEST_LIB, FORKOP_TEST_PACKAGE,
# FORKOP_TEST_PACKAGE_NAME and FORKOP_TEST_PACKAGE_VERSION set.
lib="${FORKOP_TEST_LIB:-/usr/lib/forkop}"
action="${FORKOP_TEST_ACTION:-$lib/components/action.uc}"
archive="${FORKOP_TEST_PACKAGE:?missing package archive}"
name="${FORKOP_TEST_PACKAGE_NAME:?missing package name}"
version="${FORKOP_TEST_PACKAGE_VERSION:?missing package version}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
run() { ucode -L "$lib" "$action" "$@"; }

[ "$(run sing-box-writable-path-fixture /usr/bin/sing-box 1 1)" = /overlay/upper/usr/bin/sing-box ] || fail 'overlay path wrong'
[ -z "$(run sing-box-writable-path-fixture /usr/bin/sing-box 0 1)" ] || fail 'ROM file credited'
[ "$(run sing-box-writable-path-fixture /usr/bin/sing-box 0 0)" = /usr/bin/sing-box ] || fail 'writable root rejected'

size_dir="$(mktemp -d)"
trap 'rm -rf "$size_dir"' EXIT
printf test >"$size_dir/present"
: >"$size_dir/empty"
[ "$(run sing-box-file-size-fixture "$size_dir/present")" = 4 ] || fail 'existing file size is wrong'
[ "$(run sing-box-file-size-fixture "$size_dir/empty")" = 0 ] || fail 'empty file size is wrong'
[ "$(run sing-box-file-size-fixture "$size_dir/missing")" = 0 ] || fail 'missing optional library invalidates backup size'
ln -s "$size_dir/present" "$size_dir/link"
[ "$(run sing-box-writable-file-size-fixture "$size_dir/link")" = 0 ] || fail 'symlink target credited'
ln "$size_dir/present" "$size_dir/hardlink"
[ "$(run sing-box-writable-file-size-fixture "$size_dir/present")" = 0 ] || fail 'shared hardlink credited'
rm "$size_dir/hardlink"
[ "$(run sing-box-writable-file-size-fixture "$size_dir/present")" = 4 ] || fail 'regular writable file not credited'

info="$(run sing-box-package-info-fixture "$archive" "$name" "$version")" ||
  fail 'valid package metadata rejected'
[ "$(printf '%s\n' "$info" | jsonfilter -e '@.name')" = "$name" ] ||
  fail 'package name mismatch'
[ "$(printf '%s\n' "$info" | jsonfilter -e '@.version')" = "$version" ] ||
  fail 'package version mismatch'
if [ -n "${FORKOP_TEST_EXPECT_PAYLOAD_BYTES:-}" ]; then
  [ "$(printf '%s\n' "$info" | jsonfilter -e '@.size')" = "$FORKOP_TEST_EXPECT_PAYLOAD_BYTES" ] ||
    fail 'payload differs from actual packed package files'
fi
if [ -n "${FORKOP_TEST_MIN_INSTALLED_BYTES:-}" ]; then
  [ "$(printf '%s\n' "$info" | jsonfilter -e '@.size')" -ge "$FORKOP_TEST_MIN_INSTALLED_BYTES" ] ||
    fail 'installed size underestimates the unpacked package'
fi
if run sing-box-package-info-fixture "$archive" wrong-package "$version" >/dev/null 2>&1; then
  fail 'wrong package name accepted'
fi
if run sing-box-package-info-fixture "$archive" "$name" wrong-version >/dev/null 2>&1; then
  fail 'wrong package version accepted'
fi
if run sing-box-package-info-fixture /tmp/nonexistent-sing-box-package "$name" "$version" >/dev/null 2>&1; then
  fail 'missing package accepted'
fi

# Actual blocks after removal, independent of filesystem/compression.
run sing-box-space-fixture 200000 200000 33576419 0 >/dev/null || fail 'ample free space rejected'
run sing-box-space-fixture 32457 200000 31138816 0 >/dev/null || fail 'exact installation reserve rejected'
if run sing-box-space-fixture 32456 200000 31138816 0 >/dev/null 2>&1; then fail 'installation reserve ignored'; fi
if run sing-box-space-fixture 1000 200000 9941146 0 >/dev/null 2>&1; then fail 'actual flash shortage ignored'; fi
if run sing-box-space-fixture 200000 1000 9941146 0 >/dev/null 2>&1; then fail 'tmp workspace shortage ignored'; fi
if run sing-box-space-fixture 0 200000 9941146 0 >/dev/null 2>&1; then fail 'unknown capacity accepted'; fi

# Existing writable core already fit. Reserve only growth above that baseline.
run sing-box-rollback-space-fixture 39716 200000 99775488 99000000 0 0 >/dev/null || fail 'Extended rollback counted twice'
run sing-box-rollback-space-fixture 39716 200000 31000000 31000000 0 31000000 >/dev/null || fail 'compressed rollback used ordinary Extended'
run sing-box-space-fixture 39716 200000 9941146 0 >/dev/null || fail 'packed X payload rejected'
# ROM never freed writable storage: reinstalling it needs its full payload.
if run sing-box-rollback-space-fixture 39716 200000 99775488 0 0 0 >/dev/null 2>&1; then fail 'ROM rollback capacity ignored'; fi
if run sing-box-rollback-space-fixture 39716 20000 31000000 31000000 0 31000000 >/dev/null 2>&1; then fail 'compressed backup tmp shortage ignored'; fi
# A failed opkg transaction can retain newly installed target dependencies.
run sing-box-rollback-space-fixture 10240 200000 100000000 100000000 8388608 0 >/dev/null || fail 'exact dependency reserve rejected'
if run sing-box-rollback-space-fixture 10239 200000 100000000 100000000 8388608 0 >/dev/null 2>&1; then fail 'dependency recovery reserve ignored'; fi
if run sing-box-rollback-space-fixture 2047 200000 100000000 100000000 0 0 >/dev/null 2>&1; then fail 'recovery workspace reserve ignored'; fi
printf '%s\n' 'sing-box package metadata and storage preflight: OK'
