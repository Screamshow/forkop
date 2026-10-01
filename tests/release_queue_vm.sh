#!/bin/sh
set -eu
[ "${FORKOP_TEST_VM:-}" = 1 ] || { echo 'Set FORKOP_TEST_VM=1 on a test VM' >&2; exit 1; }
ubus call system board | grep -qi VMware || { echo 'VMware VM required' >&2; exit 1; }
W=/tmp/forkop-release-check
L=/usr/lib/forkop
apk list --installed --manifest > "$W/queue-packages.before" 2>/dev/null || opkg list-installed > "$W/queue-packages.before"
ubus call service list > "$W/queue-services.before"
ucode -L "$L" "$L/service/ui.uc" service-action-async restart > "$W/restart-job.json"
job=$(jsonfilter -i "$W/restart-job.json" -e '@.job_id')
[ -n "$job" ]
sleep 1
ucode -L "$L" "$L/service/state.uc" mark-pending-reload /var/run/forkop/reload.pending vm-release-check
/etc/init.d/forkop reload on_config_change > "$W/queued-config-reload.log" 2>&1 & config_pid=$!
/etc/init.d/forkop reload list-content > "$W/queued-list-reload.log" 2>&1 & list_pid=$!
for i in $(seq 1 120); do
 ucode -L "$L" "$L/service/ui.uc" service-action-status "$job" > "$W/restart-status.json"
 [ "$(jsonfilter -i "$W/restart-status.json" -e '@.running')" = true ] || break
 sleep 1
done
[ "$(jsonfilter -i "$W/restart-status.json" -e '@.running')" = false ]
[ "$(jsonfilter -i "$W/restart-status.json" -e '@.success')" = true ]
wait "$config_pid"
wait "$list_pid"
for i in $(seq 1 60); do
 /usr/bin/forkop get_ui_state > "$W/queue-ui.json"
 if [ ! -e /var/run/forkop/reload.pending ] && [ ! -d /var/run/forkop.reload.lock ] &&
  [ "$(jsonfilter -i "$W/queue-ui.json" -e '@.service.forkop.running')" = 1 ] &&
  [ "$(jsonfilter -i "$W/queue-ui.json" -e '@.service.forkop.restart_blocked')" = 0 ]; then break; fi
 sleep 1
done
[ ! -e /var/run/forkop/reload.pending ]
[ ! -d /var/run/forkop.reload.lock ]
[ "$(jsonfilter -i "$W/queue-ui.json" -e '@.service.forkop.running')" = 1 ]
[ "$(ucode -L "$L" "$L/service/state.uc" sing-box-process-count)" = 1 ]
nslookup example.com 127.0.0.1 > "$W/queue-dns.txt"
echo 'PASS: restart plus queued reloads, pending consumed, locks released, sole owned process, DNS'
sh /tmp/singbox_single_process.sh > "$W/single-process.log" 2>&1
cat "$W/single-process.log"
FORKOP_LIB="$L" sh /tmp/sing_box_manual_version.sh
