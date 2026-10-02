#!/bin/sh
# No real package mutations. Requires the main Tailscale service disabled/stopped.
set -eu
test_dir=$(mktemp -d /tmp/forkop-support-package-test.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
mkdir "$test_dir/bin" "$test_dir/session"
for command in cat cut tr mv rm rmdir sleep; do
    ln -s /bin/busybox "$test_dir/bin/$command"
done
export FORKOP_SUPPORT_DIR="$test_dir/session"
export FORKOP_SUPPORT_PACKAGE_LOG="$test_dir/package.log"
export PATH="$test_dir/bin"
for manager in apk opkg; do
    /bin/rm -f "$test_dir/bin/apk" "$test_dir/bin/opkg"
    /bin/cat > "$test_dir/bin/$manager" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$FORKOP_SUPPORT_PACKAGE_LOG"
exit "${FORKOP_SUPPORT_PACKAGE_EXIT:-0}"
EOF
    /bin/chmod 755 "$test_dir/bin/$manager"
    for result in 0 1; do
        export FORKOP_SUPPORT_PACKAGE_EXIT=$result
        printf remove > "$FORKOP_SUPPORT_DIR/operation"
        /bin/mkdir "$FORKOP_SUPPORT_DIR/lock"
        if /bin/sh /usr/lib/forkop/support/worker.sh; then actual=0; else actual=1; fi
        [ "$actual" = "$result" ]
        expected='remove tailscale'
        [ "$manager" != apk ] || expected='del tailscale'
        [ "$(cat "$FORKOP_SUPPORT_PACKAGE_LOG")" = "$expected" ]
        test ! -d "$FORKOP_SUPPORT_DIR/lock"
        test ! -e "$FORKOP_SUPPORT_DIR/operation"
    done
done
echo 'APK and OPKG removal success/failure cleanup passed (mock managers)'
