# LuCI sing-box package changes

The LuCI tiny and Extended actions are transactions in `components/action.uc`.
Before Forkop is stopped or a package is removed, the action downloads the
target package and the exact installed package needed for rollback into `/tmp`.
On APK systems it also stages dependencies needed after removal of the old
variant. Package names, versions and architecture are read from the downloaded
archives; IPK installed size is measured from the data archive as well as
checked against its declared size. If the old version is no longer
available, the change stops without modifying the running service.

The flash preflight measures the unpacked target and rollback package sizes
separately, including the dependencies staged for each side. It estimates
the extra space needed for installation and rollback, adds 25% plus 8 MiB
to each, and requires the larger result. The previous installed package is
already accounted for by the measured free space, so it is not added again.
Only a variant switch that removes the old package before installing the
new one receives reclaim credit: 75% of the existing `/usr/bin/sing-box`
file, when that file is verifiably in the writable layer. On
SquashFS/overlay systems it must exist under `/overlay/upper`; on a plain
writable root the actual file is counted. A firmware file or same-variant
reinstall receives no credit. `/tmp` is checked separately after staging,
with 8 MiB reserved beyond any binary backup needed for the legacy
compressed variant.

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
