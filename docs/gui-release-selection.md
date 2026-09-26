# GUI release selection

The installer continues to use the latest release in its requested channel.
The Updates page obtains available versions with `forkop forkop_releases` and
passes an optional exact version to `component_action_async forkop install VERSION`.
The worker resolves the version from the mirror catalog, checks the complete
package set for the current package manager, verifies SHA256, and saves the
Forkop UCI configuration under `/etc/forkop-backups` before changing packages.
Exactly one managed archive is kept: `/etc/forkop-backups/configuration.tar.gz`.
A complete new archive atomically replaces the previous one. If archive creation
fails, the previous copy is preserved and installation does not proceed. Legacy
`before-VERSION-TIMESTAMP.tar.gz` archives are removed after successful replacement.
The directory and archive are private to root. A backup does not automatically reverse
configuration migrations or a failed package transaction.

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
