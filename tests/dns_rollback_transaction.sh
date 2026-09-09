#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="$ROOT_DIR/forkop/files/usr/lib/dns/apply.uc"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
STATE="$WORK_DIR/uci.state"
DNSMASQ_LOG="$WORK_DIR/dnsmasq.log"
LOGGER_LOG="$WORK_DIR/logger.log"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
value() { awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$STATE"; }
absent() { ! grep -Fq "$1=" "$STATE" || fail "$1 must be absent"; }

cat >"$WORK_DIR/dnsmasq-init" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${DNSMASQ_LOG:?}"
SH
chmod 0755 "$WORK_DIR/dnsmasq-init"
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LOGGER_LOG:?}"
SH
chmod 0755 "$WORK_DIR/bin/logger"

export FORKOP_UCI_STATE_FILE="$STATE"
export DNSMASQ_INIT="$WORK_DIR/dnsmasq-init"
export DNSMASQ_LOG
export LOGGER_LOG
export PATH="$WORK_DIR/bin:$PATH"

# A foreign resolver, including port/resolvfile, has no Forkop transaction and
# must survive failed-start/package failsafe cleanup byte-for-byte.
cat >"$STATE" <<'EOF_STATE'
dhcp.@dnsmasq[0].port=5353
dhcp.@dnsmasq[0].server=127.0.0.1#5053
dhcp.@dnsmasq[0].noresolv=1
dhcp.@dnsmasq[0].resolvfile=/tmp/external-resolv.conf
EOF_STATE
cp "$STATE" "$WORK_DIR/foreign.before"
: >"$DNSMASQ_LOG"
ucode -L "$FORKOP_LIB" "$APPLY" failsafe-restore
cmp -s "$WORK_DIR/foreign.before" "$STATE" || fail 'foreign dnsmasq was changed'
[ ! -s "$DNSMASQ_LOG" ] || fail 'foreign dnsmasq was restarted'

# A Forkop transaction restores exactly the original values, including absence.
cat >"$STATE" <<'EOF_STATE'
dhcp.@dnsmasq[0].server=1.1.1.1
dhcp.@dnsmasq[0].noresolv=0
EOF_STATE
ucode -L "$FORKOP_LIB" "$APPLY" configure force
[ "$(value 'dhcp.@dnsmasq[0].forkop_dns_version')" = 1 ] || fail 'transaction marker missing'
ucode -L "$FORKOP_LIB" "$APPLY" failsafe-restore
[ "$(value 'dhcp.@dnsmasq[0].server')" = '1.1.1.1' ] || fail 'scalar server snapshot was not restored'
[ "$(value 'dhcp.@dnsmasq[0].noresolv')" = 0 ] || fail 'noresolv snapshot was not restored'
absent 'dhcp.@dnsmasq[0].cachesize'
absent 'dhcp.@dnsmasq[0].forkop_dns_version'

# Explicit empty and absent server options are separate states and survive a
# transaction as such.
cat >"$STATE" <<'EOF_STATE'
dhcp.@dnsmasq[0].server=
EOF_STATE
ucode -L "$FORKOP_LIB" "$APPLY" configure force
ucode -L "$FORKOP_LIB" "$APPLY" failsafe-restore
grep -Fqx 'dhcp.@dnsmasq[0].server=' "$STATE" || fail 'explicit empty server was not restored'

: >"$STATE"
ucode -L "$FORKOP_LIB" "$APPLY" configure force
ucode -L "$FORKOP_LIB" "$APPLY" failsafe-restore
absent 'dhcp.@dnsmasq[0].server'

# A server snapshot marked as a UCI list is restored with add_list(), retaining
# the declared order. The text fixture serializes lists as space-separated text,
# while production UCI preserves the array/list type.
cat >"$STATE" <<'EOF_STATE'
dhcp.@dnsmasq[0].server=127.0.0.42
dhcp.@dnsmasq[0].noresolv=1
dhcp.@dnsmasq[0].cachesize=0
dhcp.@dnsmasq[0].forkop_dns_version=1
dhcp.@dnsmasq[0].forkop_dns_transaction_id=list-test
dhcp.@dnsmasq[0].forkop_dns_server_present=1
dhcp.@dnsmasq[0].forkop_dns_server_kind=list
dhcp.@dnsmasq[0].forkop_dns_server=1.1.1.1#53 8.8.8.8#53 9.9.9.9#53
dhcp.@dnsmasq[0].forkop_dns_noresolv_present=0
dhcp.@dnsmasq[0].forkop_dns_cachesize_present=0
EOF_STATE
ucode -L "$FORKOP_LIB" "$APPLY" failsafe-restore
[ "$(value 'dhcp.@dnsmasq[0].server')" = '1.1.1.1#53 8.8.8.8#53 9.9.9.9#53' ] || fail 'multi-value server list order was not restored'
absent 'dhcp.@dnsmasq[0].forkop_dns_server_kind'

# A marker is not ownership proof. Incomplete or malformed transactions are
# retained untouched, and neither cleanup path may restart dnsmasq.
for invalid in version-only missing-id bad-presence missing-value; do
  case "$invalid" in
    version-only) snapshot='dhcp.@dnsmasq[0].forkop_dns_version=1' ;;
    missing-id) snapshot='dhcp.@dnsmasq[0].forkop_dns_version=1
dhcp.@dnsmasq[0].forkop_dns_server_present=0
dhcp.@dnsmasq[0].forkop_dns_noresolv_present=0
dhcp.@dnsmasq[0].forkop_dns_cachesize_present=0' ;;
    bad-presence) snapshot='dhcp.@dnsmasq[0].forkop_dns_version=1
dhcp.@dnsmasq[0].forkop_dns_transaction_id=bad-presence
dhcp.@dnsmasq[0].forkop_dns_server_present=2
dhcp.@dnsmasq[0].forkop_dns_noresolv_present=0
dhcp.@dnsmasq[0].forkop_dns_cachesize_present=0' ;;
    missing-value) snapshot='dhcp.@dnsmasq[0].forkop_dns_version=1
dhcp.@dnsmasq[0].forkop_dns_transaction_id=missing-value
dhcp.@dnsmasq[0].forkop_dns_server_present=1
dhcp.@dnsmasq[0].forkop_dns_server_kind=list
dhcp.@dnsmasq[0].forkop_dns_noresolv_present=0
dhcp.@dnsmasq[0].forkop_dns_cachesize_present=0' ;;
  esac
  printf 'dhcp.@dnsmasq[0].server=127.0.0.42\ndhcp.@dnsmasq[0].noresolv=1\ndhcp.@dnsmasq[0].cachesize=0\n%s\n' "$snapshot" >"$STATE"
  cp "$STATE" "$WORK_DIR/invalid.before"
  : >"$DNSMASQ_LOG"
  ucode -L "$FORKOP_LIB" "$APPLY" failsafe-restore
  cmp -s "$WORK_DIR/invalid.before" "$STATE" || fail "invalid snapshot $invalid was changed"
  [ ! -s "$DNSMASQ_LOG" ] || fail "invalid snapshot $invalid restarted dnsmasq"
  : >"$DNSMASQ_LOG"
  if ucode -L "$FORKOP_LIB" "$APPLY" configure force; then fail "invalid snapshot $invalid allowed configure"; fi
  cmp -s "$WORK_DIR/invalid.before" "$STATE" || fail "invalid snapshot $invalid was changed by configure"
  [ ! -s "$DNSMASQ_LOG" ] || fail "invalid snapshot $invalid configured dnsmasq"
done

# An external change wins its field; rollback restores only the untouched ones
# and consumes the transaction, making a second rollback a no-op.
cat >"$STATE" <<'EOF_STATE'
dhcp.@dnsmasq[0].server=1.1.1.1 8.8.8.8
dhcp.@dnsmasq[0].noresolv=0
EOF_STATE
ucode -L "$FORKOP_LIB" "$APPLY" configure force
sed -i 's/^dhcp.@dnsmasq\[0\].server=.*/dhcp.@dnsmasq[0].server=9.9.9.9/' "$STATE"
: >"$DNSMASQ_LOG"
ucode -L "$FORKOP_LIB" "$APPLY" failsafe-restore
[ "$(value 'dhcp.@dnsmasq[0].server')" = 9.9.9.9 ] || fail 'external server change was overwritten'
absent 'dhcp.@dnsmasq[0].forkop_dns_version'
: >"$DNSMASQ_LOG"
ucode -L "$FORKOP_LIB" "$APPLY" failsafe-restore
[ ! -s "$DNSMASQ_LOG" ] || fail 'rollback is not idempotent'

printf 'DNS rollback transaction checks passed\n'
