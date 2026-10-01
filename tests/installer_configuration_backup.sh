#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d /tmp/forkop-installer-backup.XXXXXX)"
trap 'rm -rf "$work"' EXIT
fail() { printf '%s\n' "$1" >&2; exit 1; }
msg() { :; }
# Exercise the standalone installer's actual backup implementation without
# running installation or writing to /etc.
sed -n '/^prepare_current_config_backup() {/,/^}/p' "$ROOT/install.sh" > "$work/functions.sh"
. "$work/functions.sh"
export FORKOP_INSTALLER_CONFIG_DIR="$work/config"
export FORKOP_INSTALLER_BACKUP_DIR="$work/backups"
mkdir -p "$work/config" "$work/backups"
INSTALL_MODE=clean
prepare_current_config_backup
[ ! -e "$work/backups/configuration.tar.gz" ] || fail 'clean install created a backup'
INSTALL_MODE=legacy
prepare_current_config_backup
[ ! -e "$work/backups/configuration.tar.gz" ] || fail 'legacy path replaced current backup'
INSTALL_MODE=update
printf 'original\n' > "$work/config/forkop"
printf old > "$work/backups/before-1.14.7-canary.3-123.tar.gz"
printf keep > "$work/backups/user-copy.tar.gz"
prepare_current_config_backup
[ "$(tar -xOzf "$work/backups/configuration.tar.gz" forkop)" = original ] || fail 'incorrect backup'
[ ! -e "$work/backups/before-1.14.7-canary.3-123.tar.gz" ] || fail 'obsolete backup survived'
[ -e "$work/backups/user-copy.tar.gz" ] || fail 'user backup deleted'
[ "$(ls -l "$work/backups/configuration.tar.gz" | awk '{print $1}')" = -rw------- ] || fail 'insecure backup'
printf 'updated\n' > "$work/config/forkop"
prepare_current_config_backup
[ "$(tar -xOzf "$work/backups/configuration.tar.gz" forkop)" = updated ] || fail 'backup not replaced'
before="$(sha256sum "$work/backups/configuration.tar.gz")"
rm "$work/config/forkop"
if (prepare_current_config_backup); then fail 'accepted missing configuration'; fi
[ "$(sha256sum "$work/backups/configuration.tar.gz")" = "$before" ] || fail 'failed backup destroyed previous copy'
[ "$(find "$work/backups" -name '.configuration.*' | wc -l)" = 0 ] || fail 'temporary archive leaked'
# Both LuCI update variants must reach the common backup after preflight.
ucode -e 'let fs = require("fs"); let s = fs.readfile(ARGV[0]);
let a = index(s, "function install_forkop(");
let start = index(s, "    capture_forkop_running_state();", a);
let backup = index(s, "    forkop_configuration_backup = save_forkop_configuration_backup", a);
let mutation = index(s, "    if (!stop_old_sing_box_before_forkop_upgrade())", a);
if (!(start > a && backup > start && mutation > backup)) exit(1);' \
  "$ROOT/forkop/files/usr/lib/components/action.uc" || fail 'common LuCI backup missing before mutation'
printf 'Installer configuration backup checks passed\n'
