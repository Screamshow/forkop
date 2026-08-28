#!/bin/sh
set -eu

MIRROR_BASE_URL="${FORKOP_MIRROR_BASE_URL:-https://mirror.51343.ru}"
MIRROR_BASE_URL="${MIRROR_BASE_URL%/}"
MIGRATION_ID="mirror_51343_ru_v1"
SETTINGS_SECTION="forkop.settings"
MIGRATION_ROOT="${FORKOP_MIGRATION_ROOT:-}"
APK_BIN="${FORKOP_MIGRATION_APK_BIN:-apk}"
CURL_BIN="${FORKOP_MIGRATION_CURL_BIN:-curl}"
UCI_BIN="${FORKOP_MIGRATION_UCI_BIN:-uci}"

command -v "$APK_BIN" >/dev/null 2>&1 || exit 0

root_path() {
    printf '%s%s\n' "$MIGRATION_ROOT" "$1"
}

rewrite_repository_file() {
    repository_file="$1"
    [ -e "$repository_file" ] || return 0

    temporary="${repository_file}.forkop-mirror-new"
    sed -E \
        "s#https?://[^/]+/(pub/software/openwrt/)?releases/#${MIRROR_BASE_URL}/openwrt/releases/#" \
        "$repository_file" > "$temporary"

    if grep -E 'https?://[^/]+/(pub/software/openwrt/)?releases/' "$temporary" |
        grep -Fv "$MIRROR_BASE_URL/openwrt/releases/" >/dev/null; then
        rm -f "$temporary"
        echo "Forkop mirror migration could not rewrite every URL in $repository_file" >&2
        return 1
    fi

    backup="${repository_file}.pre-forkop-mirror"
    [ -e "$backup" ] || cp "$repository_file" "$backup"
    mv "$temporary" "$repository_file"
}

case "$MIRROR_BASE_URL" in
    https://*|http://*) ;;
    *) echo "Invalid Forkop mirror URL: $MIRROR_BASE_URL" >&2; exit 1 ;;
esac

repositories="$(root_path /etc/apk/repositories)"
repositories_dir="$(root_path /etc/apk/repositories.d)"
keys_dir="$(root_path /etc/apk/keys)"

rewrite_repository_file "$repositories"
rewrite_repository_file "$repositories_dir/distfeeds.list"

mkdir -p "$keys_dir" "$repositories_dir"
key_tmp="$keys_dir/forkop-mirror.pem.new"
if ! "$CURL_BIN" -fsSL --connect-timeout 15 --max-time 60 \
    "$MIRROR_BASE_URL/forkop/forkop-apk.pem" -o "$key_tmp"; then
    rm -f "$key_tmp"
    echo "Unable to download the Forkop mirror APK key" >&2
    exit 1
fi
grep -Fq 'BEGIN PUBLIC KEY' "$key_tmp" || {
    rm -f "$key_tmp"
    echo "The downloaded Forkop mirror APK key is invalid" >&2
    exit 1
}
mv "$key_tmp" "$keys_dir/forkop-mirror.pem"
chmod 0644 "$keys_dir/forkop-mirror.pem"

printf '%s\n' "$MIRROR_BASE_URL/forkop/mirror/current/packages.adb" \
    > "$repositories_dir/forkop.list"

"$UCI_BIN" -q set "$SETTINGS_SECTION.mirror_base_url=$MIRROR_BASE_URL"
if ! "$UCI_BIN" -q get "$SETTINGS_SECTION.applied_migrations" 2>/dev/null |
    tr ' ' '\n' | grep -Fxq "$MIGRATION_ID"; then
    "$UCI_BIN" -q add_list "$SETTINGS_SECTION.applied_migrations=$MIGRATION_ID"
fi
"$UCI_BIN" -q commit forkop

exit 0
