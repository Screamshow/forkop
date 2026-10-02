# Installer publication

`install.sh` is the shared installer. Stable is its default channel; canary
uses `--channel canary`. `canary-install.sh` downloads that same installer,
selects canary and forwards the remaining arguments. Do not maintain a
second copy of the installation implementation.

On Openwrt-Mirror, keep the Git versions of both scripts in
`/usr/local/share/forkop/` and publish them to
`/srv/mirror/public/forkop/`. The existing `sync-forkop-mirror` service uses
`/usr/local/share/forkop/install.sh` as its installer override; updating only
the public copy can therefore revert a fix during the next synchronization.
The synchronization does not replace `canary-install.sh`.

After publishing, compare SHA-256 for the Git files, the override files and
both public HTTP endpoints. Run both scripts with `--help`, then rerun the
mirror synchronization and verify the hashes remain unchanged. Preserve
previous files before replacement. Installer-only changes do not require a
new package release; changes to packaged files do.

## Verification on 2026-10-02

- Both public scripts match the committed installer implementation and
  wrapper. Their `--help` invocations succeed.
- `forkop-mirror.service` completed successfully and preserved both scripts.
- Canary wrapper channel/argument forwarding and download failure handling,
  installer configuration backups and rollback checks passed.
- Published 1.15.1-canary.2 packages passed upgrade and repeat-install checks
  on existing OpenWrt 24/opkg and OpenWrt 25/APK VMware VMs. User settings
  were preserved; only the runtime `shutdown_correctly` marker is excluded
  from the in-test comparison. Original configuration is restored exactly.
- Public `canary.json`, `releases.json`, release manifest and all six package
  hashes agree with the downloaded GitHub release assets.
