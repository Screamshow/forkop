#!/bin/sh
set -eu
[ "${FORKOP_TEST_VM:-}" = 1 ] || exit 1
ubus call system board | grep -qi VMware || exit 1
lib=${FORKOP_LIB:-/usr/lib/forkop}
work=$(mktemp -d /tmp/forkop-tmp-shortage.XXXXXX)
mkdir "$work/bin"
if command -v apk >/dev/null; then apk info -v >"$work/packages.before"; else opkg list-installed >"$work/packages.before"; fi
ubus call service list >"$work/services.before"
cp /etc/config/forkop /etc/config/sing-box "$work/"
sha256sum /usr/bin/sing-box >"$work/binary.sha256"
cat >"$work/bin/df" <<'EOF'
#!/bin/sh
if [ "$1" = -Pk ]; then
  case "$2" in /tmp/*)
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\ntmpfs 100000 99000 1000 99%% /tmp\n'; exit 0;;
  esac
fi
exec /bin/df "$@"
EOF
chmod 755 "$work/bin/df"
if PATH="$work/bin:$PATH" ucode -L "$lib" "$lib/components/action.uc" component-action sing_box install_x >"$work/action.log" 2>&1; then
  echo 'FAIL: tmp shortage accepted' >&2; exit 1
fi
grep -q 'Not enough temporary memory' "$work/action.log"
sha256sum -c "$work/binary.sha256" >/dev/null
cmp /etc/config/forkop "$work/forkop"
cmp /etc/config/sing-box "$work/sing-box"
if command -v apk >/dev/null; then apk info -v >"$work/packages.after"; else opkg list-installed >"$work/packages.after"; fi
cmp "$work/packages.before" "$work/packages.after"
[ "$(forkop get_status | jsonfilter -e '@.running')" = 1 ]
echo "PASS: tmp shortage rejected before package mutation; binary, UCI and runtime preserved; evidence: $work"
