#!/bin/sh
# Portable function tests; full worker lifecycle is covered by support_session_vm.sh.
# Functions are extracted from the production worker below.
# shellcheck disable=SC2034,SC2154
set -eu
root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
awk '/^kill_tree\(\)/ { printing=1 } /^cleanup\(\)/ { printing=0 } printing' "$root/forkop/files/usr/lib/support/worker.sh" > "$test_dir/functions.sh"
dir=$test_dir
uptime_seconds() { cut -d. -f1 /proc/uptime; }
. "$test_dir/functions.sh"
for candidate in '' '100.114.74.44;reboot' '192.168.1.1' '100.63.1.1' '100.128.1.1' '100.114.74.256' '100.114.074.44' '100.114.74.44.' '100..74.44' '100.114.74.44.1'; do
    FORKOP_SUPPORT_OPERATOR_IP=$candidate
    load_peer
    test -z "$peer"
done
for candidate in 100.64.0.0 100.127.255.255 100.114.74.44; do
    FORKOP_SUPPORT_OPERATOR_IP=$candidate
    load_peer
    test "$peer" = "$candidate"
done
cat > "$dir/cli" <<'EOF'
#!/bin/sh
shift
printf '%s\n' "$*" >> "$TEST_CALLS"
case "$1" in
ping)
    case "$TEST_SCENARIO" in
      fail) exit 1;;
      hang) sleep 120 & echo $! > "$TEST_CHILD"; wait;;
    esac;;
esac
EOF
chmod +x "$dir/cli"
cli=$dir/cli
export TEST_CALLS=$dir/calls TEST_CHILD=$dir/child TEST_SCENARIO=ok
deadline=$(( $(uptime_seconds) + 60 ))
phase=connected
attempts=0
next_netcheck=0
probe_peer
test "$(wc -l < "$dir/calls")" = 1
test "$next_peer_check" -ge "$(( $(uptime_seconds) + 59 ))"
export TEST_SCENARIO=fail
before_probe=$(uptime_seconds)
probe_peer
test "$(grep -c '^netcheck$' "$dir/calls")" = 1
test "$next_netcheck" -ge "$(( before_probe + 300 ))"
probe_peer
test "$(grep -c '^netcheck$' "$dir/calls")" = 1
test "$phase" = connected
test "$attempts" = 0
export TEST_SCENARIO=hang
started=$(uptime_seconds)
if run_cli 2 ping --c=1 --timeout=5s "$peer"; then exit 1; fi
test "$(( $(uptime_seconds) - started ))" -le 4
test -z "$auth_pid"
child=$(cat "$dir/child")
if kill -0 "$child" 2>/dev/null; then
    # A reparented killed child may briefly remain as a zombie under PID 1.
    test "$(awk '{print $3}' "/proc/$child/stat")" = Z
fi
for termination in expiry cancel; do
    rm -f "$dir/child"
    (
        auth_pid=
        trap '[ -z "$auth_pid" ] || kill_tree "$auth_pid"; [ -z "$auth_pid" ] || wait "$auth_pid" 2>/dev/null || true' EXIT
        trap 'exit 0' TERM
        deadline=$(( $(uptime_seconds) + 2 ))
        [ "$termination" != cancel ] || deadline=$(( $(uptime_seconds) + 30 ))
        run_cli 20 ping --c=1 --timeout=5s "$peer"
    ) & runner=$!
    count=0
    while [ ! -s "$dir/child" ]; do
        sleep 1; count=$((count + 1)); test "$count" -lt 5
    done
    [ "$termination" != cancel ] || kill "$runner"
    wait "$runner"
    child=$(cat "$dir/child")
    if kill -0 "$child" 2>/dev/null; then
        test "$(awk '{print $3}' "/proc/$child/stat")" = Z
    fi
done
echo 'peer validation, ping, netcheck backoff and hung-command timeout passed'
