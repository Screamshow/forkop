#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
awk '/cat > "\$helper_path"/ { capture=1; next } capture && /^EOF$/ { exit } capture { print }' "$ROOT_DIR/install.sh" > "$WORK_DIR/helper.uc"
test -s "$WORK_DIR/helper.uc"
# Inject only the native dependency; exercise the real helper command.
python3 - "$WORK_DIR/helper.uc" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1])
s=p.read_text().replace('require("uci").cursor()', '''({
 load: function(name) { if (getenv("DHCP_CASE") == "throw") die("load failed"); return getenv("DHCP_CASE") != "missing"; },
 get: function(package, section) { return getenv("DHCP_CASE") == "present" ? { ".type": "forkop" } : null; }
})''')
p.write_text(s)
PY
DHCP_CASE=absent ucode "$WORK_DIR/helper.uc" installer-dhcp-forkop-absent
for state in present missing throw; do
  if DHCP_CASE="$state" ucode "$WORK_DIR/helper.uc" installer-dhcp-forkop-absent 2>/dev/null; then
    echo "FAIL: $state must not permit skipping stop" >&2; exit 1
  fi
done
sed 's/let cursor = uci_cursor();/let cursor = null;/' "$WORK_DIR/helper.uc" > "$WORK_DIR/unavailable.uc"
if ucode "$WORK_DIR/unavailable.uc" installer-dhcp-forkop-absent; then
  echo 'FAIL: unavailable UCI must not permit skipping stop' >&2; exit 1
fi
# Extract the real old-package adapter; replace only the service endpoint
# so tests cannot start/stop any host service.
awk '/cat > "\$TMP_DIR\/package-init"/ { capture=1; next } capture && /^EOF$/ { exit } capture { print }' "$ROOT_DIR/install.sh" > "$WORK_DIR/adapter"
test -s "$WORK_DIR/adapter"
sed -i 's|exec /etc/init.d/forkop|exec "$FORKOP_TEST_INIT"|' "$WORK_DIR/adapter"
cat > "$WORK_DIR/init" <<'SH'
#!/bin/sh
echo "$1" >> "$FORKOP_TEST_LOG"
SH
cat > "$WORK_DIR/nft" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$WORK_DIR/init" "$WORK_DIR/nft"
export PATH="$WORK_DIR:$PATH" FORKOP_TEST_INIT="$WORK_DIR/init" FORKOP_TEST_LOG="$WORK_DIR/stop.log"
FORKOP_INSTALLER_JSON_HELPER="$WORK_DIR/missing" sh "$WORK_DIR/adapter" stop
grep -Fxq stop "$WORK_DIR/stop.log"
for state in present missing; do
  : > "$WORK_DIR/stop.log"
  DHCP_CASE="$state" FORKOP_INSTALLER_JSON_HELPER="$WORK_DIR/helper.uc" sh "$WORK_DIR/adapter" stop
  grep -Fxq stop "$WORK_DIR/stop.log"
done
: > "$WORK_DIR/stop.log"
DHCP_CASE=absent FORKOP_INSTALLER_JSON_HELPER="$WORK_DIR/helper.uc" sh "$WORK_DIR/adapter" stop
test ! -s "$WORK_DIR/stop.log"
echo 'installer DHCP detection and conservative fallback passed'
