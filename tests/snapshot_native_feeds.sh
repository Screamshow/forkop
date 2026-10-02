#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
fail_test() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$WORK_DIR/root/etc/apk/repositories.d" "$WORK_DIR/bin"
sed '/^main "\$@"$/d' "$ROOT_DIR/install.sh" |
    sed "s#/etc/openwrt_release#$WORK_DIR/root/etc/openwrt_release#g" > "$WORK_DIR/library.sh"
. "$WORK_DIR/library.sh"
TMP_DIR="$WORK_DIR/tmp"
mkdir -p "$TMP_DIR"
APK_REPOSITORIES_FILE="$WORK_DIR/root/etc/apk/repositories"
APK_DISTFEEDS_FILE="$WORK_DIR/root/etc/apk/repositories.d/distfeeds.list"
OPKG_DISTFEEDS_FILE="$WORK_DIR/root/etc/opkg/distfeeds.conf"
PKG_IS_APK=1
for release in SNAPSHOT 25.12-SNAPSHOT; do
    cat > "$WORK_DIR/root/etc/openwrt_release" <<EOF
DISTRIB_RELEASE='$release'
DISTRIB_TARGET='mediatek/filogic'
DISTRIB_ARCH='aarch64_cortex-a53'
EOF
    printf '%s\n' 'https://downloads.openwrt.org/snapshots/targets/mediatek/filogic/packages/packages.adb' > "$APK_DISTFEEDS_FILE"
    printf '%s\n' '# user repository configuration' > "$APK_REPOSITORIES_FILE"
    cp "$APK_DISTFEEDS_FILE" "$WORK_DIR/distfeeds.before"
    cp "$APK_REPOSITORIES_FILE" "$WORK_DIR/repositories.before"
    MIRROR_SUPPORTED=1
    check_system
    [ "$MIRROR_SUPPORTED" = 0 ] || fail_test "$release enabled system mirror"
    configure_package_mirror
    [ "$REPOSITORY_MODE" = native-feeds ] || fail_test "$release selected full mirror"
    cmp "$APK_DISTFEEDS_FILE" "$WORK_DIR/distfeeds.before"
    cmp "$APK_REPOSITORIES_FILE" "$WORK_DIR/repositories.before"

    # Execute the real postinst migration with an isolated root and fake tools.
    printf '#!/bin/sh\nexit 0\n' > "$WORK_DIR/bin/apk"
    printf '#!/bin/sh\nexit 0\n' > "$WORK_DIR/bin/uci"
    printf '#!/bin/sh\nexit 99\n' > "$WORK_DIR/bin/curl"
    chmod +x "$WORK_DIR/bin/"*
    env FORKOP_MIGRATION_ROOT="$WORK_DIR/root" \
        FORKOP_MIGRATION_APK_BIN="$WORK_DIR/bin/apk" \
        FORKOP_MIGRATION_UCI_BIN="$WORK_DIR/bin/uci" \
        FORKOP_MIGRATION_CURL_BIN="$WORK_DIR/bin/curl" \
        sh "$ROOT_DIR/forkop/files/usr/share/forkop/mirror-migration.sh"
    cmp "$APK_DISTFEEDS_FILE" "$WORK_DIR/distfeeds.before"
    cmp "$APK_REPOSITORIES_FILE" "$WORK_DIR/repositories.before"
    [ ! -e "$WORK_DIR/root/etc/apk/repositories.d/forkop.list" ] || fail_test 'migration added a system feed'
done

# Previously redirected branch snapshots recover only their owned backups.
cp "$APK_DISTFEEDS_FILE" "$APK_DISTFEEDS_FILE.pre-forkop-mirror"
printf '%s\n' 'https://mirror.51343.ru/openwrt/releases/25.12-SNAPSHOT/targets/mediatek/filogic/packages/packages.adb' > "$APK_DISTFEEDS_FILE"
configure_package_mirror
cmp "$APK_DISTFEEDS_FILE" "$WORK_DIR/distfeeds.before"

cp "$APK_DISTFEEDS_FILE" "$APK_DISTFEEDS_FILE.pre-forkop-mirror"
printf '%s\n' 'https://mirror.51343.ru/openwrt/releases/25.12-SNAPSHOT/targets/mediatek/filogic/packages/packages.adb' > "$APK_DISTFEEDS_FILE"
env FORKOP_MIGRATION_ROOT="$WORK_DIR/root" \
    FORKOP_MIGRATION_APK_BIN="$WORK_DIR/bin/apk" \
    FORKOP_MIGRATION_UCI_BIN="$WORK_DIR/bin/uci" \
    FORKOP_MIGRATION_CURL_BIN="$WORK_DIR/bin/curl" \
    sh "$ROOT_DIR/forkop/files/usr/share/forkop/mirror-migration.sh"
cmp "$APK_DISTFEEDS_FILE" "$WORK_DIR/distfeeds.before"

# A user's subsequent feed edit remains authoritative over an old backup.
cp "$APK_DISTFEEDS_FILE" "$APK_DISTFEEDS_FILE.pre-forkop-mirror"
printf '%s\n' 'https://example.test/custom/packages.adb' > "$APK_DISTFEEDS_FILE"
configure_package_mirror
grep -Fxq 'https://example.test/custom/packages.adb' "$APK_DISTFEEDS_FILE" || fail_test 'user feed edit overwritten'

# Stable Filogic releases retain the existing full mirror behavior.
sed "s/25.12-SNAPSHOT/25.12.5/" "$WORK_DIR/root/etc/openwrt_release" > "$WORK_DIR/release.stable"
cp "$WORK_DIR/release.stable" "$WORK_DIR/root/etc/openwrt_release"
check_system
resolve_repository_mode
[ "$MIRROR_SUPPORTED" = 1 ] && [ "$REPOSITORY_MODE" = full-mirror ] || fail_test 'stable mirror disabled'
echo 'snapshot native feed tests passed'
