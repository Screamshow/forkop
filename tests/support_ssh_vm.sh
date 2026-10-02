#!/bin/sh
# Isolated file tests; no production authorized_keys changes.
set -eu
umask 077
test_dir=$(mktemp -d /tmp/forkop-support-ssh-test.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
export FORKOP_SUPPORT_AUTHORIZED_KEYS="$test_dir/authorized_keys"
printf '# client keys with no trailing newline' > "$test_dir/original"
cp "$test_dir/original" "$FORKOP_SUPPORT_AUTHORIZED_KEYS"
ucode /usr/lib/forkop/support/ssh-access.uc add
test "$(ls -ld "$FORKOP_SUPPORT_AUTHORIZED_KEYS" | cut -d' ' -f1)" = '-rw-------'
test "$(grep -c forkop-support-temporary "$FORKOP_SUPPORT_AUTHORIZED_KEYS")" = 1
ucode /usr/lib/forkop/support/ssh-access.uc add
test "$(grep -c forkop-support-temporary "$FORKOP_SUPPORT_AUTHORIZED_KEYS")" = 1
printf '\n# concurrent client key\n' >> "$FORKOP_SUPPORT_AUTHORIZED_KEYS"
ucode /usr/lib/forkop/support/ssh-access.uc remove
printf '\n# concurrent client key\n' >> "$test_dir/original"
cmp "$test_dir/original" "$FORKOP_SUPPORT_AUTHORIZED_KEYS"
ucode /usr/lib/forkop/support/ssh-access.uc remove
cmp "$test_dir/original" "$FORKOP_SUPPORT_AUTHORIZED_KEYS"
rm "$FORKOP_SUPPORT_AUTHORIZED_KEYS"
ucode /usr/lib/forkop/support/ssh-access.uc add
ucode /usr/lib/forkop/support/ssh-access.uc remove
test ! -e "$FORKOP_SUPPORT_AUTHORIZED_KEYS"
ln -s "$test_dir/original" "$FORKOP_SUPPORT_AUTHORIZED_KEYS"
if ucode /usr/lib/forkop/support/ssh-access.uc add >/dev/null 2>&1; then
    echo 'symlink authorization file was unexpectedly replaced'; exit 1
fi
echo 'temporary SSH key permissions, idempotence, client edits and symlink protection passed'
