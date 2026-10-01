#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export FORKOP_LIB="${FORKOP_LIB:-$ROOT_DIR/forkop/files/usr/lib}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/actions"
export SB_VARIANT_STATE_FILE="$WORK_DIR/variant"
export SB_VERSION_STATE_FILE="$WORK_DIR/version"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/state"
export FORKOP_UI_COMPONENT_ACTION_DIR="$WORK_DIR/actions"
export FORKOP_DIAGNOSTICS_SING_BOX_BIN_PATH="$WORK_DIR/bin/sing-box"
export TEST_PROBE_FILE="$WORK_DIR/probes"
export PATH="$WORK_DIR/bin:$PATH"

cat > "$WORK_DIR/bin/apk" <<'APK'
#!/bin/sh
[ "$TEST_MANAGER" = apk ] || exit 1
case "$1" in
info) [ "$2" = -e ] && [ -n "$TEST_PACKAGE" ] && [ "$3" = "$TEST_PACKAGE" ] ;;
list) [ -z "$TEST_PACKAGE" ] || echo "$TEST_PACKAGE 1.0-r1" ;;
*) exit 1 ;;
esac
APK
cat > "$WORK_DIR/bin/opkg" <<'OPKG'
#!/bin/sh
[ "$TEST_MANAGER" = opkg ] && [ "$1" = list-installed ] || exit 1
[ -z "$TEST_PACKAGE" ] || echo "$TEST_PACKAGE - 1.0-r1"
OPKG
cat > "$WORK_DIR/bin/sing-box" <<'BINARY'
#!/bin/sh
echo probe >> "$TEST_PROBE_FILE"
echo "sing-box version $TEST_VERSION"
BINARY
chmod +x "$WORK_DIR/bin/"*
echo extended-compressed > "$SB_VARIANT_STATE_FILE"
echo 1.14.0-extended-2.7.1 > "$SB_VERSION_STATE_FILE"

check() {
    export TEST_PACKAGE="$1" TEST_VERSION="$2"
    export FORKOP_SYSTEM_INFO_CACHE_FILE="$WORK_DIR/info-$3.json"
    rm -f "$TEST_PROBE_FILE"
    ucode -L "$FORKOP_LIB" "$FORKOP_LIB/diagnostics/runtime.uc" get-system-info > "$WORK_DIR/result.json"
    ucode -e '
        let fs = require("fs");
        let info = json(fs.readfile(ARGV[0]));
        assert(info.sing_box_version == ARGV[1], "current version");
        assert(info.sing_box_extended == int(ARGV[2]), "Extended flag");
        assert(info.sing_box_tiny == int(ARGV[3]), "Tiny flag");
        assert(info.sing_box_compressed == int(ARGV[4]), "compressed flag");
        assert(info.sing_box_tailscale == int(ARGV[2]), "Tailscale flag");
    ' "$WORK_DIR/result.json" "$4" "$5" "$6" "$7"
    if [ "$8" = probe ]; then
        [ -s "$TEST_PROBE_FILE" ]
    else
        [ ! -e "$TEST_PROBE_FILE" ]
    fi
}

# A leftover compressed marker must not override any manually installed package.
for manager in apk opkg; do
export TEST_MANAGER="$manager"
check sing-box-extended 1.14.1-extended-2.7.2 "$manager-extended" 1.14.1-extended-2.7.2 1 0 0 probe
[ "$(ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/runtime.uc" version)" = "$TEST_VERSION" ]
[ "$(ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/runtime.uc" variant)" = extended ]
check sing-box-tiny 1.13.21 "$manager-tiny" 1.13.21 0 1 0 probe
[ "$(ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/runtime.uc" variant)" = tiny ]
check sing-box 1.13.0 "$manager-stable" 1.13.0 0 0 0 probe
[ "$(ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/runtime.uc" variant)" = stable ]
done
export TEST_MANAGER=apk

# Genuine unpackaged Compressed must never start a version probe.
check '' unused compressed 1.14.0-extended-2.7.1 1 0 1 no-probe
[ "$(ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/runtime.uc" version)" = 1.14.0-extended-2.7.1 ]
[ "$(ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/runtime.uc" variant)" = extended-compressed ]
[ ! -e "$TEST_PROBE_FILE" ]

# A component transaction must not start even a packaged binary.
echo '{"running":true,"component":"sing_box"}' > "$WORK_DIR/actions/test.json"
check sing-box-extended 1.14.1-extended-2.7.2 transaction 1.14.0-extended-2.7.1 1 0 0 no-probe
echo 'sing-box manual version checks passed'
