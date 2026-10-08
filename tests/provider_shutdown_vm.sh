#!/bin/sh
set -eu
lib="${FORKOP_TEST_LIB:-/usr/lib/forkop}"
work=$(mktemp -d /tmp/forkop-provider-stop.XXXXXX)
supervisor=; child=; external=
cleanup() {
    for pid in "$supervisor" "$child" "$external"; do
        [ -z "$pid" ] || kill -9 "$pid" 2>/dev/null || true
    done
    rm -rf "$work"
}
trap cleanup EXIT
sleep 60 & external=$!
for provider in zapret zapret2 byedpi; do
    state="$work/$provider"
    mkdir -p "$state/pid" "$state/child-pid" "$state/log"
    sleep 60 & supervisor=$!
    sh -c 'trap "" TERM; while :; do sleep 1; done' & child=$!
    # Allow the child to install its TERM handler before shutdown.
    sleep 1
    echo "$supervisor" > "$state/pid/rule.pid"
    echo "$child" > "$state/child-pid/rule.pid"
    export ZAPRET_STATE_DIR="$state" ZAPRET2_STATE_DIR="$state" BYEDPI_STATE_DIR="$state"
    export ZAPRET_LEGACY_RUNTIME_BASE_DIR="$work/legacy" ZAPRET_HOSTLIST_DIR="$work/hostlist"
    a=$(cut -d' ' -f1 /proc/uptime)
    ucode -L "$lib" "$lib/providers/$provider/runtime.uc" stop-runtime
    b=$(cut -d' ' -f1 /proc/uptime)
    wait "$supervisor" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    if kill -0 "$supervisor" 2>/dev/null || kill -0 "$child" 2>/dev/null; then
        echo "FAIL: owned processes survived $provider"; exit 1
    fi
    supervisor=; child=
    kill -0 "$external" || { echo 'FAIL: external process stopped'; exit 1; }
    [ ! -e "$state/pid" ] && [ ! -e "$state/child-pid" ] || exit 1
    awk -v a="$a" -v b="$b" 'BEGIN { if (b-a < 1) exit 1 }'
    echo "PASS $provider real TERM/KILL, external process preserved, grace=$(awk -v a="$a" -v b="$b" 'BEGIN {print b-a}')"
done