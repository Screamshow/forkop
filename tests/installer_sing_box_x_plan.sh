#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
TMP_DIR="$work"
sed -n '/^install_json_helper_path() {/,/^install_json_ucode() {/ { /^install_json_ucode() {/d; p; }' "$ROOT/install.sh" > "$work/functions.sh"
. "$work/functions.sh"
helper="$(install_json_helper_path)"
cat >"$work/catalog.json" <<'EOF'
{"schema":1,"name":"sing-box-x","version":"1.0.0","assets":[{"package":"sing-box-x","format":"ipk","architecture":"x86_64","name":"sing-box-x_1.0.0-2_x86_64.ipk","url":"https://mirror.51343.ru/forkop/sing-box-x/releases/1.0.0/sing-box-x_1.0.0-2_x86_64.ipk","sha256":"77a35e3f96b74439052b71ec14b9591204138f763e770acb51c3b2e6e6f27f15","size":9685283,"installed_size":9860489,"plain_binary_bytes":31133858}]}
EOF
ucode "$helper" sing-box-x-plan x86_64 ipk https://mirror.51343.ru <"$work/catalog.json" >"$work/plan"
[ "$(cut -f4 "$work/plan")" = 9860489 ] || { echo 'UPX memory size used as flash size' >&2; exit 1; }
if ucode "$helper" sing-box-x-plan mipsel_24kc ipk https://mirror.51343.ru <"$work/catalog.json"; then
  echo 'Unsupported architecture accepted' >&2; exit 1
fi
if ucode "$helper" sing-box-x-plan x86_64 apk https://mirror.51343.ru <"$work/catalog.json"; then
  echo 'Wrong package format accepted' >&2; exit 1
fi
sed 's@https://mirror.51343.ru/forkop/sing-box-x/releases/@https://example.com/forkop/sing-box-x/releases/@' "$work/catalog.json" >"$work/wrong-source.json"
if ucode "$helper" sing-box-x-plan x86_64 ipk https://mirror.51343.ru <"$work/wrong-source.json"; then
  echo 'Off-mirror package URL accepted' >&2; exit 1
fi
echo 'Installer X catalog and flash plan: OK'
sed -n '/^select_sing_box_for_release() {/,/^}/p' "$ROOT/install.sh" >"$work/release-choice.sh"
. "$work/release-choice.sh"
msg() { :; }
fail() { echo "$*" >&2; exit 1; }
SING_BOX_INSTALL_VARIANT=x
FORKOP_RELEASE_TAG=1.16.4
select_sing_box_for_release
[ "$SING_BOX_INSTALL_VARIANT" = tiny ] || exit 1
SING_BOX_INSTALL_VARIANT=x
FORKOP_RELEASE_TAG=2.0.0-canary.1
select_sing_box_for_release
[ "$SING_BOX_INSTALL_VARIANT" = x ] || exit 1
SING_BOX_INSTALL_VARIANT=extended-compressed
FORKOP_RELEASE_TAG=2.0.0-canary.1
select_sing_box_for_release
[ "$SING_BOX_INSTALL_VARIANT" = extended-compressed ] || exit 1
echo 'Old stable and 2.0 installer component choices: OK'
