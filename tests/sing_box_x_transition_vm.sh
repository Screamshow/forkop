#!/bin/sh
set -eu
[ "${FORKOP_TEST_VM:-}" = 1 ] || { echo 'FORKOP_TEST_VM=1 required' >&2; exit 1; }
ubus call system board | grep -qi VMware || { echo 'Existing VMware VM required' >&2; exit 1; }
lib="${FORKOP_LIB:-/usr/lib/forkop}"
work="$(mktemp -d /tmp/forkop-x-matrix.XXXXXX)"
fail() { echo "FAIL: $*; evidence: $work" >&2; exit 1; }
variant() { ucode -L "$lib" "$lib/singbox/runtime.uc" variant; }
snapshot() {
  if command -v apk >/dev/null; then apk info -v; else opkg list-installed; fi
  ubus call service list
  forkop get_status
  df -Pk /usr/bin /tmp
}
run() { ucode -L "$lib" "$lib/components/action.uc" component-action sing_box "$1"; }
cp /etc/config/forkop "$work/forkop.uci"
cp /etc/config/sing-box "$work/sing-box.uci"
verify() {
  [ "$(variant)" = "$1" ] || fail "expected $1, got $(variant)"
  cmp /etc/config/forkop "$work/forkop.uci" || fail 'Forkop UCI changed'
  cmp /etc/config/sing-box "$work/sing-box.uci" || fail 'sing-box UCI changed'
  sing-box check -c /etc/sing-box/config.json >"$work/config-$1.log" 2>&1 || fail 'generated configuration invalid'
  [ "$(forkop get_status | jsonfilter -e '@.running')" = 1 ] || fail 'Forkop did not restart'
  nslookup example.com 127.0.0.1 >"$work/dns-$1.log" 2>&1 || fail 'DNS failed'
}
transition() {
  snapshot >"$work/before-$1.txt"
  run "$1" >"$work/$1.log" 2>&1 || fail "$1 failed"
  verify "$2"
  echo "PASS: $1 -> $2"
}
snapshot >"$work/before.txt"
if [ "${FORKOP_TEST_RESUME_FAULTS:-0}" != 1 ]; then
transition install_x x
transition install_x x
run check_update >"$work/check.log" || fail 'X update check failed'
[ "$(tail -n 1 "$work/check.log" | jsonfilter -e '@.current_version')" = 1.0.0 ] || fail 'upstream version used instead of X build version'
transition install x
transition install_tiny tiny
transition install_x x
transition install_stable stable
transition install_x x
snapshot >"$work/before-extended.txt"
if run install_extended >"$work/install_extended.log" 2>&1; then
  verify extended
  echo 'PASS: X -> Extended'
  transition install_x x
else
  grep -q 'Not enough flash space' "$work/install_extended.log" || fail 'unexpected Extended failure'
  verify x
  echo 'PASS: Extended flash shortage preserves X'
fi
snapshot >"$work/before-compressed.txt"
if run install_extended_compressed >"$work/install_extended_compressed.log" 2>&1; then
  verify extended-compressed
  echo 'PASS: X -> Extended compressed'
  transition install_x x
else
  grep -Eq 'Not enough flash space|Downloaded sing-box-extended compressed failed validation' "$work/install_extended_compressed.log" || fail 'unexpected compressed failure'
  verify x
  echo 'PASS: compressed preflight failure preserves X (see log for reason)'
fi
fi
if [ "$(variant)" != tiny ]; then
  transition install_tiny tiny
else
  verify tiny
fi

# Fail the target local package transaction, then permit the exact cached
# previous package to be restored by the normal component action.
manager="$(command -v apk || command -v opkg)"
mkdir "$work/fault-bin"
cat >"$work/fault-bin/$(basename "$manager")" <<'EOF'
#!/bin/sh
for arg in "$@"; do
  case "$arg" in */sing-box-x_*.apk|*/sing-box-x_*.ipk)
    case " $* " in *' add '*|*' install '*)
      echo 'injected X package installation failure' >&2
      exit 42
    esac ;;
  esac
done
exec "$FORKOP_TEST_REAL_MANAGER" "$@"
EOF
chmod 755 "$work/fault-bin/$(basename "$manager")"
snapshot >"$work/before-package-failure.txt"
if PATH="$work/fault-bin:$PATH" FORKOP_TEST_REAL_MANAGER="$manager" run install_x >"$work/package-failure.log" 2>&1; then
  fail 'injected package failure reported success'
fi
grep -q 'previous sing-box variant was restored' "$work/package-failure.log" || fail 'package rollback not confirmed'
verify tiny
echo 'PASS: failed X installation restores Tiny package and runtime'
transition install_x x
snapshot >"$work/before-download-failure.txt"
if FORKOP_MIRROR_BASE_URL=http://127.0.0.1:9 run install_x >"$work/download-failure.log" 2>&1; then
  fail 'unreachable mirror accepted'
fi
verify x
echo 'PASS: mirror failure preserves X'
snapshot >"$work/after.txt"
echo "X matrix complete; evidence: $work"
