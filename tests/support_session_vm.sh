#!/bin/sh
# Run on an OpenWrt VM with Tailscale and the candidate worker installed.
# Synthetic credentials stay inside the mocked CLI; no tailnet registration.
set -eu
test_dir=$(mktemp -d /tmp/forkop-support-test.XXXXXX)
real_daemon=$(command -v tailscaled)
trap 'rm -rf "$test_dir"' EXIT
mkdir "$test_dir/bin" "$test_dir/session"
cat > "$test_dir/bin/tailscale" <<'EOF'
#!/bin/sh
set -eu
test -f "$FORKOP_SUPPORT_DIR/auth.key"
test "$(ls -ld "$FORKOP_SUPPORT_DIR/auth.key" | cut -d' ' -f1)" = '-rw-------'
test "$(ls -ld "$FORKOP_SUPPORT_DIR" | cut -d' ' -f1)" = 'drwx------'
case "$*" in *tskey-auth-*) exit 1;; esac
exit 0
EOF
printf '#!/bin/sh\nexec "%s" "$@"\n' "$real_daemon" > "$test_dir/bin/tailscaled"
chmod 755 "$test_dir/bin/"*
export PATH="$test_dir/bin:$PATH"
export FORKOP_SUPPORT_DIR="$test_dir/session"
export FORKOP_SUPPORT_AUTHORIZED_KEYS="$test_dir/authorized_keys"
chmod 700 "$FORKOP_SUPPORT_DIR"
export FORKOP_SUPPORT_TTL=3
printf start > "$FORKOP_SUPPORT_DIR/operation"
printf synthetic-test-credential > "$FORKOP_SUPPORT_DIR/auth.key"
chmod 600 "$FORKOP_SUPPORT_DIR/auth.key"
mkdir "$FORKOP_SUPPORT_DIR/lock"
sh /usr/lib/forkop/support/worker.sh
test "$(jsonfilter -i "$FORKOP_SUPPORT_DIR/status.json" -e '@.phase')" = stopped
test ! -e "$FORKOP_SUPPORT_DIR/auth.key"
test ! -e "$FORKOP_SUPPORT_DIR/socket"
test ! -d "$FORKOP_SUPPORT_DIR/lock"
echo 'timer, credential permissions and cleanup passed'

export FORKOP_SUPPORT_TTL=120
printf start > "$FORKOP_SUPPORT_DIR/operation"
printf synthetic-test-credential > "$FORKOP_SUPPORT_DIR/auth.key"
chmod 600 "$FORKOP_SUPPORT_DIR/auth.key"
mkdir "$FORKOP_SUPPORT_DIR/lock"
sh /usr/lib/forkop/support/worker.sh &
worker=$!
sleep 2
kill "$worker"
wait "$worker"
test ! -e "$FORKOP_SUPPORT_DIR/auth.key"
test ! -e "$FORKOP_SUPPORT_DIR/socket"
test ! -d "$FORKOP_SUPPORT_DIR/lock"
echo 'manual cancellation cleanup passed'

# A stalled auth client must not outlive the session deadline.
printf '#!/bin/sh\nexec /bin/sleep 120\n' > "$test_dir/bin/tailscale"
export FORKOP_SUPPORT_TTL=3
printf start > "$FORKOP_SUPPORT_DIR/operation"
printf synthetic-test-credential > "$FORKOP_SUPPORT_DIR/auth.key"
chmod 600 "$FORKOP_SUPPORT_DIR/auth.key"
mkdir "$FORKOP_SUPPORT_DIR/lock"
if sh /usr/lib/forkop/support/worker.sh; then
    echo 'stalled authorization unexpectedly succeeded'; exit 1
fi
test "$(jsonfilter -i "$FORKOP_SUPPORT_DIR/status.json" -e '@.phase')" = failed
test ! -e "$FORKOP_SUPPORT_DIR/auth.key"
test ! -e "$FORKOP_SUPPORT_DIR/socket"
test ! -d "$FORKOP_SUPPORT_DIR/lock"
echo 'stalled authorization deadline and cleanup passed'
