#!/bin/sh
set -eu

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INSTALLER="$REPO/install.sh"
MIGRATION="$REPO/forkop/files/usr/share/forkop/mirror-migration.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

sh "$INSTALLER" --help | grep -Fq -- '--channel stable|canary' || fail 'installer channel option missing'
grep -Fq 'updates/${FORKOP_CHANNEL}.json' "$INSTALLER" || fail 'installer channel manifest missing'
grep -Fq 'MIRROR_SUPPORTED=1' "$INSTALLER" || fail 'mirror supported discriminator missing'
grep -Fq 'keeping native OpenWrt feeds' "$INSTALLER" || fail 'native fallback missing'
grep -Fq '/forkop/updates/" + forkop_update_channel() + ".json' "$REPO/forkop/files/usr/lib/components/action.uc" || fail 'runtime channel lookup missing'

make_root() {
  root="$1"
  target="$2"
  arch="$3"
  mkdir -p "$root/etc/opkg" "$root/etc/apk/repositories.d" "$root/etc/apk/keys" "$root/bin"
  printf "DISTRIB_TARGET='%s'\nDISTRIB_ARCH='%s'\n" "$target" "$arch" >"$root/etc/openwrt_release"
  printf 'native-feed\n' >"$root/etc/opkg/distfeeds.conf.pre-forkop-mirror"
  printf 'https://mirror.51343.ru/openwrt/releases/test\n' >"$root/etc/opkg/distfeeds.conf"
  printf '#!/bin/sh\nexit 0\n' >"$root/bin/opkg"
  printf '#!/bin/sh\nexit 0\n' >"$root/bin/uci"
  chmod +x "$root/bin/opkg" "$root/bin/uci"
}

native="$WORK/native"
make_root "$native" x86/64 x86_64
PATH="$native/bin:$PATH" FORKOP_MIGRATION_APK_BIN="$native/bin/missing-apk" FORKOP_MIGRATION_ROOT="$native" sh "$MIGRATION"
[ "$(cat "$native/etc/opkg/distfeeds.conf")" = native-feed ] || fail 'unsupported target did not restore Forkop backup'
[ ! -e "$native/etc/opkg/distfeeds.conf.pre-forkop-mirror" ] || fail 'restored backup was retained'

supported="$WORK/supported"
make_root "$supported" mediatek/filogic aarch64_cortex-a53
printf 'src/gz base https://downloads.openwrt.org/releases/24.10.8/packages/aarch64_cortex-a53/base\n' >"$supported/etc/opkg/distfeeds.conf"
PATH="$supported/bin:$PATH" FORKOP_MIGRATION_APK_BIN="$supported/bin/missing-apk" FORKOP_MIGRATION_ROOT="$supported" sh "$MIGRATION"
grep -Fq 'https://mirror.51343.ru/openwrt/releases/' "$supported/etc/opkg/distfeeds.conf" || fail 'supported target lost mirror path'

echo 'channel architecture tests passed'
