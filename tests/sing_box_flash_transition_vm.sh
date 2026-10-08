#!/bin/sh
set -eu
[ "${FORKOP_TEST_VM:-}" = 1 ] || exit 1
ubus call system board | grep -qi VMware || exit 1
lib=${FORKOP_LIB:-/usr/lib/forkop}
work=$(mktemp -d /tmp/forkop-flash-matrix.XXXXXX)
manager=$(command -v apk || command -v opkg)
export FORKOP_TEST_REAL_MANAGER="$manager"
export FORKOP_TEST_FAULT_ONCE="$work/install-fault-fired"
fail() { echo "FAIL: $*; evidence: $work" >&2; exit 1; }
run() { ucode -L "$lib" "$lib/components/action.uc" component-action sing_box "$1"; }
variant() { ucode -L "$lib" "$lib/singbox/runtime.uc" variant; }
snapshot() {
  if command -v apk >/dev/null; then apk info -v; else opkg list-installed; fi
  ubus call service list
  df -Pk /usr/bin /tmp
}
packages() { if command -v apk >/dev/null; then apk info -v; else opkg list-installed; fi; }
verify() {
  [ "$(variant)" = "$1" ] || fail "variant should be $1"
  cmp /etc/config/forkop "$work/forkop.uci" || fail 'Forkop UCI changed'
  cmp /etc/config/sing-box "$work/sing-box.uci" || fail 'sing-box UCI changed'
  sing-box check -c /etc/sing-box/config.json >"$work/check.log" 2>&1 || fail 'invalid configuration'
  [ "$(forkop get_status | jsonfilter -e '@.running')" = 1 ] || fail 'runtime not restored'
  [ "$(ucode -L "$lib" "$lib/service/state.uc" sing-box-process-count)" = 1 ] || fail 'runtime process count'
  nslookup example.com 127.0.0.1 >"$work/dns.log" 2>&1 || fail 'DNS recovery'
}
cp /etc/config/forkop "$work/forkop.uci"
cp /etc/config/sing-box "$work/sing-box.uci"
snapshot >"$work/before-x.txt"
run install_x >"$work/install-x.log" 2>&1 || fail 'initial X installation'
verify x
sing-box version | grep -q '1.14.2-x-1.0.2' || fail 'wrong X build'
echo 'PASS: final Forkop package installs mirror X 1.0.2'
mkdir "$work/fault-bin"
cat >"$work/fault-bin/$(basename "$manager")" <<'EOF'
#!/bin/sh
for arg in "$@"; do
  case "$arg" in */sing-box-x_*.apk|*/sing-box-x_*.ipk)
    case " $* " in *' add '*|*' install '*)
      if [ ! -e "$FORKOP_TEST_FAULT_ONCE" ]; then
        touch "$FORKOP_TEST_FAULT_ONCE"; echo 'injected X install failure' >&2; exit 42
      fi;; esac;;
  esac
done
exec "$FORKOP_TEST_REAL_MANAGER" "$@"
EOF
cat >"$work/fault-bin/df" <<'EOF'
#!/bin/sh
case " $* " in
  *' -PT '*) printf '/dev/test ubifs 500000 460284 39716 92%% /\n'; exit 0;;
  *' -Pk '*'/usr/bin'*)
    if [ -x /usr/bin/sing-box ] || [ "${FORKOP_TEST_DF_POST_SHORTAGE:-1}" = 0 ]; then free=39716; else free=1000; fi
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/test 500000 460284 %s 92%% /\n' "$free"; exit 0;;
esac
exec /bin/df "$@"
EOF
chmod 755 "$work/fault-bin/"*
for mode in extended extended_compressed; do
  snapshot >"$work/before-$mode.txt"
  if ! run "install_$mode" >"$work/install-$mode.log" 2>&1; then
    grep -Eq 'Not enough flash space|Not enough temporary memory|failed validation' "$work/install-$mode.log" || fail "unexpected $mode failure"
    verify x
    echo "LIMIT: $mode does not fit this VM; X and UCI preserved"
    continue
  fi
  expected=$(printf '%s' "$mode" | tr _ -)
  verify "$expected"
  sha256sum /usr/bin/sing-box >"$work/binary-before-$mode.sha256"
  echo "PASS: X -> $expected"
  # Exercise compressed-filesystem credit with the screenshot's free space,
  # then make the authoritative post-removal check reject the transaction.
  snapshot >"$work/before-ubifs-failure-$mode.txt"
  packages >"$work/packages-before-$mode"
  if PATH="$work/fault-bin:$PATH" run install_x >"$work/ubifs-failure-$mode.log" 2>&1; then fail 'post-removal shortage accepted'; fi
  grep -q 'Not enough flash space' "$work/ubifs-failure-$mode.log" || fail 'no authoritative flash rejection'
  grep -q 'previous sing-box variant was restored' "$work/ubifs-failure-$mode.log" || fail 'rollback not confirmed'
  verify "$expected"
  packages >"$work/packages-after-$mode"
  cmp "$work/packages-before-$mode" "$work/packages-after-$mode" || fail 'rollback package/dependency revisions differ'
  sha256sum -c "$work/binary-before-$mode.sha256" >/dev/null || fail 'rollback bytes differ'
  echo "PASS: simulated UBIFS / post-removal shortage restores exact $expected and runtime"
  # Use actual df while injecting a package-manager error after removal.
  mv "$work/fault-bin/df" "$work/df.saved"
  snapshot >"$work/before-install-failure-$mode.txt"
  rm -f "$FORKOP_TEST_FAULT_ONCE"
  if PATH="$work/fault-bin:$PATH" run install_x >"$work/install-failure-$mode.log" 2>&1; then fail 'package failure accepted'; fi
  [ -e "$FORKOP_TEST_FAULT_ONCE" ] || fail 'installation fault not reached'
  grep -q 'previous sing-box variant was restored' "$work/install-failure-$mode.log" || fail 'rollback not confirmed'
  verify "$expected"
  packages >"$work/packages-after-$mode"
  cmp "$work/packages-before-$mode" "$work/packages-after-$mode" || fail 'rollback package/dependency revisions differ'
  sha256sum -c "$work/binary-before-$mode.sha256" >/dev/null || fail 'rollback bytes differ'
  mv "$work/df.saved" "$work/fault-bin/df"
  echo "PASS: failed X install restores exact $expected and runtime"
  snapshot >"$work/before-return-x-$mode.txt"
  FORKOP_TEST_DF_POST_SHORTAGE=0 PATH="$work/fault-bin:$PATH" run install_x >"$work/return-x-$mode.log" 2>&1 || fail "return from $expected to X"
  verify x
  echo "PASS: simulated UBIFS / 39716 KiB free: $expected -> X 1.0.2"
done
mv "$work/fault-bin/df" "$work/df.saved"
rm -f "$FORKOP_TEST_FAULT_ONCE"
sha256sum /usr/bin/sing-box >"$work/x-before-failure.sha256"
snapshot >"$work/before-x-reinstall-failure.txt"
packages >"$work/packages-before-x-failure"
if PATH="$work/fault-bin:$PATH" run install_x >"$work/x-reinstall-failure.log" 2>&1; then fail 'X reinstall failure accepted'; fi
[ -e "$FORKOP_TEST_FAULT_ONCE" ] || fail 'reinstall fault not reached'
grep -q 'previous sing-box variant was restored' "$work/x-reinstall-failure.log" || fail 'X rollback not confirmed'
verify x
packages >"$work/packages-after-x-failure"
cmp "$work/packages-before-x-failure" "$work/packages-after-x-failure" || fail 'X rollback dependency revisions differ'
sha256sum -c "$work/x-before-failure.sha256" >/dev/null || fail 'X rollback bytes differ'
echo 'PASS: failed X reinstall restores exact X package and runtime'
snapshot >"$work/after.txt"
echo "FLASH_MATRIX_COMPLETE; evidence: $work"
