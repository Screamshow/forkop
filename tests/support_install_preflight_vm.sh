#!/bin/sh
# Mock managers: never install packages or stop the primary service.
set -eu
test_dir=$(mktemp -d /tmp/forkop-support-preflight.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
mkdir "$test_dir/bin" "$test_dir/session"
for command in cat cut tr mv rm rmdir sleep awk sed; do
    ln -s /bin/busybox "$test_dir/bin/$command"
done
cat > "$test_dir/bin/df" <<'EOF'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nmock 100000 0 %s 0%% /overlay\n' "$TEST_FREE_KIB"
EOF
cat > "$test_dir/bin/opkg" <<'EOF'
#!/bin/sh
if [ "$1" = info ]; then
    printf 'Installed-Size: %s\n' "${TEST_PACKAGE_BYTES:-23275520}"
    exit 0
fi
printf '%s\n' "$*" >> "$TEST_CALLS"
printf 'mock repository error: "missing package" <details>\n'
[ "$1" = update ] && [ "$TEST_FAIL_UPDATE" = 0 ] && exit 0
exit 1
EOF
chmod 755 "$test_dir/bin/df" "$test_dir/bin/opkg"
export FORKOP_SUPPORT_DIR="$test_dir/session"
export TEST_CALLS="$test_dir/calls"
export PATH="$test_dir/bin"
export TEST_FREE_KIB=21893 TEST_FAIL_UPDATE=0
printf install > "$FORKOP_SUPPORT_DIR/operation"
if /bin/sh /usr/lib/forkop/support/worker.sh; then exit 1; fi
/usr/bin/jsonfilter -i "$FORKOP_SUPPORT_DIR/status.json" -e '@.error' | /bin/grep -q 'Not enough free storage'
[ ! -f "$TEST_CALLS" ]
[ ! -e "$FORKOP_SUPPORT_DIR/operation" ]
export TEST_FREE_KIB=100000
for TEST_FAIL_UPDATE in 0 1; do
    export TEST_FAIL_UPDATE
    /bin/rm -f "$TEST_CALLS"
    printf install > "$FORKOP_SUPPORT_DIR/operation"
    if /bin/sh /usr/lib/forkop/support/worker.sh; then exit 1; fi
    /bin/grep -q 'mock repository error' "$FORKOP_SUPPORT_DIR/package.log"
    /usr/bin/jsonfilter -i "$FORKOP_SUPPORT_DIR/status.json" -e '@.error' | /bin/grep -q 'Tailscale installation failed'
    if [ "$TEST_FAIL_UPDATE" = 1 ]; then
        [ "$(cat "$TEST_CALLS")" = update ]
    else
        /bin/grep -q '^install tailscale$' "$TEST_CALLS"
    fi
done
export TEST_FREE_KIB=30000 TEST_PACKAGE_BYTES=unknown
printf install > "$FORKOP_SUPPORT_DIR/operation"
if /bin/sh /usr/lib/forkop/support/worker.sh; then exit 1; fi
[ "$(/usr/bin/jsonfilter -i "$FORKOP_SUPPORT_DIR/status.json" -e '@.required_kib')" = 32768 ]
cat > "$test_dir/bin/apk" <<'EOF'
#!/bin/sh
printf 'mock APK solver error\n'
exit 1
EOF
/bin/chmod 755 "$test_dir/bin/apk"
export TEST_FREE_KIB=100000
printf install > "$FORKOP_SUPPORT_DIR/operation"
if /bin/sh /usr/lib/forkop/support/worker.sh; then exit 1; fi
/bin/grep -q 'mock APK solver error' "$FORKOP_SUPPORT_DIR/package.log"
# Check bounded, JSON-safe diagnostics through the actual API module.
sed "s|const DIR = '/var/run/forkop/support';|const DIR = '$FORKOP_SUPPORT_DIR';|" /usr/lib/forkop/support/session.uc > "$test_dir/session.uc"
export TEST_SUPPORT_MODULE="$test_dir/session.uc"
cat > "$test_dir/check.uc" <<'EOF'
let fs = require('fs');
let dir = getenv('FORKOP_SUPPORT_DIR');
let message = '"<details>"\n';
for (let i = 0; i < 5000; i++) message += 'x';
fs.writefile(dir + '/package.log', message);
let module = loadfile(getenv('TEST_SUPPORT_MODULE'))();
let result = module.status();
if (length(result.error_detail) != 4096 || substr(result.error_detail, 0, 11) != '"<details>"') die('Invalid diagnostic detail');
let encoded = json(sprintf('%J', result));
if (encoded.error_detail != result.error_detail) die('Invalid JSON escaping');
EOF
/usr/bin/ucode "$test_dir/check.uc"
echo 'storage preflight, fallback estimate and package diagnostics passed'
