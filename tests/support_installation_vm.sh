#!/bin/sh
# RAM-only status fixtures; no packages, services or credentials are changed.
set -eu
LIB=${LIB:-/usr/lib/forkop/support}
TEST_ROOT=$(mktemp -d /tmp/forkop-support-installation.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT
export LIB TEST_ROOT
mkdir "$TEST_ROOT/bin" "$TEST_ROOT/lite" "$TEST_ROOT/session"
cat > "$TEST_ROOT/bin/ubus" <<'EOF'
#!/bin/sh
printf '{}'
EOF
cat > "$TEST_ROOT/bin/apk" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 755 "$TEST_ROOT/bin/ubus" "$TEST_ROOT/bin/apk"
UCODE=$(command -v ucode)
API_TEST=${API_TEST:-$(dirname "$0")/support_installation_vm.uc}
check() {
    PATH="$TEST_ROOT/bin" EXPECT_SYSTEM="$1" EXPECT_LITE="$2" EXPECT_VERSION="$3" "$UCODE" "$API_TEST"
}
check false false ''
cat > "$TEST_ROOT/bin/tailscale" <<'EOF'
#!/bin/sh
printf '1.82.5\n  tailscale commit: fixture\n'
EOF
cp "$TEST_ROOT/bin/tailscale" "$TEST_ROOT/bin/tailscaled"
chmod 755 "$TEST_ROOT/bin/tailscale" "$TEST_ROOT/bin/tailscaled"
check true false '1.82.5'
touch "$TEST_ROOT/lite/.forkop-lite"
cat > "$TEST_ROOT/lite/tailscale" <<'EOF'
#!/bin/sh
printf '1.98.3\n  tailscale commit: fixture-lite\n'
EOF
cp "$TEST_ROOT/lite/tailscale" "$TEST_ROOT/lite/tailscaled"
chmod 755 "$TEST_ROOT/lite/tailscale" "$TEST_ROOT/lite/tailscaled"
check true true '1.98.3'
rm "$TEST_ROOT/bin/tailscale" "$TEST_ROOT/bin/tailscaled"
check false true '1.98.3'
rm "$TEST_ROOT/lite/.forkop-lite"
check false false ''
cat > "$TEST_ROOT/bin/tailscale" <<'EOF'
#!/bin/sh
printf 'misleading output\n'
exit 1
EOF
cp "$TEST_ROOT/bin/tailscale" "$TEST_ROOT/bin/tailscaled"
chmod 755 "$TEST_ROOT/bin/tailscale" "$TEST_ROOT/bin/tailscaled"
check true false ''
printf 'System/Lite installation and version fixtures passed\n'
