#!/bin/sh
# Integration test for the existing OpenWrt VMs. This changes real packages and
# services, and restores the initial state after each case. Run only on a VM.
set -eu
umask 077
ROOT=/tmp/forkop-update-review
LAB="$ROOT/integration"
TARGET=1.14.9-canary.2
ORIGIN="${1:?original release required}"
MODE="${2:-prepare}"
mkdir -p "$LAB"
if command -v apk >/dev/null 2>&1; then EXT=apk; else EXT=ipk; fi
versions() {
    for name in forkop luci-app-forkop luci-i18n-forkop-ru; do
        ucode -L /usr/lib/forkop /usr/lib/forkop/core/packages.uc version "$name"
    done
}
assert_config() {
    tar -xOzf "${1:-$LAB/config.tar.gz}" etc/config/forkop | tr -d '\r' > "$LAB/expected-config"
    tr -d '\r' < /etc/config/forkop > "$LAB/current-config"
    cmp "$LAB/expected-config" "$LAB/current-config"
}
wait_idle() {
    attempts=120
    while ! ucode -L /usr/lib/forkop /usr/lib/forkop/service/ui.uc service-action-idle; do
        [ "$attempts" -gt 0 ] || return 1
        attempts=$((attempts - 1))
        sleep 1
    done
}
if [ "$MODE" = prepare ]; then
    [ ! -e "$LAB/config.tar.gz" ] || { echo 'snapshot already exists'; exit 1; }
    umask 077
    tar -czf "$LAB/config.tar.gz" -C / etc/config
    [ ! -d /etc/forkop ] || tar -czf "$LAB/persistent.tar.gz" -C / etc/forkop
    [ ! -d /etc/forkop-backups ] || tar -czf "$LAB/backups.tar.gz" -C / etc/forkop-backups
    sha256sum /etc/config/forkop > "$LAB/config.sha256"
    versions > "$LAB/versions.txt"
    if [ "$EXT" = apk ]; then apk list --installed > "$LAB/packages.txt"; cp /etc/apk/world "$LAB/world";
    else opkg list-installed > "$LAB/packages.txt"; fi
    /etc/init.d/forkop enabled && echo 1 > "$LAB/enabled" || echo 0 > "$LAB/enabled"
    /etc/init.d/forkop status > "$LAB/service.txt"
    ubus call service list > "$LAB/services.json"
    mkdir -p "$LAB/www/forkop/updates" "$LAB/original" "$LAB/bin"
    curl -fsSL --max-time 60 https://mirror.51343.ru/forkop/updates/releases.json > "$LAB/www/forkop/updates/releases.json"
    ucode -e 'let fs=require("fs");let root=ARGV[0];let origin=ARGV[1];let target=ARGV[2];let ext=ARGV[3];
        let c=json(fs.readfile(root+"/www/forkop/updates/releases.json"));
        for(let r in c.releases)if(r.tag_name==origin||r.tag_name==target){
            if(r.tag_name==target)fs.writefile(root+"/www/forkop/updates/canary.json",sprintf("%J",r));
            for(let a in r.assets)if(substr(a.name,-length(ext)-1)=="."+ext)
                print(a.browser_download_url,"\t",a.sha256,"\t",r.tag_name,"\n");
        }' "$LAB" "$ORIGIN" "$TARGET" "$EXT" > "$LAB/assets.tsv"
    while IFS="$(printf '\t')" read -r path digest version; do
        mkdir -p "$LAB/www$(dirname "$path")"
        curl -fsSL --max-time 120 "https://mirror.51343.ru$path" -o "$LAB/www$path"
        echo "$digest  $LAB/www$path" | sha256sum -c - >/dev/null
        [ "$version" != "$ORIGIN" ] || cp "$LAB/www$path" "$LAB/original/$(basename "$path")"
    done < "$LAB/assets.tsv"
    echo 'snapshot and verified original/target archives ready'
    exit 0
fi
restore() {
    wait_idle
    if /etc/init.d/forkop status >/dev/null; then /etc/init.d/forkop stop; fi
    tar -xOzf "$LAB/config.tar.gz" etc/config/forkop > /etc/config/forkop
    set -- "$LAB/original/luci-app-forkop_$ORIGIN.$EXT" \
        "$LAB/original/luci-i18n-forkop-ru_$ORIGIN.$EXT" "$LAB/original/forkop_$ORIGIN.$EXT"
    versions > "$LAB/pre-restore-versions.txt"
    if ! cmp -s "$LAB/versions.txt" "$LAB/pre-restore-versions.txt"; then
        if [ "$EXT" = apk ]; then FORKOP_INIT="$ROOT/package-init" /usr/bin/apk --preserve-env add --no-network --allow-untrusted --force-reinstall "$@";
        else FORKOP_INIT="$ROOT/package-init" /bin/opkg install --force-reinstall --force-overwrite --force-downgrade "$@"; fi
    fi
    tar -xOzf "$LAB/config.tar.gz" etc/config/forkop > /etc/config/forkop
    [ ! -f "$LAB/backups.tar.gz" ] || tar -xzf "$LAB/backups.tar.gz" -C /
    if [ "$(cat "$LAB/enabled")" = 1 ]; then /etc/init.d/forkop enable; else /etc/init.d/forkop disable; fi
    /etc/init.d/forkop start
    wait_idle
    versions > "$LAB/restored-versions.txt"
    cmp "$LAB/versions.txt" "$LAB/restored-versions.txt"
    assert_config
    /etc/init.d/forkop status
}
if [ "$MODE" = restore ]; then restore; exit 0; fi
wait_idle
if [ "${FORKOP_VM_TEST_STOPPED:-0}" = 1 ]; then
    /etc/init.d/forkop stop
    /etc/init.d/forkop disable
    wait_idle
fi
tar -czf "$LAB/current-initial.tar.gz" -C / etc/config/forkop
# Both feeds select the same verified target in this isolated transaction test.
cp "$LAB/www/forkop/updates/canary.json" "$LAB/www/forkop/updates/stable.json"
chmod -R a+rX "$LAB/www"
uhttpd -f -p 127.0.0.1:18089 -h "$LAB/www" > "$LAB/http.log" 2>&1 &
HTTP_PID=$!
trap 'kill "$HTTP_PID" 2>/dev/null || true' EXIT
MIRROR=http://127.0.0.1:18089
TEST_INIT=/etc/init.d/forkop
if [ "${FORKOP_VM_DELAY_START:-0}" = 1 ]; then
    TEST_INIT="$LAB/service-init"
    rm -f "$LAB/delayed-start-used"
    cat > "$TEST_INIT" <<'EOF'
#!/bin/sh
if [ "${1:-}" = start ]; then
    touch "$(dirname "$0")/delayed-start-used"
    (sleep 2; /etc/init.d/forkop start) </dev/null >/dev/null 2>&1 &
    exit 0
fi
exec /etc/init.d/forkop "$@"
EOF
    chmod 700 "$TEST_INIT"
fi
mkdir -p "$ROOT/runtime"
cp -a /usr/lib/forkop/. "$ROOT/runtime/"
cp "$ROOT/forkop/files/usr/lib/components/updater.uc" "$ROOT/runtime/components/updater.uc"
sleep 1
FAIL=0
case "$MODE" in *-failure) FAIL=1 ;; esac
rm -f "$LAB/injected"
{
    manager=apk
    [ "$EXT" != ipk ] || manager=opkg
    rm -f "$LAB/bin/apk" "$LAB/bin/opkg"
    for manager in "$manager"; do
        real=/usr/bin/apk
        [ "$manager" != opkg ] || real=/bin/opkg
        cat > "$LAB/bin/$manager" <<EOF
#!/bin/sh
unset FORKOP_LIB
if [ "\${1:-}" = update ]; then
    echo 'Using previously refreshed VM package indexes'
    exit 0
fi
hit=0
installing=0
for arg in "\$@"; do
    case "\$arg" in add|install) installing=1 ;; esac
    case "\$arg" in */forkop_$TARGET.$EXT) hit=1 ;; esac
done
if [ "$FAIL" = 1 ] && [ "\$installing" = 1 ] && [ "\$hit" = 1 ] && [ ! -f "$LAB/injected" ]; then
    "$real" "\$@" || exit \$?
    uci set forkop.settings.vm_upgrade_probe=fault
    uci commit forkop
    touch "$LAB/injected"
    echo 'VM injected failure AFTER real target package installation' >&2
    exit 42
fi
exec "$real" "\$@"
EOF
        chmod 700 "$LAB/bin/$manager"
    done
    PATH="$LAB/bin:$PATH"
    export PATH
}
case "$MODE" in
    script-*)
        if FORKOP_MIRROR_BASE_URL="$MIRROR" sh "$ROOT/install.sh" --channel canary > "$LAB/$MODE.log" 2>&1; then RC=0; else RC=$?; fi
        ;;
    luci-*)
        if FORKOP_SERVICE_INIT="$TEST_INIT" FORKOP_LIB="$ROOT/runtime" FORKOP_PACKAGE_INIT_ADAPTER="$ROOT/package-init" FORKOP_MIRROR_BASE_URL="$MIRROR" ucode -L /usr/lib/forkop \
            "$ROOT/forkop/files/usr/lib/components/action.uc" component-action forkop install > "$LAB/$MODE.log" 2>&1; then RC=0; else RC=$?; fi
        ;;
    version-*)
        if FORKOP_SERVICE_INIT="$TEST_INIT" FORKOP_LIB="$ROOT/runtime" FORKOP_PACKAGE_INIT_ADAPTER="$ROOT/package-init" FORKOP_MIRROR_BASE_URL="$MIRROR" ucode -L /usr/lib/forkop \
            "$ROOT/forkop/files/usr/lib/components/action.uc" component-action forkop install "$TARGET" > "$LAB/$MODE.log" 2>&1; then RC=0; else RC=$?; fi
        ;;
    *) echo 'unknown mode'; exit 1 ;;
esac
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
echo "workflow exit=$RC"
versions > "$LAB/$MODE.versions"
if [ "$FAIL" = 1 ]; then
    [ "$RC" != 0 ]
    [ -f "$LAB/injected" ]
    case "$MODE" in
        script-*) grep -q 'Previous Forkop configuration, packages and service state restored' "$LAB/$MODE.log" ;;
        *) grep -q 'previous configuration, packages and service restored' "$LAB/$MODE.log" ;;
    esac
    cmp "$LAB/versions.txt" "$LAB/$MODE.versions"
    assert_config "$LAB/current-initial.tar.gz"
    [ "$(uci -q get forkop.settings.vm_upgrade_probe || true)" != fault ]
else
    [ "$RC" = 0 ]
    [ "$(ucode -L /usr/lib/forkop /usr/lib/forkop/core/packages.uc version forkop)" = \
        "$(if [ "$EXT" = apk ]; then echo 1.14.9_rc2; else echo "$TARGET"; fi)" ]
    tar -xOzf /etc/forkop-backups/configuration.tar.gz forkop > "$LAB/$MODE.backup-config"
    tar -xOzf "$LAB/current-initial.tar.gz" etc/config/forkop > "$LAB/original-config"
    tr -d '\r' < "$LAB/original-config" > "$LAB/expected-config"
    tr -d '\r' < "$LAB/$MODE.backup-config" > "$LAB/current-config"
    cmp "$LAB/expected-config" "$LAB/current-config"
fi
if [ "${FORKOP_VM_TEST_STOPPED:-0}" = 1 ]; then
    if /etc/init.d/forkop status >/dev/null; then echo 'unexpected service start'; exit 1; fi
    if /etc/init.d/forkop enabled; then echo 'unexpected service enable'; exit 1; fi
else
    /etc/init.d/forkop status
    [ "$(cat "$LAB/enabled")" != 1 ] || /etc/init.d/forkop enabled
fi
if [ "${FORKOP_VM_DELAY_START:-0}" = 1 ]; then
    [ -f "$LAB/delayed-start-used" ] || { echo 'delayed start was not exercised'; exit 1; }
fi
echo "$MODE PASSED (initial stopped=${FORKOP_VM_TEST_STOPPED:-0}, delayed start=${FORKOP_VM_DELAY_START:-0})"
restore > "$LAB/$MODE.restore.log" 2>&1
echo 'original VM state restored'
