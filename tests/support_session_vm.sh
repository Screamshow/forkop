#!/bin/sh
# Existing OpenWrt VM only. Isolated real daemon + synthetic CLI; no auth key.
# WORKER/LIB/DAEMON may point at a candidate staged entirely under /tmp.
set -eu
worker_path=${WORKER:-/usr/lib/forkop/support/worker.sh}
lib_path=${LIB:-/usr/lib/forkop/support}
daemon_path=${DAEMON:-$(command -v tailscaled)}
test_dir=$(mktemp -d /tmp/forkop-support-test.XXXXXX)
worker=
primary=
trap '[ -z "$worker" ] || kill "$worker" 2>/dev/null || true; [ -z "$worker" ] || wait "$worker" 2>/dev/null || true; [ -z "$primary" ] || kill "$primary" 2>/dev/null || true; [ -z "$primary" ] || wait "$primary" 2>/dev/null || true; rm -rf "$test_dir"' EXIT
mkdir "$test_dir/lite" "$test_dir/session"
chmod 700 "$test_dir/session"
printf '#!/bin/sh\necho $$ >> "$FORKOP_SUPPORT_DIR/daemon-pids"\nexec "%s" "$@"\n' "$daemon_path" > "$test_dir/lite/tailscaled"
chmod 755 "$test_dir/lite/tailscaled"
# An independent instance must stay alive throughout all support tests.
"$daemon_path" --tun=userspace-networking --state=mem: --statedir="$test_dir/primary" --socket="$test_dir/primary.socket" --port=0 --no-logs-no-support >/dev/null 2>&1 &
primary=$!
# Deliberately omit any system tailscale/tailscaled from the worker's PATH.
mkdir "$test_dir/tools"
for tool in sh cat cut rm mv jsonfilter ucode wc sleep rmdir ls touch; do
    ln -s "$(command -v "$tool")" "$test_dir/tools/$tool"
done
touch "$test_dir/lite/.forkop-lite"
cat > "$test_dir/lite/tailscale" <<'EOF'
#!/bin/sh
set -eu
case "$1" in --socket=*) ;; *) exit 1;; esac
shift
printf '%s\n' "$*" >> "$FORKOP_SUPPORT_DIR/commands"
case "$1" in
up)
    case "$*" in
    *--auth-key=*)
        test -f "$FORKOP_SUPPORT_DIR/auth.key"
        test "$(ls -ld "$FORKOP_SUPPORT_DIR/auth.key" | cut -d' ' -f1)" = '-rw-------'
        test "$(ls -ld "$FORKOP_SUPPORT_DIR" | cut -d' ' -f1)" = 'drwx------'
        test ! -e "$FORKOP_SUPPORT_DIR/initial-up"
        touch "$FORKOP_SUPPORT_DIR/initial-up"
        if [ "$SCENARIO" = auth-hang ]; then
            sleep 120 & echo $! > "$FORKOP_SUPPORT_DIR/child"; wait
        fi
        ;;
    *)
        test ! -e "$FORKOP_SUPPORT_DIR/auth.key"
        for flag in --timeout=20s --accept-dns=false --accept-routes=false --netfilter-mode=off "--hostname=forkop-support-$(cat /proc/sys/kernel/hostname)"; do
            case " $* " in *" $flag "*) ;; *) exit 1;; esac
        done
        if [ "$SCENARIO" = up-hang ]; then
            sleep 120 & echo $! > "$FORKOP_SUPPORT_DIR/child"; wait
        fi
        touch "$FORKOP_SUPPORT_DIR/recovered"
        ;;
    esac
    ;;
down)
    if [ "$SCENARIO" = down-hang ]; then
        sleep 120 & echo $! > "$FORKOP_SUPPORT_DIR/child"; wait
    fi
    ;;
status)
    count=$(cat "$FORKOP_SUPPORT_DIR/count" 2>/dev/null || echo 0)
    count=$((count + 1)); echo "$count" > "$FORKOP_SUPPORT_DIR/count"
    if [ "$SCENARIO" = status-hang ]; then
        sleep 120 & echo $! > "$FORKOP_SUPPORT_DIR/child"; wait
    fi
    bad=0
    case "$SCENARIO" in
      persistent|down-hang|up-hang|peer-degraded|peer-degraded-fail) bad=1;;
      recover) [ -f "$FORKOP_SUPPORT_DIR/recovered" ] || bad=1;;
      transient) [ "$count" -ne 2 ] || bad=1;;
    esac
    if [ "$bad" = 1 ]; then
        printf '{"BackendState":"Running","Self":{"Online":true},"Health":["Unable to connect to the Tailscale coordination server to synchronize the state of your tailnet."]}\n'
    else
        # Offline self and unrelated DNS warnings must not trigger recovery.
        printf '{"BackendState":"Running","Self":{"Online":false},"Health":["DNS configuration warning"]}\n'
    fi
    ;;
ping)
    test "$*" = 'ping --c=1 --timeout=5s --until-direct=false 100.114.74.44'
    case "$SCENARIO" in
      peer-fail|peer-degraded-fail|netcheck-hang) exit 1;;
      peer-hang) sleep 120 & echo $! > "$FORKOP_SUPPORT_DIR/child"; wait;;
    esac
    ;;
netcheck)
    if [ "$SCENARIO" = netcheck-hang ]; then
        sleep 120 & echo $! > "$FORKOP_SUPPORT_DIR/child"; wait
    fi
    ;;
*) exit 1;;
esac
EOF
chmod 755 "$test_dir/lite/tailscale"
export FORKOP_SUPPORT_DIR="$test_dir/session" FORKOP_SUPPORT_LITE_DIR="$test_dir/lite"
export FORKOP_SUPPORT_LIB_DIR="$lib_path" FORKOP_SUPPORT_PUBLIC_KEY="$lib_path/operator.pub"
export FORKOP_SUPPORT_AUTHORIZED_KEYS="$test_dir/authorized_keys"
export FORKOP_SUPPORT_HEALTH_INTERVAL=1 FORKOP_SUPPORT_HEALTH_GRACE=2 FORKOP_SUPPORT_RECOVERY_INTERVAL=3
export FORKOP_SUPPORT_OPERATOR_IP=
prepare() {
    rm -f "$FORKOP_SUPPORT_DIR/"*
    printf 'existing-customer-key\n' > "$test_dir/authorized_keys"
    cp "$test_dir/authorized_keys" "$test_dir/original-keys"
    printf start > "$FORKOP_SUPPORT_DIR/operation"
    printf synthetic-test-credential > "$FORKOP_SUPPORT_DIR/auth.key"
    chmod 600 "$FORKOP_SUPPORT_DIR/auth.key"
    mkdir "$FORKOP_SUPPORT_DIR/lock"
}
clean_assert() {
    kill -0 "$primary"
    test "$(wc -l < "$FORKOP_SUPPORT_DIR/daemon-pids")" = 1
    test "$(jsonfilter -i "$FORKOP_SUPPORT_DIR/status.json" -e '@.phase')" = stopped
    test ! -e "$FORKOP_SUPPORT_DIR/socket"
    test ! -e "$FORKOP_SUPPORT_DIR/auth.key"
    test ! -d "$FORKOP_SUPPORT_DIR/lock"
    cmp "$test_dir/authorized_keys" "$test_dir/original-keys"
    if [ -f "$FORKOP_SUPPORT_DIR/child" ]; then
        ! kill -0 "$(cat "$FORKOP_SUPPORT_DIR/child")" 2>/dev/null
    fi
    # The real daemon and mock CLI command lines contain the private test path.
    for p in /proc/[0-9]*/cmdline; do
        args=$(tr '\000' ' ' 2>/dev/null < "$p") || continue
        case "$args" in *"$test_dir/lite/"*) echo "leftover test process"; exit 1;; esac
    done
}
for SCENARIO in healthy transient recover persistent; do
    export SCENARIO
    prepare
    case "$SCENARIO" in healthy) export FORKOP_SUPPORT_TTL=4;; transient) export FORKOP_SUPPORT_TTL=8;; *) export FORKOP_SUPPORT_TTL=16;; esac
    expected_id=$(cat /proc/sys/kernel/random/uuid)
    expected_deadline=$(( $(cut -d. -f1 /proc/uptime) + FORKOP_SUPPORT_TTL ))
    printf '{"schema":2,"session_id":"%s","deadline":%s}' "$expected_id" "$expected_deadline" > "$FORKOP_SUPPORT_DIR/status.json"
    PATH="$test_dir/tools" sh "$worker_path" & worker=$!
    sleep 2
    initial_deadline=$(jsonfilter -i "$FORKOP_SUPPORT_DIR/status.json" -e '@.deadline')
    initial_id=$(jsonfilter -i "$FORKOP_SUPPORT_DIR/status.json" -e '@.session_id')
    test "$initial_id" = "$expected_id"
    test "$initial_deadline" = "$expected_deadline"
    wait "$worker"; worker=
    clean_assert
    test "$initial_deadline" = "$(jsonfilter -i "$FORKOP_SUPPORT_DIR/status.json" -e '@.deadline')"
    test "$initial_id" = "$(jsonfilter -i "$FORKOP_SUPPORT_DIR/status.json" -e '@.session_id')"
    attempts=$(jsonfilter -i "$FORKOP_SUPPORT_DIR/status.json" -e '@.recovery_attempts')
    downs=$(grep -c '^down$' "$FORKOP_SUPPORT_DIR/commands" || true)
    test "$downs" = "$attempts"
    awk '$2 == "recovery-started" { if (last && $1 - last < 3) exit 1; last=$1 }' "$FORKOP_SUPPORT_DIR/recovery.log"
    case "$SCENARIO" in healthy|transient) test "$attempts" = 0;; recover) test "$attempts" = 1; grep -q control-healthy "$FORKOP_SUPPORT_DIR/recovery.log";; persistent) test "$attempts" = 3;; esac
    echo "$SCENARIO: deadline, identity, retry count, SSH preservation and process cleanup passed"
done
for SCENARIO in peer-ok peer-fail peer-invalid peer-degraded peer-degraded-fail; do
    export SCENARIO FORKOP_SUPPORT_TTL=9 FORKOP_SUPPORT_OPERATOR_IP=100.114.74.44
    export FORKOP_SUPPORT_HEALTH_GRACE=30
    [ "$SCENARIO" != peer-invalid ] || export FORKOP_SUPPORT_OPERATOR_IP='100.114.74.44;reboot'
    prepare
    PATH="$test_dir/tools" sh "$worker_path" & worker=$!
    case "$SCENARIO" in peer-degraded|peer-degraded-fail)
        sleep 4
        test "$(jsonfilter -i "$FORKOP_SUPPORT_DIR/status.json" -e '@.phase')" = degraded
        test "$(jsonfilter -i "$FORKOP_SUPPORT_DIR/status.json" -e '@.recovery_attempts')" = 0
        test -S "$FORKOP_SUPPORT_DIR/socket"
        ;;
    esac
    wait "$worker"; worker=
    clean_assert
    test "$(jsonfilter -i "$FORKOP_SUPPORT_DIR/status.json" -e '@.recovery_attempts')" = 0
    pings=$(grep -c '^ping ' "$FORKOP_SUPPORT_DIR/commands" || true)
    checks=$(grep -c '^netcheck$' "$FORKOP_SUPPORT_DIR/commands" || true)
    case "$SCENARIO" in
      peer-ok|peer-degraded) test "$pings" = 1; test "$checks" = 0;;
      peer-fail|peer-degraded-fail) test "$pings" = 2; test "$checks" = 1;;
      peer-invalid) test "$pings" = 0; test "$checks" = 0;;
    esac
    echo "$SCENARIO: bounded peer probes without control recovery passed"
done
export FORKOP_SUPPORT_HEALTH_GRACE=2
for SCENARIO in down-hang up-hang status-hang auth-hang peer-hang netcheck-hang; do
    export SCENARIO
    export FORKOP_SUPPORT_OPERATOR_IP=
    case "$SCENARIO" in peer-hang|netcheck-hang) export FORKOP_SUPPORT_OPERATOR_IP=100.114.74.44;; esac
    for termination in cancel expiry; do
        prepare
        if [ "$termination" = cancel ]; then export FORKOP_SUPPORT_TTL=60; else export FORKOP_SUPPORT_TTL=7; fi
        PATH="$test_dir/tools" sh "$worker_path" & worker=$!
        count=0
        while [ ! -s "$FORKOP_SUPPORT_DIR/child" ]; do
            sleep 1; count=$((count + 1)); test "$count" -lt 15
        done
        if [ "$termination" = cancel ]; then kill "$worker"; fi
        wait "$worker"; worker=
        clean_assert
        echo "$SCENARIO/$termination: child cleanup and SSH revocation passed"
    done
done
# Parser regression cases: backend, invalid JSON, control warning, unrelated warning.
for fixture in '{"BackendState":"Stopped"}' '{}' 'bad-json' '{"BackendState":"Running","Health":["Tailscale has not received a network map from the coordination server"]}'; do
    printf '%s' "$fixture" > "$test_dir/health.json"
    if ucode "$lib_path/health.uc" "$test_dir/health.json"; then echo 'bad status accepted'; exit 1; fi
done
printf '%s' '{"BackendState":"Running","Self":{"Online":false},"Health":null}' > "$test_dir/health.json"
ucode "$lib_path/health.uc" "$test_dir/health.json"
echo 'health parser fixtures passed'
