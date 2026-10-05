#!/bin/sh
# Run only against an isolated test copy of Forkop, on an existing OpenWrt VM.
# Capture package/service state before staging this test.
set -eu
umask 000
ROOT=${FORKOP_PRIVATE_TEST_ROOT:?Set an isolated test directory}
WORK="$ROOT/work"
LIB="$ROOT/lib"
SESSION=""
cleanup() {
    if [ -n "$SESSION" ]; then
        ubus call session destroy "{\"ubus_rpc_session\":\"$SESSION\"}" >/dev/null
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ucode -L "$LIB" "$ROOT/private_files.uc" "$WORK" "$LIB"

# These fixtures are synthetic. The parent is traversable, so this checks
# the file permissions and the private cache directory rather than /tmp.
start-stop-daemon -S -x /bin/sh -p "$WORK/nobody-check.pid" -c nobody -- -c \
    'test "$(id -u)" = 65534 && test ! -r "$1" && test ! -r "$2"' check \
    "$WORK/private.json" "$WORK/run/section-cache/probe.json"
echo 'PASS: unprivileged account cannot read private config or section cache'

# LuCI fs.read uses this same rpcd file API. Grant only the two fixture paths,
# then check that the root daemon can read 0600 files inside the 0700 cache.
SESSION=$(ubus -S call session create '{"timeout":60}' | jsonfilter -e @.ubus_rpc_session)
test -n "$SESSION"
ubus call session grant "{\"ubus_rpc_session\":\"$SESSION\",\"scope\":\"file\",\"objects\":[[\"$WORK/private.json\",\"read\"],[\"$WORK/run/section-cache/probe.json\",\"read\"]]}" >/dev/null
ubus call session grant "{\"ubus_rpc_session\":\"$SESSION\",\"scope\":\"ubus\",\"objects\":[[\"file\",\"read\"]]}" >/dev/null
for file in "$WORK/private.json" "$WORK/run/section-cache/probe.json"; do
    umask 077
    ubus -S call file read "{\"ubus_rpc_session\":\"$SESSION\",\"path\":\"$file\"}" > "$WORK/rpc-read.json"
    FORKOP_RPC_READ_RESULT="$WORK/rpc-read.json" FORKOP_RPC_READ_TARGET="$file" \
        ucode -e 'let fs = require("fs"); let result = json(fs.readfile(getenv("FORKOP_RPC_READ_RESULT"))); if (result.data != fs.readfile(getenv("FORKOP_RPC_READ_TARGET"))) die("RPC reader changed file content\n");'
done
echo 'PASS: authorized rpcd readers can read private config and section cache'
