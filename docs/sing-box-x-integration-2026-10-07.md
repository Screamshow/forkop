# sing-box X integration — 2026-10-07

Candidate: Forkop X 2.0.0-canary.1. Existing main branch and existing VMware OpenWrt 25.12.5/APK and 24.10.8/IPK VMs were used. Package/service state and configuration were saved before mutations. No replacement VM was created; the customer router was not changed.

Published as a GitHub prerelease and synchronized with `forkop-canary-mirror.service`.
Public `canary.json`, `releases.json`, release manifest and all six package
SHA-256 hashes were verified. The shared public installer was updated atomically
after a backup and verified by hash; it uses X for 2.0 and retains Tiny for older
backends that do not implement `install_x`. Stable remains 1.16.4.

## Behavior

- LuCI offers Sing-Box X, Extended and Extended compressed. Installed Tiny remains recognized and supported by its existing backend action.
- Clean installs select X. Updates retain the existing variant; switching to X is an explicit component action.
- X catalog and packages come from `https://mirror.51343.ru/forkop/sing-box-x/`. Architecture, package identity, revision, mirror URL, length and SHA-256 are validated before removing the old package. Unsupported architectures fail explicitly.
- Update checks display/compare X build version 1.0.0 separately from upstream 1.14.2 and package revision r2/2. Revision-only changes still produce an update status.
- Exact previous package archives and missing dependencies are staged before a switch. Installation errors restore the previous package, markers and runtime. Failure responses now wait for service recovery.
- Flash planning uses extracted package payload (the UPX-packed executable stays packed on flash), missing dependency payloads, filesystem reserves, writable binary credit and rollback capacity. Temporary archive files are already reflected in free tmpfs; binary backups and additional workspace have their own reserve. Clean installer plans include X before installing Forkop packages.

## Verification

553 frontend tests passed; TypeScript and LuCI production build passed. Runtime, installer configuration backup, installer update rollback and build-version regressions passed with the existing WSL ucode runtime. `installer_sing_box_x_plan.sh` checks packed flash size, unsupported architecture, wrong format and off-mirror URLs.

| Check | OpenWrt 25 / APK | OpenWrt 24 / IPK |
| --- | --- | --- |
| Tiny → X; repeated X install; update check/no-op | passed | passed |
| X ↔ Tiny | passed | passed |
| X ↔ ordinary sing-box | passed | passed after temporarily moving old test artifacts to tmpfs |
| X ↔ Extended package | passed | safely rejected before mutation: 104669 KiB required, 48264 KiB available |
| X ↔ Extended compressed | passed | downloaded binary validation rejected: kernel OOM, exit 137 on the 200 MiB VM; X recovered |
| Failed X package installation → exact Tiny rollback | passed | passed |
| Unreachable mirror leaves X working | passed | passed |
| UCI preservation, generated config check, DNS | passed for successful transitions | passed for successful transitions and rejected Extended actions |
| Clash connections API on X | passed | passed |
| Installing final Forkop 2.0.0-canary.1 packages | passed | passed |

Both VMs were left running X 1.0.0 and the candidate Forkop release with their previous UCI configuration preserved. Old validation directories moved to tmpfs were returned to their original paths. The IPK VM's limited disk/RAM prevented a successful full Extended round trip; this is not claimed as tested. Real subscription gRPC and latest post-quantum Xray REALITY compatibility remain unverified as described in the handoff.

VM evidence: `/tmp/x-matrix.log`, `/tmp/x-fault-matrix.log`, `/tmp/forkop-x-matrix.*`, `/tmp/2-canary-install.log`, `/tmp/x-integration-before/`. Local build output: `dist/2.0.0-canary.1/`.
