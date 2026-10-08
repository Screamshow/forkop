# Forkop 2.1.0 / X 1.0.2 release validation — 2026-10-08

Release notes combine canary.1, canary.2, the support operator migration and
XHTTP capability integration: docs/releases/2.1.0.md.

Isolated source: main 8abe52ae plus support migration and reviewed XHTTP changes
in runtime/generator/UI and frontend store/types/UI state. Generated LuCI assets
rebuilt from this snapshot. Packages use final 2.1.0, not canary.3. Exact six
artifacts and SHA-256/length manifest: tmp/release210-validation/packages and
manifest.json. Repeated build has identical contents for all six APK/IPK.

Validation:

- 560 frontend tests in 53 files passed; TypeScript and tsup/asset compaction
  passed using Windows bundled Node. WSL frontend startup initially failed due
  to missing npm and incompatible Windows esbuild dependencies, then the native
  runtime completed the same snapshot successfully.
- sing_box_runtime, xhttp_capabilities and support_operator_migration passed.
- X latest.json rechecked: stable 1.0.2, upstream 1.14.2, APK 1.0.2-r1/IPK
  1.0.2-1, x86_64. New and rollback 1.0.1 packages downloaded solely from mirror;
  URL, package identity, architecture, revision, length and SHA-256 validated.
  Extracted UPX payload lengths checked. New binary is 9,938,872 bytes; old
  9,863,528. Dependencies ca-bundle/kmod-tun already installed. VM24 free root
  space 15.4 MiB, VM25 36.1 MiB; package/rollback workspace on /tmp. Planning
  uses packed payload and old writable binary credit, not expanded RAM size.
- Both existing VMs (25.12.5 and 24.10.8) exercised real package hooks: install
  published canary.2, stop Forkop, update X to mirror 1.0.2, update Forkop to final
  2.1.0 with missing operator setting, explicitly restart, reinstall, restart.
- After each runtime check: one owned core, valid generated configuration, DNS
  answer, authenticated Clash /version, router HTTPS 204. Capability API reports
  sing_box_xhttp=1 and runtime accepts Features transport.xhttp. Core SHA-256
  unchanged by Forkop reinstall/restart; setting migrated to 100.114.74.44.
- Exact original Forkop canary.1/X 1.0.1 packages and UCI restored afterward;
  core hash, package inventory and config files match baseline. Services restart
  normally, so PID equality is not expected. Private curl files removed.

First harness attempts not counted: assumed SOCKS inbound absent on both VMs;
then omitted explicit start after deliberately stopping Forkop to replace the
core. Runner corrected both assumptions; final successful runs are the evidence.
HTTPS on these VMs is router connectivity, not a SOCKS subscription test.

Prior final X 1.0.2 subscription validation was 61/61 on VM25 and MT6000 (58
TCP REALITY, one gRPC, two XHTTP); it is documented separately in
artifacts/sing-box-x/VALIDATION-TLS-FINGERPRINTS-2026-10-08.md. The current stage
does not repeat that subscription matrix on VM24 or claim full Xray compatibility,
long-duration load, LTE bypass, reboot or clean install of the final artifacts.

No release tag, publication, mirror update or customer installation performed.
