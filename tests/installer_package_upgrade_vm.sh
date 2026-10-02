#!/bin/sh
# Run only on an existing test VM after capturing package and service state.
# The directory must contain install.sh and baseline/, target/, original/ packages.
set -eu
ROOT=${1:?staged test directory required}
TARGET_VERSION=${2:-1.15.0}
if command -v apk >/dev/null 2>&1; then PKG_IS_APK=1; EXT=apk; else PKG_IS_APK=0; EXT=ipk; fi
EXPECTED_PACKAGE_VERSION=$TARGET_VERSION
if [ "$PKG_IS_APK" = 1 ]; then
    EXPECTED_PACKAGE_VERSION=$(printf '%s\n' "$TARGET_VERSION" | sed 's/-canary\./_rc/')
fi
TMP_DIR="$ROOT/adapter"
mkdir -p "$TMP_DIR"
sed -n '/^prepare_package_init_adapter() {/,/^}/p; /^pkg_install_files() {/,/^}/p' "$ROOT/install.sh" > "$ROOT/functions.sh"
. "$ROOT/functions.sh"
prepare_package_init_adapter
cp -p /etc/config/forkop "$ROOT/config.original"
WAS_RUNNING=0
/etc/init.d/forkop status >/dev/null 2>&1 && WAS_RUNNING=1
restore() {
    status=$?
    trap - EXIT
    /etc/init.d/forkop stop >/dev/null 2>&1 || true
    if [ "$PKG_IS_APK" = 1 ]; then
        apk --preserve-env add --allow-untrusted --force-reinstall "$ROOT"/original/*.apk || exit 1
    else
        opkg install --force-overwrite --force-downgrade --force-reinstall "$ROOT"/original/*.ipk || exit 1
    fi
    cp -p "$ROOT/config.original" /etc/config/forkop
    if [ "$WAS_RUNNING" = 1 ]; then /etc/init.d/forkop start; else /etc/init.d/forkop stop; fi
    cmp "$ROOT/config.original" /etc/config/forkop
    echo "Original packages, configuration and service state restored"
    exit "$status"
}
trap restore EXIT
"$FORKOP_INIT" stop
if [ "$PKG_IS_APK" = 1 ]; then
    apk --preserve-env add --allow-untrusted --force-reinstall "$ROOT"/baseline/*.apk
else
    opkg install --force-overwrite --force-downgrade --force-reinstall "$ROOT"/baseline/*.ipk
fi
if [ "$WAS_RUNNING" = 1 ]; then /etc/init.d/forkop start; fi
# Match the installer's stop followed by old-package prerm stop.
"$FORKOP_INIT" stop
cp -p /etc/config/forkop "$ROOT/config.baseline"
# Lifecycle changes this runtime marker when stopping or restoring the service.
sed '/^[[:space:]]*option shutdown_correctly[[:space:]]/d' "$ROOT/config.baseline" > "$ROOT/config.expected"
for run in 1 2; do
    for name in forkop luci-app-forkop luci-i18n-forkop-ru; do
        pkg_install_files "$ROOT/target/${name}_$TARGET_VERSION.$EXT"
        version=$(ucode -L /usr/lib/forkop /usr/lib/forkop/core/packages.uc version "$name")
        [ "$version" = "$EXPECTED_PACKAGE_VERSION" ]
    done
    cp -p /etc/config/forkop "$ROOT/config.target.$run"
    sed '/^[[:space:]]*option shutdown_correctly[[:space:]]/d' /etc/config/forkop > "$ROOT/config.actual"
    cmp "$ROOT/config.expected" "$ROOT/config.actual"
    echo "PASS: package upgrade/repeat $run ($EXT), configuration preserved"
done
