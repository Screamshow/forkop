#!/bin/sh
set -eu
lib=${FORKOP_TEST_LIB:-/usr/lib/forkop}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/control" "$work/data/usr/bin" "$work/bin"
printf UPX! >"$work/data/usr/bin/sing-box"
cat >"$work/control/control" <<'EOF'
Package: sing-box-size-test
Version: 1.0.0
Architecture: all
Installed-Size: 999999999
Description: Payload regression
EOF
tar -czf "$work/control.tar.gz" -C "$work/control" ./control
tar -czf "$work/data.tar.gz" -C "$work/data" .
printf '2.0\n' >"$work/debian-binary"
tar -czf "$work/payload.ipk" -C "$work" ./debian-binary ./control.tar.gz ./data.tar.gz
run() { ucode -L "$lib" "$lib/components/action.uc" sing-box-package-info-fixture "$1" sing-box-size-test 1.0.0; }
if ! command -v apk >/dev/null; then
  result=$(run "$work/payload.ipk")
  [ "$(printf '%s' "$result" | jsonfilter -e '@.size')" = 4 ] || { echo 'IPK producer size overrides packed payload' >&2; exit 1; }
  echo 'PASS: IPK measures data archive despite inflated Installed-Size'
fi
# adbdump boundary fixture: package identity is real-format metadata, but
# inflated installed-size represents a producer counting UPX's RAM image.
cat >"$work/bin/apk" <<'EOF'
#!/bin/sh
cat <<'ADB'
info:
  name: sing-box-size-test
  version: 1.0.0
  arch: all
  installed-size: 999999999
paths:
  - name: usr/bin
    files:
      - name: sing-box
        size: 4
ADB
EOF
chmod 755 "$work/bin/apk"
result=$(PATH="$work/bin:$PATH" run "$work/payload.ipk")
[ "$(printf '%s' "$result" | jsonfilter -e '@.size')" = 4 ] || { echo 'APK producer size overrides packed payload' >&2; exit 1; }
echo 'PASS: APK measures file sizes rather than inflated UPX RAM size'
