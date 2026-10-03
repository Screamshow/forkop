#!/bin/sh
set -eu
test_dir=$(mktemp -d /tmp/ts-redaction.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
printf 'synthetic-private-credential' > "$test_dir/auth.key"
printf 'Received error: http 502 synthetic-private-credential tskey-auth-synthetic-not-a-real-key\nTryLogin: https://login.tailscale.com/a/private-code\nx509: certificate failure\n' > "$test_dir/daemon.log"
printf 'timeout waiting for Running\n' > "$test_dir/auth.log"
FORKOP_SUPPORT_DIR="$test_dir" ucode /usr/lib/forkop/support/auth-diagnostic.uc
grep -q 'http 502' "$test_dir/auth-detail.txt"
grep -q 'x509' "$test_dir/auth-detail.txt"
if grep -E 'synthetic-private-credential|tskey-|private-code' "$test_dir/auth-detail.txt"; then exit 1; fi
echo 'Auth diagnostics retained; credentials/login links redacted'
