#!/bin/sh
set -eu
REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$REPO/forkop/files/usr/lib/full-uninstall.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fixture() {
    ROOT="$WORK/$1"
    mkdir -p "$ROOT/etc/opkg" "$ROOT/usr/bin" "$ROOT/bin" "$ROOT/packages" \
        "$ROOT/etc/forkop" "$ROOT/etc/sing-box" "$ROOT/etc/config" "$ROOT/usr/lib/forkop"
    printf 'original vendor repositories\n' > "$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
    printf 'https://mirror.51343.ru/openwrt/releases/test\n' > "$ROOT/etc/opkg/distfeeds.conf"
    printf 'wifi configuration\n' > "$ROOT/etc/config/wireless"
    touch "$ROOT/etc/config/wireless.apk-new"
    touch "$ROOT/etc/config/forkop.apk-new" "$ROOT/etc/config/forkop.apk-old" \
        "$ROOT/etc/config/forkop-opkg" "$ROOT/etc/config/forkop.opkg-new" \
        "$ROOT/etc/config/forkop.opkg-old" "$ROOT/etc/config/forkop.opkg-dist"
    touch "$ROOT/etc/config/sing-box.apk-new" "$ROOT/etc/config/sing-box.apk-old" \
        "$ROOT/etc/config/sing-box-opkg" "$ROOT/etc/config/sing-box.opkg-new" \
        "$ROOT/etc/config/sing-box.opkg-old" "$ROOT/etc/config/sing-box.opkg-dist"
    touch "$ROOT/etc/forkop/secret" "$ROOT/etc/sing-box/config.json" "$ROOT/usr/lib/forkop/test"
    touch "$ROOT/packages/forkop" "$ROOT/packages/luci-app-forkop" "$ROOT/packages/sing-box"
    cat > "$ROOT/usr/bin/forkop" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$FORKOP_UNINSTALL_ROOT/service-calls"
exit "${FAIL_STOP:-0}"
SH
    cat > "$ROOT/bin/opkg" <<'SH'
#!/bin/sh
case "$1" in
 status) [ -e "$FORKOP_UNINSTALL_ROOT/packages/$2" ] && echo 'Status: install ok installed';;
 remove)
  [ "${FAIL_PACKAGE:-0}" = 0 ] || exit 1
  shift
  for p in "$@"; do rm -f "$FORKOP_UNINSTALL_ROOT/packages/$p"; done;;
 *) exit 1;;
esac
SH
    chmod +x "$ROOT/usr/bin/forkop" "$ROOT/bin/opkg"
}

run_case() {
    FORKOP_UNINSTALL_ROOT="$ROOT" PATH="$ROOT/bin:$PATH" sh "$SCRIPT" start > "$ROOT/response"
    count=0
    while :; do
        status="$(cat "$ROOT"/www/forkop-uninstall.*.json)"
        case "$status" in *'"state":"complete"'*|*'"state":"failed"'*) break;; esac
        count=$((count+1))
        [ "$count" -lt 20 ] || { echo 'worker timed out'; exit 1; }
        sleep 1
    done
    printf '%s\n' "$status" | grep -q "\"state\":\"$1\""
}

fixture opkg
run_case complete
grep -qx 'original vendor repositories' "$ROOT/etc/opkg/distfeeds.conf"
[ ! -e "$ROOT/usr/lib/forkop" ] && [ ! -e "$ROOT/etc/forkop" ] && [ ! -e "$ROOT/etc/sing-box" ]
[ ! -e "$ROOT/packages/forkop" ]
grep -qx 'wifi configuration' "$ROOT/etc/config/wireless"
[ -e "$ROOT/etc/config/wireless.apk-new" ]
for file in forkop.apk-new forkop.apk-old forkop-opkg forkop.opkg-new forkop.opkg-old \
    forkop.opkg-dist sing-box.apk-new sing-box.apk-old sing-box-opkg sing-box.opkg-new \
    sing-box.opkg-old sing-box.opkg-dist; do
    [ ! -e "$ROOT/etc/config/$file" ]
done
grep -qx dnsmasq_restore "$ROOT/service-calls"

fixture missing_backup
rm "$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
run_case failed
[ -e "$ROOT/packages/forkop" ] && [ -e "$ROOT/etc/forkop/secret" ]
[ ! -e "$ROOT/service-calls" ]

fixture rom_fallback
rm "$ROOT/etc/opkg/distfeeds.conf.pre-forkop-mirror"
mkdir -p "$ROOT/rom/etc/opkg"
printf 'firmware repositories\n' > "$ROOT/rom/etc/opkg/distfeeds.conf"
run_case complete
grep -qx 'firmware repositories' "$ROOT/etc/opkg/distfeeds.conf"

fixture failed_package
export FAIL_PACKAGE=1
run_case failed
unset FAIL_PACKAGE
[ -e "$ROOT/packages/forkop" ] && [ -e "$ROOT/usr/lib/forkop/test" ]

fixture apk
mkdir -p "$ROOT/etc/apk/repositories.d" "$ROOT/etc/apk/keys"
printf 'https://mirror.51343.ru/openwrt/releases/test\n' > "$ROOT/etc/apk/repositories.d/distfeeds.list"
printf 'original apk repositories\n' > "$ROOT/etc/apk/repositories.d/distfeeds.list.pre-forkop-mirror"
touch "$ROOT/etc/apk/repositories.d/forkop.list" "$ROOT/etc/apk/keys/forkop-mirror.pem"
cat > "$ROOT/bin/apk" <<'SH'
#!/bin/sh
case "$1" in
 info) test -f "$FORKOP_UNINSTALL_ROOT/packages/$3";;
 del) shift; for p in "$@"; do rm -f "$FORKOP_UNINSTALL_ROOT/packages/$p"; done;;
 *) exit 1;;
esac
SH
chmod +x "$ROOT/bin/apk"
run_case complete
grep -qx 'original apk repositories' "$ROOT/etc/apk/repositories.d/distfeeds.list"
[ ! -e "$ROOT/etc/apk/repositories.d/forkop.list" ] && [ ! -e "$ROOT/etc/apk/keys/forkop-mirror.pem" ]
printf 'Full uninstall checks passed\n'
