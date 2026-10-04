#!/bin/sh
set -eu
lib=/usr/lib/forkop
dir=/root/forkop-managed-verify/actions
mkdir -p "$dir/bin" "$dir/www"
fail() { echo "FAIL:$*" >> /root/forkop-managed-verify/additional-result.log; exit 1; }
state() { ucode -L "$lib" "$lib/service/state.uc" "$@"; }
stable() {
    for i in $(seq 1 120); do
        if test -s /var/run/forkop/watchdog.ready && state forkop-stably-running forkop ForkopTable 0x04000000 2; then return 0; fi
        sleep 1
    done
    return 1
}
waitjob() {
    job=$1
    for i in $(seq 1 180); do
        forkop service_action_status "$job" > "$dir/job.json"
        running=$(jsonfilter -i "$dir/job.json" -e '@.running')
        [ "$running" = true ] || {
            test "$(jsonfilter -i "$dir/job.json" -e '@.success')" = true || fail "UI restart failed"
            return
        }
        sleep 1
    done
    fail "UI restart timed out"
}
# Controlled content changes keep the real external Reality transport. Only the
# fixture subscription URL is mapped to local HTTP; production HTTPS is intact.
cat > "$dir/bin/curl" <<'CURL'
#!/bin/sh
dir=/root/forkop-managed-verify/actions
for arg do
    shift
    case "$arg" in
        https://sub.hat.onl/forkop-actions-test/subscription.txt*)
            if [ -f "$dir/hold" ]; then
                echo reached > "$dir/reached"
                while [ -f "$dir/hold" ]; do sleep 1; done
            fi
            arg=http://127.0.0.1:19091/subscription.txt;;
    esac
    set -- "$@" "$arg"
done
exec /usr/bin/curl "$@"
CURL
chmod +x "$dir/bin/curl"
uhttpd -f -p 127.0.0.1:19091 -h "$dir/www" > "$dir/http.log" 2>&1 &
http_pid=$!
trap 'kill "$http_pid" 2>/dev/null || true' EXIT
uci -q delete forkop.realtest.subscription_urls
uci add_list forkop.realtest.subscription_urls=https://sub.hat.onl/forkop-actions-test/subscription.txt
uci commit forkop
export PATH="$dir/bin:$PATH"
echo 'CASE: LuCI async restart using the exact backend invoked by the button' > "$dir/runner.log"
forkop service_action_async restart > "$dir/start.json"
job=$(jsonfilter -i "$dir/start.json" -e '@.job_id')
test -n "$job" || fail "no UI job"
waitjob "$job"
stable || fail "UI restart not stable"
echo 'PASS:LuCI restart backend, tracked async completion, full runtime and DNS' >> /root/forkop-managed-verify/additional-result.log

cp "$dir/initial.txt" "$dir/www/subscription.txt"
chmod 644 "$dir/www/subscription.txt"
ucode -L "$lib" "$lib/components/updates.uc" subscription-update realtest > "$dir/update-a.private.log" 2>&1 || fail "initial controlled update"
stable || fail "initial update not stable"
grep -q Fixture-A /etc/sing-box/config.json || fail "Fixture-A absent"
old_pid=$(state sing-box-service-runtime-pid)
cp "$dir/changed.txt" "$dir/www/subscription.txt"
chmod 644 "$dir/www/subscription.txt"
ucode -L "$lib" "$lib/components/updates.uc" subscription-update realtest > "$dir/update-b.private.log" 2>&1 || fail "changed controlled update"
stable || fail "changed update not stable"
grep -q Fixture-B /etc/sing-box/config.json || fail "added node absent"
test "$old_pid" != "$(state sing-box-service-runtime-pid)" || fail "changed nodes did not replace PID"
echo 'PASS:subscription node additions update config via controlled sole-PID transition' >> /root/forkop-managed-verify/additional-result.log
# Remove B again while deliberately holding subscription I/O. Reload must
# queue; a manual restart must decline without tearing down the working policy.
cp "$dir/initial.txt" "$dir/www/subscription.txt"
chmod 644 "$dir/www/subscription.txt"
marker="ACTIONS_CONCURRENCY_BEGIN_$$"
logger -t forkop "$marker"
touch "$dir/hold"
rm -f "$dir/reached"
ucode -L "$lib" "$lib/components/updates.uc" subscription-update realtest > "$dir/concurrent-update.private.log" 2>&1 &
updater=$!
for i in $(seq 1 30); do [ -f "$dir/reached" ] && break; sleep 1; done
test -f "$dir/reached" || fail "updater did not enter hold"
old_pid=$(state sing-box-service-runtime-pid)
forkop reload on_config_change > "$dir/queued.log" 2>&1 &
reload=$!
forkop service_action_async restart > "$dir/concurrent-ui.json"
job=$(jsonfilter -i "$dir/concurrent-ui.json" -e '@.job_id')
test -n "$job" || fail "concurrent UI request missing job"
sleep 3
state sing-box-single-owned-service-runtime || fail "concurrency lost owned runtime"
test "$old_pid" = "$(state sing-box-service-runtime-pid)" || fail "concurrency stopped existing PID during I/O"
rm "$dir/hold"
wait "$updater" || fail "concurrent update failed"
wait "$reload" || true
# shellcheck disable=SC2034
for i in $(seq 1 90); do
    forkop service_action_status "$job" > "$dir/concurrent-job.json"
    test "$(jsonfilter -i "$dir/concurrent-job.json" -e '@.running')" != true && break
    sleep 1
done
test "$(jsonfilter -i "$dir/concurrent-job.json" -e '@.success')" = false || fail "busy manual restart unexpectedly succeeded"
stable || fail "concurrency did not settle to full runtime"
if grep -q Fixture-B /etc/sing-box/config.json; then fail "removed node survived final config"; fi
logread -e forkop | sed -n "/$marker/,$ p" > "$dir/concurrency-runtime.log"
if grep -Eq "unexpected sing-box exists before start|Restart verification failed|did not reach a running procd state" "$dir/concurrency-runtime.log"; then fail "concurrent transition reported fatal runtime failure"; fi
dig +short example.com @127.0.0.42 > "$dir/dns.log"
test -s "$dir/dns.log" || fail "DNS returned no answer"
echo 'PASS:subscription update plus reload plus LuCI restart preserves I/O runtime and settles safely' >> /root/forkop-managed-verify/additional-result.log
