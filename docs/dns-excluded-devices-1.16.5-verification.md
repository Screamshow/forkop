# DNS exclusions with Extended 1.14 — 1.16.5-canary.1

## Trigger and fix

A section with response-matched rule sets, excluded source IPs, and no positive source-IP filter generated an `evaluate` DNS rule with a logical AND containing an empty object and an inverted source-IP matcher. Extended 1.14 rejects the empty child with `missing conditions`.

`exclude_sources_from_matchers()` now returns the inverted exclusion directly when the original matchers are empty. Nonempty matchers retain the existing logical AND. The exclusion is preserved; no customer settings or rule sets are changed.

## Verification, 2026-10-06

- `tests/sing_box_dns114.sh`: PASS for 1.12.25, 1.13.18, 1.14.0 and 1.14.1. The fixture includes mixed/domain lists and an excluded device without a positive device filter. Assertions verify the exclusion and reject empty logical children. The synthetic Discord subnet artifact is prepared explicitly.
- `tests/sing_box_runtime.sh`: PASS.
- On existing OpenWrt 25 VM, ordinary and compressed Extended 1.14.1-extended-2.7.2 both reject the old logical DNS rule and accept the corrected generated configuration. Source rule sets were replaced with synthetic local domain/IP fixtures for this isolated check; no customer proxy credentials were used. The installed Tiny service was not replaced by either diagnostic binary.
- All three candidate APK packages installed on the existing OpenWrt 25 VM; all three candidate IPK packages installed on the existing OpenWrt 24 VM. Installed generator hashes match the source. Forkop remains running, installed sing-box configuration checks pass, and FakeIP DNS returns addresses in 198.18.0.0/15 on both VMs.
- Package/service state and configuration snapshots were captured under `/tmp/forkop-165-check` before package installation. VM packages remain at the candidate version for follow-up checks.

The Extended checks validate configuration acceptance, not a complete live traffic transition through Extended. Tailscale changes are outside this release.
