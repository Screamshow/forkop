# LuCI sing-box package changes

The LuCI X and Extended actions are transactions in `components/action.uc`.
Tiny remains supported as a legacy backend action. X is installed from the
Forkop mirror with package metadata, length and SHA-256 validation; its build
version is compared separately from the upstream kernel and package revision.
Before Forkop is stopped or a package is removed, the action downloads the
target package and the exact installed package needed for rollback into `/tmp`.
On APK systems it also stages dependencies needed after removal of the old
variant. Package names, versions and architecture are read from the downloaded
archives; installed size is measured from the package payload, ignoring
inflated producer Installed-Size metadata. If the old version is no longer
available, the change stops without modifying the running service.

Storage checks use two steps shared by X, Extended, Tiny and ordinary
sing-box, for both updates and variant changes:

1. Before stopping the service, stage the exact rollback package and required
   dependencies. Check only additional rollback storage above the existing
   writable files. A writable core needs no extra flash for its own rollback.
   A core supplied by ROM does: the current rollback reinstalls its package
   into writable storage. Check RAM separately using min(free tmpfs,
   MemAvailable): compressed binary backups plus 8 MiB workspace; downloaded
   archives already occupy RAM. Downloads are limited to the available budget.
2. Remove all old sing-box packages (including the target's own old version),
   or move the managed compressed binary to RAM, then sync and read df again.
   Require the measured target payload and staged dependencies plus 256 KiB
   for package metadata. On shortage, restore the staged previous variant.

The payload contains the UPX-packed executable. Its decompressed runtime size
is not flash usage. There are no percentage multipliers or estimated reclaim
credits for target installation. Extended Compressed to X follows exactly
this replacement path: it does not require space for two cores on flash.
Missing optional libraries contribute zero bytes to the backup size.

Extended Compressed stays archived in RAM until the old core is stopped and
rollback is ready. The selected binary and library stream directly to staging
files on flash, then rename into place. No extracted target binary is kept in
tmpfs, and it is not executed alongside the old core. The target archive is
deleted before binary validation and runtime startup. Failed extraction removes
the partial staging file and uses the prepared rollback. Runtime memory for an
UPX executable remains separate from storage; these checks reduce peak memory
but cannot promise startup under arbitrary concurrent memory pressure.

After a component transaction has stopped Forkop, recovery uses `start`
instead of stopping it again through `restart`. An immediate start failure
enters rollback without the normal health-check wait. Compressed rollback
checks restoration of the service script and verifies that a previously
running Forkop has recovered. Repeated Stop on an absent sing-box runtime is
successful; a failed service deletion with a remaining process is an error.

For integration validation on an existing VMware OpenWrt test VM with tiny
running, execute `FORKOP_TEST_VM=1 sh tests/sing_box_component_transition_vm.sh`.
It captures package/service state, checks repeated Stop, performs tiny to
compressed and back, and injects one extended start failure to verify rollback.
The test retains its logs in the printed `/tmp/forkop-transition-test.*` directory.

Package-managed variants do not make a second full binary copy in `/overlay`.
Their rollback uses the locally staged package archives and validates both
the package-manager version and binary afterward. APK installation is
performed with `--no-network`; an unavailable dependency therefore fails
before mutation or, if the package manager rejects the local set, fails
without fetching after the service is stopped. If rollback fails, the action
reports that the previous variant could not be restored; restoring a lone
binary is not counted as a successful package rollback.

This is deliberately conservative: a device may reject an update even if
the package manager could have completed it with less peak space. The check
also cannot guarantee success against concurrent writes to flash or `/tmp`,
post-install scripts with unusually large writes, or sudden power loss.
