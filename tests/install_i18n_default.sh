#!/bin/sh
set -eu

installer="${1:-install.sh}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Load the actual installer functions without executing its main workflow.
functions="$(sed -n '/^decide_i18n_installation() {/,/^}/p; /^resolve_forkop_release() {/,/^}/p; /^download_forkop_packages() {/,/^}/p; /^install_ui_packages() {/,/^}/p' "$installer")"
[ -n "$functions" ] || fail 'installer functions not found'
eval "$functions"

detect_installer_language() { INSTALLER_LANG="$MOCK_LUCI_LANG"; }
pkg_is_installed() { [ "$MOCK_I18N_INSTALLED" = 1 ]; }
installer_text() { printf '%s' "$1"; }
msg() { MESSAGE="$1"; }
pkg_install_files() { INSTALLED="${INSTALLED}${INSTALLED:+ }$1"; }
fetch_forkop_latest_release_json() { printf '{}'; }
mirror_asset_url() { printf 'https://mirror.test%s\n' "$1"; }
install_json_ucode() {
    case "$1:${2-}:${3-}" in
        release-tag::) printf 'v1.14.3\n' ;;
        release-asset-url:backend:*) printf '/forkop_1.14.3.%s\n' "$3" ;;
        release-asset-url:app:*) printf '/luci-app-forkop_1.14.3.%s\n' "$3" ;;
        release-asset-url:i18n:*)
            [ "${MOCK_NO_I18N:-0}" = 1 ] ||
                printf '/luci-i18n-forkop-ru_1.14.3.%s\n' "$3" ;;
    esac
}
download_with_retry() { DOWNLOADED="${DOWNLOADED}${DOWNLOADED:+ }$3"; }
verify_download_sha256() { :; }
fail() { printf 'installer rejected missing required package: %s\n' "$1" >&2; exit 1; }

for mode in clean update; do
    for lang in en ru; do
        MOCK_LUCI_LANG="$lang"
        MOCK_I18N_INSTALLED=0
        FORKOP_I18N_REQUESTED=0
        INSTALL_MODE="$mode"
        MESSAGE=""
        decide_i18n_installation
        [ "$FORKOP_I18N_REQUESTED" -eq 1 ] || fail "$mode/$lang omitted Russian package"
        [ "$INSTALLER_LANG" = "$lang" ] || fail "$mode/$lang changed installer language"
        [ "$MESSAGE" = i18n_default ] || fail "$mode/$lang default message"
    done
done

MOCK_I18N_INSTALLED=1
MESSAGE=""
decide_i18n_installation
[ "$MESSAGE" = i18n_installed ] || fail 'existing i18n update message'

for ext in ipk apk; do
    PKG_IS_APK=0
    [ "$ext" = apk ] && PKG_IS_APK=1
    TMP_DIR=/tmp/forkop-install-i18n-fixture
    MOCK_NO_I18N=0
    resolve_forkop_release
    [ "$FORKOP_I18N_NAME" = "luci-i18n-forkop-ru_1.14.3.$ext" ] ||
        fail "$ext i18n asset not resolved"
    DOWNLOADED=""
    download_forkop_packages
    [ "$DOWNLOADED" = "forkop_1.14.3.$ext luci-app-forkop_1.14.3.$ext luci-i18n-forkop-ru_1.14.3.$ext" ] ||
        fail "$ext i18n package not downloaded"
    INSTALLED=""
    install_ui_packages
    [ "$INSTALLED" = "$FORKOP_APP_FILE $FORKOP_I18N_FILE" ] ||
        fail "$ext LuCI app and Russian package were not both installed"
    if (MOCK_NO_I18N=1; resolve_forkop_release) >/dev/null 2>&1; then
        fail "$ext accepted release without required Russian package"
    fi
done

printf '%s\n' 'installer includes Russian i18n by default: OK'
