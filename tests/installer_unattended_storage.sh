#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sed '/^main "\$@"$/d' "$ROOT/install.sh" >"$work/library.sh"
. "$work/library.sh"
fail() { printf '%s\n' "$*" >&2; exit 1; }
msg() { :; }
warn() { :; }
TMP_DIR="$work"
legacy_binary_managed_sing_box_present() { return 1; }
sing_box_is_present() { return 1; }
select_sing_box_installation
[ "$SING_BOX_INSTALL_VARIANT" = x ] || fail 'fresh install did not select X'
sing_box_is_present() { return 0; }
select_sing_box_installation
[ -z "$SING_BOX_INSTALL_VARIANT" ] || fail 'installed variant changed'
FORKOP_LEGACY_DETECTED=1
prepare_legacy_config_backup() { touch "$work/backup"; }
confirm_legacy_migration </dev/null
[ -f "$work/backup" ] || fail 'automatic legacy migration omitted backup'

mkdir -p "$work/data" "$work/package"
dd if=/dev/zero of="$work/data/core" bs=1024 count=10 2>/dev/null
tar -czf "$work/package/data.tar.gz" -C "$work/data" .
tar -czf "$work/target.ipk" -C "$work/package" .
dd if=/dev/zero of="$work/data/core" bs=1024 count=20 2>/dev/null
tar -czf "$work/package/data.tar.gz" -C "$work/data" .
tar -czf "$work/rollback.ipk" -C "$work/package" .
PKG_IS_APK=0
FORKOP_BACKEND_FILE="$work/target.ipk"
FORKOP_APP_FILE=""
FORKOP_I18N_FILE=""
UPDATE_ROLLBACK_MANIFEST="$work/rollback.tsv"
printf 'forkop\t1\t%s\n' "$work/rollback.ipk" >"$UPDATE_ROLLBACK_MANIFEST"
SING_BOX_X_SPACE_KB=0
[ "$(forkop_install_required_space_kb)" = 276 ] || fail 'rollback counted twice or payload underestimated'
available_flash_space_kb() { echo "$flash"; }
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\ntest 99999 0 %s 0%% /tmp\n' "$memory"; }
flash=276; memory=8192
ensure_flash_space </dev/null
flash=275
if (ensure_flash_space </dev/null) >/dev/null 2>&1; then fail 'flash shortage accepted'; fi
flash=276; memory=8191
if (ensure_flash_space </dev/null) >/dev/null 2>&1; then fail 'RAM shortage accepted'; fi
echo 'Unattended installer, payload, rollback and storage boundaries: OK'
