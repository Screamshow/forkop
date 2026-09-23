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

info="$(run sing-box-package-info-fixture "$archive" "$name" "$version")" ||
  fail 'valid package metadata rejected'
[ "$(printf '%s\n' "$info" | jsonfilter -e '@.name')" = "$name" ] ||
  fail 'package name mismatch'
[ "$(printf '%s\n' "$info" | jsonfilter -e '@.version')" = "$version" ] ||
  fail 'package version mismatch'
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

run sing-box-space-fixture 200000 200000 33576419 33576419 0 >/dev/null ||
  fail 'ample free space rejected'
if run sing-box-space-fixture 1000 200000 33576419 0 0 >/dev/null 2>&1; then
  fail 'flash shortage accepted'
fi
if run sing-box-space-fixture 200000 1000 33576419 0 0 >/dev/null 2>&1; then
  fail 'tmp shortage accepted'
fi
if run sing-box-space-fixture 200000 10000 33576419 0 33576419 >/dev/null 2>&1; then
  fail 'tmp backup shortage accepted'
fi
if run sing-box-space-fixture 0 200000 33576419 0 0 >/dev/null 2>&1; then
  fail 'unknown flash capacity accepted'
fi
run sing-box-space-fixture 140000 200000 80000000 70000000 0 0 >/dev/null ||
  fail 'old installed package counted twice against free space'
if run sing-box-space-fixture 100000 200000 80000000 70000000 0 0 >/dev/null 2>&1; then
  fail 'target extraction overhead ignored'
fi
if run sing-box-space-fixture 100000 200000 30000000 100000000 0 0 >/dev/null 2>&1; then
  fail 'rollback capacity ignored'
fi
run sing-box-space-fixture 100000 200000 80000000 70000000 0 20000000 >/dev/null ||
  fail 'verified writable binary credit rejected'
if run sing-box-space-fixture 116702 200000 107121058 30382512 0 22786884 >/dev/null 2>&1; then
  fail 'real Extended IPK threshold accepted below required free space'
fi
run sing-box-space-fixture 116703 200000 107121058 30382512 0 22786884 >/dev/null ||
  fail 'real Extended IPK threshold rejected at required free space'
run sing-box-space-fixture 140000 200000 80000000 70000000 0 60000000 >/dev/null ||
  fail 'verified writable binary credit rejected'

printf '%s\n' 'sing-box package metadata and storage preflight: OK'
