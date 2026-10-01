# GUI release selection

The installer continues to use the latest release in its requested channel.
The Updates page obtains available versions with `forkop forkop_releases` and
passes an optional exact version to `component_action_async forkop install VERSION`.
The worker resolves the version from the mirror catalog, checks the complete
package set for the current package manager, and verifies SHA256. Both the
ordinary LuCI update and exact-version selection verify SHA256 and save the Forkop UCI configuration
under `/etc/forkop-backups` after preflight and before changing the runtime or packages.
The standalone installer also saves this backup when updating an existing Forkop
installation, before its flash preflight can switch the sing-box variant. Clean
installs do not create it; legacy migration retains its separate backup handling.
Exactly one managed archive is kept: `/etc/forkop-backups/configuration.tar.gz`.
A complete new archive atomically replaces the previous one. If archive creation
fails, the previous copy is preserved and installation does not proceed. Legacy
`before-VERSION-TIMESTAMP.tar.gz` archives are removed after successful replacement.
The directory and archive are private to root. On a failed LuCI package transaction,
the worker atomically restores the saved configuration before reinstalling the
previous packages, so their postinst does not receive a configuration migrated by
the failed update. An invalid archive leaves the current configuration intact and
the rollback is reported as incomplete, retaining cached recovery packages. The standalone installer also caches the
exact installed Forkop/LuCI package versions from the release catalog, verifies
their SHA256, and captures service state before updating. If any rollback package
is unavailable, it stops before replacing Forkop. Failed updates and caught
interrupts restore configuration before reinstalling the matching package set,
remove a newly added Russian translation if it was previously absent, and restore
the previous enabled/running state. APK restores the package set in one offline
transaction; the complete world file is never overwritten. A failed rollback
retains its temporary recovery directory and reports its path. Bootstrap tools,
explicit sing-box variant changes and unrelated packages are outside this Forkop
package transaction. The flash preflight budgets for the larger of the new and
rollback package archives. A configuration-validation or service-start failure
during an update is an error and triggers rollback.

Rollback reapplies the configuration snapshot after the previous packages' hooks
finish, since those hooks may migrate settings too. Both update entry points use
a private lifecycle adapter for older hooks that stop Forkop twice. It accepts an
already stopped state only when the sing-box process, Forkop nftables table and
Forkop DNS instance are absent. APK operations preserve the adapter environment
with `--preserve-env`; APK rollback installs the matching package set together.
The adapter is included as an executable by both package builders.

Integration verification on the existing OpenWrt 24/opkg and OpenWrt 25/apk VMs
is documented in [update-vm-verification.md](update-vm-verification.md).

The initial catalog includes complete releases from 1.14.3 onward. This is an
availability boundary, not a guarantee of compatibility with every optional
component. Earlier releases need separate migration and lifecycle validation.
The selected version determines the subsequent automatic update channel, as
with existing stable/canary builds. Selecting an older version does not pin it.

Generate the catalog after publishing an immutable release directory:

```sh
python3 scripts/write-release-catalog.py /srv/mirror/public/forkop/updates
```

The generator reads `releases/*/release.json` and
`canary/releases/*/release.json`, verifies all six package hashes against the
archive manifests, sorts versions, and atomically writes `releases.json`.
It does not modify `stable.json`, `canary.json`, OpenWrt feeds, or the installer.
If there are no complete verified releases, it preserves the existing catalog.

On mirror.51343.ru the script is installed as
`/usr/local/lib/forkop/write-release-catalog.py`. The drop-in
`mirror/release-catalog.conf` is applied to `forkop-git-update.service` and
`forkop-canary-mirror.service` to regenerate the catalog after publishing.
