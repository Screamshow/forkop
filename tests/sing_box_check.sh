#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
export TEST_WORK="$work"
export FORKOP_LIB="$ROOT/forkop/files/usr/lib"
export FORKOP_STATE_UC=state FORKOP_DNS_APPLY_UC=dns
export FORKOP_RELOAD_LOCK_DIR="$work/reload" FORKOP_SING_BOX_CHECK_LOCK_DIR="$work/check"
export PATH="$work/bin:$PATH"
cat > "$work/bin/ucode" <<'SH'
#!/bin/sh
shift 2
module=$1; shift
printf '%s %s\n' "$module" "$*" >> "$TEST_WORK/log"
if [ "$module" = dns ]; then
    echo dns-init-noise
    case "$1" in
        has-managed-state) [ "$TEST_DNS" = managed ] ;;
        default-config-complete) exit 0 ;;
        restore) echo native > "$TEST_WORK/dns" ;;
        independent-of-sing-box) [ "$TEST_DNS" != unsafe ] ;;
        configure) echo managed > "$TEST_WORK/dns" ;;
        wait-listener) exit 0 ;;
    esac
    exit $?
fi
case "$1" in
    runtime-dir-lock-owned-by-ancestor) [ "$TEST_INHERITED" = 1 ] ;;
    acquire-runtime-dir-lock*) mkdir "$2" ;;
    release-runtime-dir-lock) rmdir "$2" ;;
    sing-box-process-count) cat "$TEST_WORK/count" ;;
    sing-box-current-owned-service-runtime|single-ready-sing-box-runtime) [ "$(cat "$TEST_WORK/count")" = 1 ] && [ "$TEST_FOREIGN" = 0 ] ;;
    stop-managed-sing-box-runtime) echo 0 > "$TEST_WORK/count"; [ "$TEST_STOP_FAIL" = 0 ] ;;
    start-managed-sing-box-runtime) [ "$TEST_START_FAIL" = 0 ] || exit 1; echo 1 > "$TEST_WORK/count" ;;
    *) exit 1 ;;
esac
SH
cat > "$work/bin/sing-box" <<'SH'
#!/bin/sh
[ "$(cat "$TEST_WORK/count")" = 0 ] || exit 90
[ -d "$FORKOP_SING_BOX_CHECK_LOCK_DIR" ] || exit 91
echo checker >> "$TEST_WORK/log"
[ -z "${TEST_CHECK_OUTPUT:-}" ] || printf '%s\n' "$TEST_CHECK_OUTPUT"
if [ "${TEST_SLEEP:-0}" = 1 ]; then
    echo $$ > "$TEST_WORK/child"
    exec sleep 60
fi
exit "$TEST_CHECK_STATUS"
SH
cat > "$work/bin/uci" <<'SH'
#!/bin/sh
echo 0
SH
cat > "$work/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_WORK/log"
SH
chmod +x "$work/bin/"*
export TEST_INHERITED=0 TEST_FOREIGN=0 TEST_DNS=managed
export TEST_STOP_FAIL=0 TEST_START_FAIL=0 TEST_CHECK_STATUS=0
reset() { : > "$work/log"; echo 1 > "$work/count"; echo managed > "$work/dns"; }
run() { sh "$FORKOP_LIB/service/sing-box-check.sh" rule-set match fixture; }
restored() {
    [ "$(cat "$work/count")" = 1 ]
    [ "$(cat "$work/dns")" = managed ]
    [ ! -d "$work/check" ] && [ ! -d "$work/reload" ]
}
reset; export TEST_CHECK_OUTPUT=checked
output=$(run); [ "$output" = checked ]; restored
unset TEST_CHECK_OUTPUT
# Assert the order, including DNS before stop and restart before DNS forwarding.
sed -n '/^dns restore /p; /^state stop-managed/p; /^checker$/p; /^state start-managed/p; /^dns configure /p' "$work/log" > "$work/order"
printf '%s\n' 'dns restore force' 'state stop-managed-sing-box-runtime 15' checker 'state start-managed-sing-box-runtime 15' 'dns configure force' > "$work/expected"
cmp "$work/order" "$work/expected"
reset; TEST_CHECK_STATUS=7; export TEST_CHECK_STATUS
if run; then exit 1; fi
restored
TEST_CHECK_STATUS=0; TEST_STOP_FAIL=1; export TEST_CHECK_STATUS TEST_STOP_FAIL
reset; if run; then exit 1; fi
restored; ! grep -q '^checker$' "$work/log"
TEST_STOP_FAIL=0; TEST_START_FAIL=1; export TEST_STOP_FAIL TEST_START_FAIL
reset; if run; then exit 1; fi
[ "$(cat "$work/dns")" = native ]
TEST_START_FAIL=0; TEST_FOREIGN=1; export TEST_START_FAIL TEST_FOREIGN
reset; if run; then exit 1; fi
! grep -q '^checker$\|^state stop-managed' "$work/log"
TEST_FOREIGN=0; TEST_DNS=unsafe; export TEST_FOREIGN TEST_DNS
reset; if run; then exit 1; fi
! grep -q '^checker$\|^state stop-managed' "$work/log"
TEST_DNS=managed; TEST_INHERITED=1; export TEST_DNS TEST_INHERITED
reset; mkdir "$work/reload"; run
[ -d "$work/reload" ]; rmdir "$work/reload"
# A stopped service must remain stopped, without changing DNS.
TEST_INHERITED=0; export TEST_INHERITED
reset; echo 0 > "$work/count"; run
[ "$(cat "$work/count")" = 0 ]
! grep -q '^dns restore\|^state start-managed' "$work/log"
reset; export TEST_SLEEP=1
sh "$FORKOP_LIB/service/sing-box-check.sh" rule-set match fixture & helper=$!
while [ ! -f "$work/child" ]; do sleep 1; done
kill -TERM "$helper"
if wait "$helper"; then exit 1; fi
restored
! kill -0 "$(cat "$work/child")" 2>/dev/null
echo 'Sequential checker: ordering, invalid candidate, stop/start failures, foreign runtime, unsafe DNS and inherited lock passed'
