#!/bin/sh
set -eu
lib=/usr/lib/forkop
dir=/root/forkop-managed-verify/extra
mkdir -p "$dir/bin"
/etc/init.d/forkop stop
ucode -L "$lib" "$lib/service/initd.uc" cancel-scheduled-start-retry
cp /etc/sing-box/config.json "$dir/config.original"
trap '/etc/init.d/forkop stop; cp "$dir/config.original" /etc/sing-box/config.json' EXIT
rm /etc/sing-box/config.json
rm -rf /etc/forkop/list-cache /tmp/sing-box/list-generation /tmp/sing-box/rulesets
echo 'CASE: no prior config.json, selected-section bootstrap and full runtime'
ucode -L "$lib" "$lib/service/initd.uc" start-service test "$$"
test -s /var/run/forkop/watchdog.ready
ucode -L "$lib" "$lib/service/state.uc" sing-box-single-owned-service-runtime
/etc/init.d/forkop stop
sing-box check -c /etc/sing-box/config.json
echo 'PASS: clean missing config path supported'
rm -rf /etc/forkop/list-cache /tmp/sing-box/list-generation /tmp/sing-box/rulesets
cp /etc/sing-box/config.json "$dir/before-bootstrap-check"
echo 'CASE: explicit bootstrap configuration check rejection before publication'
if FORKOP_SINGBOX_CONFIG_FAIL_PHASE=check ucode -L "$lib" "$lib/service/initd.uc" start-service test "$$"; then
    echo 'FAIL: bootstrap skipped its configuration check' >&2; exit 1
fi
cmp "$dir/before-bootstrap-check" /etc/sing-box/config.json
test ! -e /var/run/forkop/watchdog.ready
if pidof sing-box; then echo 'FAIL: sing-box survived rejected startup' >&2; exit 1; fi
ucode -L "$lib" "$lib/service/initd.uc" cancel-scheduled-start-retry
echo 'PASS: bootstrap check required, original config and stopped runtime preserved'
cat > "$dir/bin/sing-box" <<'CHECK'
#!/bin/sh
if [ "$1" = -c ] && grep -q 'tproxy' "$2"; then
    echo 'injected final configuration rejection' >&2
    exit 1
fi
exec /usr/bin/sing-box "$@"
CHECK
chmod +x "$dir/bin/sing-box"
rm -rf /etc/forkop/list-cache /tmp/sing-box/list-generation /tmp/sing-box/rulesets
cp /etc/sing-box/config.json "$dir/before-rejected"
echo 'CASE: final config check fails after successful managed download'
if PATH="$dir/bin:$PATH" ucode -L "$lib" "$lib/service/initd.uc" start-service test "$$"; then
    echo 'FAIL: final rejected config was accepted' >&2; exit 1
fi
cmp "$dir/before-rejected" /etc/sing-box/config.json
test -s /etc/forkop/list-cache/manifest.json
test ! -e /var/run/forkop/watchdog.ready
if pidof sing-box; then echo 'FAIL: sing-box survived rejected startup' >&2; exit 1; fi
ucode -L "$lib" "$lib/service/initd.uc" cancel-scheduled-start-retry
echo 'PASS: final rejection fails closed, no process or readiness, validated list cache preserved'