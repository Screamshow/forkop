#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"
CONFIG="$ROOT_DIR/forkop/files/etc/config/forkop"

sh -n "$INSTALLER"

grep -Fq 'MIRROR_BASE_URL="${FORKOP_MIRROR_BASE_URL:-https://mirror.51343.ru}"' "$INSTALLER" || {
    echo "installer does not default to the Forkop mirror" >&2
    exit 1
}
grep -Fq 'configure_apk_mirror' "$INSTALLER" || {
    echo "installer does not configure mirrored OpenWrt feeds" >&2
    exit 1
}
grep -Fq 'configure_opkg_mirror' "$INSTALLER" || {
    echo "installer does not configure OpenWrt 24 OPKG feeds" >&2
    exit 1
}
grep -Fq 'repository_file_has_vendor_origin' "$INSTALLER" || {
    echo "installer does not preserve vendor repository origins" >&2
    exit 1
}
grep -Fq 'REPOSITORY_MODE="native-feeds"' "$INSTALLER" || {
    echo "installer does not default uncertain platforms to native feeds" >&2
    exit 1
}
grep -Fq 'MIRROR_TRANSACTION_ACTIVE=1' "$INSTALLER" || {
    echo "installer feed changes are not transactional" >&2
    exit 1
}
grep -Fq 'rollback_package_mirror' "$INSTALLER" || {
    echo "installer cannot restore feeds after a failed mirror update" >&2
    exit 1
}
grep -Fq 'verify_download_sha256' "$INSTALLER" || {
    echo "installer does not verify downloaded release package hashes" >&2
    exit 1
}
grep -Fq 'release-asset-sha256' "$INSTALLER" || {
    echo "installer does not read release package hashes" >&2
    exit 1
}
grep -Fq 'for repository_file in "$APK_REPOSITORIES_FILE" "$distfeeds"' "$INSTALLER" || {
    echo "installer does not redirect both APK repository locations" >&2
    exit 1
}
grep -Fq 'SING_BOX_INSTALL_VARIANT="tiny"' "$INSTALLER" || {
    echo "installer does not default to sing-box-tiny" >&2
    exit 1
}
grep -Fq "option mirror_base_url 'https://mirror.51343.ru'" "$CONFIG" || {
    echo "packaged Forkop config does not enable the mirror" >&2
    exit 1
}

echo "installer mirror contract tests passed"
