#!/bin/sh
# Downloads to a disposable private directory; never changes system Tailscale.
set -eu
test_dir=$(mktemp -d /root/forkop-lite-test.XXXXXX)
dir=$(mktemp -d /tmp/forkop-lite-session.XXXXXX)
primary_pid=
trap '[ -z "$primary_pid" ] || kill "$primary_pid" 2>/dev/null || true; rm -rf "$test_dir" "$dir"' EXIT
export FORKOP_SUPPORT_LITE_DIR="$test_dir/lite"
free_kib=0 required_kib=0 error=
state() { :; }
. /usr/lib/forkop/support/lite-install.sh
df() {
    if [ -n "$test_free" ]; then printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nmock 1000000 0 %s 0%% /\n' "$test_free";
    else command df "$@"; fi
}
test_free=1
if install_lite; then echo 'low-space install succeeded'; exit 1; fi
[ "$error" = 'Not enough free storage to install Tailscale' ]
[ ! -e "$FORKOP_SUPPORT_LITE_DIR" ]
test_free=
install_lite
"$FORKOP_SUPPORT_LITE_DIR/tailscale" version | grep -q '1.98.3'
test -f "$FORKOP_SUPPORT_LITE_DIR/.forkop-lite"
test ! -e "$dir/lite.download"
sed -e "s|const LITE = '/usr/lib/forkop-support';|const LITE = '$FORKOP_SUPPORT_LITE_DIR';|" -e "s|const DIR = '/var/run/forkop/support';|const DIR = '$dir';|" /usr/lib/forkop/support/session.uc > "$test_dir/session.uc"
export TEST_SUPPORT_MODULE="$test_dir/session.uc"
cat > "$test_dir/check.uc" <<'EOF'
let m = loadfile(getenv('TEST_SUPPORT_MODULE'))();
let status = m.status();
if (!status.lite_installed || !status.installed || status.version != '1.98.3') die('Lite status detection failed');
let fs = require('fs');
let file = getenv('FORKOP_SUPPORT_DIR') + '/status.json';
fs.writefile(file, '{"phase":"failed","error":"old package error","required_kib":32768}');
status = m.status();
if (status.phase != 'stopped' || status.error != '' || status.required_kib != 0) die('Legacy error was retained');
fs.writefile(file, '{"schema":2,"phase":"failed","error":"current Lite error","required_kib":18000}');
status = m.status();
if (status.phase != 'failed' || status.error != 'current Lite error' || status.required_kib != 18000) die('Current error was lost');
fs.unlink(file);
EOF
FORKOP_SUPPORT_DIR="$dir" ucode "$test_dir/check.uc"
if install_lite; then echo 'existing directory overwritten'; exit 1; fi
[ "$error" = 'The Tailscale Lite directory already exists' ]
# Tampered downloads must never create an executable installation.
good_lite="$FORKOP_SUPPORT_LITE_DIR"
export FORKOP_SUPPORT_LITE_DIR="$test_dir/rejected"
curl() { printf tampered > "$dir/lite.download"; }
if install_lite; then echo 'tampered binary installed'; exit 1; fi
[ "$error" = 'Tailscale Lite verification failed' ]
[ ! -e "$FORKOP_SUPPORT_LITE_DIR" ]
unset -f curl
export FORKOP_SUPPORT_LITE_DIR="$good_lite"
# A separate standard daemon remains alive during/after the Lite session.
tailscaled --tun=userspace-networking --state=mem: --statedir="$test_dir/primary" --socket="$test_dir/primary.socket" --port=0 --no-logs-no-support >/dev/null 2>&1 &
primary_pid=$!
# Worker test uses the real Lite daemon with a synthetic auth CLI.
mv "$FORKOP_SUPPORT_LITE_DIR/tailscale" "$FORKOP_SUPPORT_LITE_DIR/tailscale.real"
cat > "$FORKOP_SUPPORT_LITE_DIR/tailscale" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 "$FORKOP_SUPPORT_LITE_DIR/tailscale"
export FORKOP_SUPPORT_DIR="$dir" FORKOP_SUPPORT_TTL=3
export FORKOP_SUPPORT_AUTHORIZED_KEYS="$test_dir/authorized_keys"
printf start > "$dir/operation"
printf synthetic-test-credential > "$dir/auth.key"
sh /usr/lib/forkop/support/worker.sh
[ "$(jsonfilter -i "$dir/status.json" -e '@.phase')" = stopped ]
test ! -e "$dir/socket"
test ! -e "$test_dir/authorized_keys"
kill -0 "$primary_pid"
rm "$FORKOP_SUPPORT_LITE_DIR/tailscale"
mv "$FORKOP_SUPPORT_LITE_DIR/tailscale.real" "$FORKOP_SUPPORT_LITE_DIR/tailscale"
printf remove > "$dir/operation"
sh /usr/lib/forkop/support/worker.sh
test ! -e "$FORKOP_SUPPORT_LITE_DIR"
kill -0 "$primary_pid"
kill "$primary_pid"
wait "$primary_pid" || true
primary_pid=
echo 'Lite mirror install, tamper rejection, parallel daemon, removal and cleanup passed'
