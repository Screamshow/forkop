#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"

cleanup_test() {
  rm -rf "$WORK_DIR"
}
trap cleanup_test EXIT

fail_test() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

sed '/^main "\$@"$/d' "$ROOT_DIR/install.sh" > "$WORK_DIR/install-library.sh"
# shellcheck disable=SC1090
. "$WORK_DIR/install-library.sh"

TMP_DIR="$WORK_DIR/tmp"
MIRROR_BASE_URL="https://mirror.51343.ru"
mkdir -p "$TMP_DIR" "$WORK_DIR/etc/opkg"
distfeeds="$WORK_DIR/etc/opkg/distfeeds.conf"
cat > "$distfeeds" <<'EOF'
src/gz openwrt_core https://downloads.openwrt.org/releases/24.10.7/targets/mediatek/filogic/packages
src/gz openwrt_base https://archive.openwrt.org/releases/24.10.7/packages/aarch64_cortex-a53/base
src/gz glinet_core https://fw.gl-inet.com/releases/v24.x/24.10.4/mediatek/filogic
src/gz glinet_core_slash https://fw.gl-inet.com/releases/v24.x/v24.10.4/mediatek/filogic/
https://downloads.openwrt.org/releases/v25.x/v25.12.5/mediatek/filogic/packages/packages.adb
https://downloads.openwrt.org/releases/v25.x/v25.12.5/aarch64_cortex-a53/video/packages.adb
https://ftp.halifax.rwth-aachen.de/openwrt/releases/25.12.3/targets/mediatek/filogic/packages/packages.adb
EOF
cp "$distfeeds" "$WORK_DIR/original"

begin_package_mirror_transaction
rewrite_package_repository_file "$distfeeds"
grep -Fq 'https://mirror.51343.ru/openwrt/releases/24.10.7/' "$distfeeds" ||
  fail_test "transaction did not rewrite OpenWrt 24 feeds"
grep -Fxq 'src/gz glinet_core https://mirror.51343.ru/openwrt/releases/24.10.4/targets/mediatek/filogic/packages' "$distfeeds" ||
  fail_test "transaction did not normalize a GL.iNet mediatek/filogic OPKG feed"
grep -Fxq 'src/gz glinet_core_slash https://mirror.51343.ru/openwrt/releases/24.10.4/targets/mediatek/filogic/packages' "$distfeeds" ||
  fail_test "transaction did not normalize the v-prefixed, slash-terminated GL.iNet OPKG feed"
grep -Fxq 'https://mirror.51343.ru/openwrt/releases/25.12.5/targets/mediatek/filogic/packages/packages.adb' "$distfeeds" ||
  fail_test "transaction did not normalize an OpenWrt 25 target feed"
grep -Fxq 'https://mirror.51343.ru/openwrt/releases/25.12.5/packages/aarch64_cortex-a53/video/packages.adb' "$distfeeds" ||
  fail_test "transaction did not normalize an OpenWrt 25 package feed"
grep -Fxq 'https://mirror.51343.ru/openwrt/releases/25.12.3/targets/mediatek/filogic/packages/packages.adb' "$distfeeds" ||
  fail_test "transaction did not redirect an OpenWrt mirror using the /openwrt/releases path"
[ -s "$distfeeds.pre-forkop-mirror" ] ||
  fail_test "transaction did not create a persistent recovery copy"

rollback_package_mirror
cmp -s "$WORK_DIR/original" "$distfeeds" ||
  fail_test "transaction rollback did not restore original feeds"

begin_package_mirror_transaction
rewrite_package_repository_file "$distfeeds"
commit_package_mirror_transaction
cleanup
mkdir -p "$TMP_DIR"
grep -Fq 'https://mirror.51343.ru/openwrt/releases/24.10.7/' "$distfeeds" ||
  fail_test "committed transaction was unexpectedly rolled back"

PKG_IS_APK=1
apk() {
  case "$1:$2:$3" in
    'info:-e:sing-box-tiny') printf '%s\n' 'sing-box-tiny'; return 0 ;;
    'info:-e:sing-box') printf '%s\n' 'sing-box-tiny'; return 0 ;;
    'info:-W:/usr/bin/sing-box') printf '%s\n' '/usr/bin/sing-box is owned by sing-box-tiny-1.13.18-r1'; return 0 ;;
  esac
  return 1
}
installed_sing_box_package | grep -Fxq 'sing-box-tiny' ||
  fail_test "APK ownership lookup did not recognize sing-box-tiny"
if pkg_is_installed sing-box; then
  fail_test "APK virtual sing-box dependency was mistaken for the normal sing-box package"
fi

routerich_feeds="$WORK_DIR/etc/opkg/routerich-distfeeds.conf"
cat >"$routerich_feeds" <<'EOF'
src/gz routerich_core https://packages.routerich.ru/24.10/mediatek/filogic/24.10.6/core
src/gz routerich_base https://packages.routerich.ru/24.10/mediatek/filogic/24.10.6/base
src/gz routerich_luci https://packages.routerich.ru/24.10/mediatek/filogic/24.10.6/luci
src/gz routerich_packages https://packages.routerich.ru/24.10/mediatek/filogic/24.10.6/packages
src/gz routerich_routing https://packages.routerich.ru/24.10/mediatek/filogic/24.10.6/routing
src/gz routerich_telephony https://packages.routerich.ru/24.10/mediatek/filogic/24.10.6/telephony
src/gz routerich https://packages.routerich.ru/24.10/mediatek/filogic/routerich
EOF
cp "$routerich_feeds" "$WORK_DIR/routerich-original"
OPKG_DISTFEEDS_FILE="$routerich_feeds"
PKG_IS_APK=0
repository_file_has_vendor_origin "$routerich_feeds" ||
  fail_test "Routerich OPKG feeds must select native-feeds mode"
cmp -s "$WORK_DIR/routerich-original" "$routerich_feeds" ||
  fail_test "Routerich OPKG feeds must remain byte-for-byte unchanged"

# Native fallback must recover only a still-live Forkop rewrite before the
# package-manager update; a later vendor/user edit is authoritative.
legacy_native="$WORK_DIR/etc/opkg/legacy-native.conf"
printf '%s\n' 'src/gz core https://mirror.51343.ru/openwrt/releases/24.10.5/packages/aarch64_cortex-a53/base' >"$legacy_native"
printf '%s\n' 'src/gz core https://downloads.openwrt.org/releases/24.10.5/packages/aarch64_cortex-a53/base' >"${legacy_native}.pre-forkop-mirror"
restore_native_repository_file "$legacy_native"
grep -Fq 'downloads.openwrt.org' "$legacy_native" ||
  fail_test "native fallback did not restore a Forkop-owned OPKG mirror rewrite"
[ ! -e "${legacy_native}.pre-forkop-mirror" ] ||
  fail_test "restored OPKG backup was not consumed"

printf '%s\n' 'src/gz vendor https://vendor.example.invalid/feed' >"$legacy_native"
printf '%s\n' 'src/gz core https://downloads.openwrt.org/releases/24.10.5/packages/aarch64_cortex-a53/base' >"${legacy_native}.pre-forkop-mirror"
restore_native_repository_file "$legacy_native"
grep -Fq 'vendor.example.invalid' "$legacy_native" ||
  fail_test "native fallback overwrote a later vendor/user OPKG edit"

printf 'Installer feed transaction tests passed\n'
