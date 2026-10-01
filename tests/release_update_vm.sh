#!/bin/sh
set -eu
[ "${FORKOP_TEST_VM:-}" = 1 ] || { echo 'Set FORKOP_TEST_VM=1 on a test VM' >&2; exit 1; }
ubus call system board | grep -qi VMware || { echo 'VMware VM required' >&2; exit 1; }
W=/tmp/forkop-release-check
L=/usr/lib/forkop
phase=${1:-failure}
mkdir -p "$W/www" "$W/bin"
tar -xzf "$W/release-check-www.tgz" -C "$W/www"
command -v apk >/dev/null 2>&1 && manager=apk || manager=opkg
cat > "$W/bin/$manager" <<'WRAP'
#!/bin/sh
W=/tmp/forkop-release-check
case "$0" in */apk) real=/usr/bin/apk ;; *) real=/bin/opkg ;; esac
[ "${1:-}" != update ] || exit 0
hit=0
installing=0
for arg in "$@"; do case "$arg" in add|install) installing=1;; esac; case "$arg" in */forkop_1.14.9-canary.7.apk|*/forkop_1.14.9-canary.7.ipk) hit=1;; esac; done
if [ "$real" = /usr/bin/apk ]; then "$real" --no-network "$@"; else "$real" "$@"; fi
rc=$?
[ "$rc" = 0 ] || exit "$rc"
if [ "$TEST_PHASE" = failure ] && [ "$installing" = 1 ] && [ "$hit" = 1 ] && [ ! -e "$W/injected" ]; then
 uci set forkop.settings.vm_upgrade_probe=fault
 uci commit forkop
 touch "$W/injected"
 echo 'Injected error AFTER real target package install' >&2
 exit 42
fi
exit 0
WRAP
chmod +x "$W/bin/$manager"
for i in $(seq 1 120); do ucode -L "$L" "$L/service/ui.uc" service-action-idle && break; sleep 1; done
ucode -L "$L" "$L/service/ui.uc" service-action-idle
sha256sum /etc/config/forkop > "$W/$phase.config.sha"
ubus call service list > "$W/$phase.services.before"
ucode -L "$L" "$L/core/packages.uc" version forkop > "$W/$phase.version.before"
ucode -L "$L" "$L/service/state.uc" mark-pending-reload /var/run/forkop/reload.pending upgrade-test
uhttpd -f -p 127.0.0.1:18196 -h "$W/www" > "$W/http-$phase.log" 2>&1 & http=$!
trap 'kill "$http" 2>/dev/null || true' EXIT
export TEST_PHASE="$phase" PATH="$W/bin:$PATH"
if FORKOP_MIRROR_BASE_URL=http://127.0.0.1:18196 ucode -L "$L" "$L/components/action.uc" component-action forkop install 1.14.9-canary.7 > "$W/update-$phase.log" 2>&1; then rc=0; else rc=$?; fi
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
if [ "$phase" = failure ]; then
 [ "$rc" != 0 ]
 [ -f "$W/injected" ]
 grep -q 'previous configuration, packages and service restored' "$W/update-$phase.log"
 sha256sum -c "$W/$phase.config.sha"
 ucode -L "$L" "$L/core/packages.uc" version forkop > "$W/$phase.version.after"
 cmp "$W/$phase.version.before" "$W/$phase.version.after"
else
 [ "$rc" = 0 ]
 version=$(ucode -L "$L" "$L/core/packages.uc" version forkop)
 case "$version" in 1.14.9_rc7|1.14.9-canary.7) ;; *) exit 1;; esac
fi
for i in $(seq 1 90); do
 /usr/bin/forkop get_ui_state > "$W/$phase.ui.after.json"
 if [ ! -e /var/run/forkop/reload.pending ] && [ ! -d /var/run/forkop.reload.lock ] && [ "$(jsonfilter -i "$W/$phase.ui.after.json" -e '@.service.forkop.running')" = 1 ]; then break; fi
 sleep 1
done
[ ! -e /var/run/forkop/reload.pending ]
[ ! -d /var/run/forkop.reload.lock ]
[ "$(jsonfilter -i "$W/$phase.ui.after.json" -e '@.service.forkop.running')" = 1 ]
[ "$(ucode -L "$L" "$L/service/state.uc" sing-box-process-count)" = 1 ]
echo "PASS: Forkop update $phase with pending reload, actual package transaction, healthy final service"
