# Sing-box X package search

Stable X packages are published in signed, architecture-specific APK indexes:

- `https://mirror.51343.ru/forkop/mirror/current/aarch64_cortex-a53/packages.adb`
- `https://mirror.51343.ru/forkop/mirror/current/x86_64/packages.adb`

Each index includes the three current stable Forkop packages and one matching
X package. The legacy architecture-independent index retains only Forkop.
Canary Forkop releases remain in the separate component update catalog.

Existing APK routers must replace the legacy URL in
`/etc/apk/repositories.d/forkop.list` with the matching architecture URL and run
`apk update` (LuCI: Update lists). Keep the existing trusted mirror public key.
The package name for LuCI search and installation is `sing-box-x`.
The migration script in the next Forkop build selects the architecture URL.
This change does not add an opkg feed or install/upgrade router packages.

Mirror deployment: install `mirror/publish-sing-box-x-feed.py` in
`/usr/local/lib/forkop/`, and install and enable `sing-box-x-feed.service` and
`sing-box-x-feed.timer`. The five-minute timer reads the latest stable X catalog
and `MIRROR_LATEST`, validates archive hashes and signatures, builds signed
indexes in a new snapshot, and atomically switches `mirror/current`.
Immutable Forkop and X release directories remain intact. Restore the previous
`mirror/current` symlink target to roll back publication.

Verified 2026-10-07: X 1.0.1-r1 with Forkop stable 1.16.4. The public indexes
selected the correct package for both architectures; package downloads,
SHA-256 and signatures passed in isolated temporary APK roots on the mirror.
Use `mirror/verify-sing-box-x-feed.py` to repeat this check.
