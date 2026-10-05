#!/bin/sh
set -eu
LIB=${LIB:-/usr/lib/forkop/support}
DAEMON=${DAEMON:-$(command -v tailscaled)}
TEST_ROOT=$(mktemp -d /tmp/forkop-support-api.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT
export LIB TEST_ROOT
mkdir "$TEST_ROOT/session" "$TEST_ROOT/lite" "$TEST_ROOT/bin"
touch "$TEST_ROOT/lite/.forkop-lite"
ln -s "$DAEMON" "$TEST_ROOT/lite/tailscale"
ln -s "$DAEMON" "$TEST_ROOT/lite/tailscaled"
cat > "$TEST_ROOT/bin/ubus" <<'EOF'
#!/bin/sh
if [ -e "$TEST_ROOT/active" ]; then printf '{"forkop-support":{"instances":{"test":{"running":true}}}}'; else printf '{}'; fi
EOF
cat > "$TEST_ROOT/service" <<'EOF'
#!/bin/sh
case "$1" in start) touch "$TEST_ROOT/active";; stop) rm -f "$TEST_ROOT/active";; enable) :;; *) exit 1;; esac
EOF
chmod 755 "$TEST_ROOT/bin/ubus" "$TEST_ROOT/service"
PATH="$TEST_ROOT/bin:$PATH" ucode "${API_TEST:-$(dirname "$0")/support_session_api.uc}"
