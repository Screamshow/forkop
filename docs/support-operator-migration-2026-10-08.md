# Support operator migration — 2026-10-08

The customer router running 2.1.0-canary.2 retained an older UCI configuration
without support_operator_ip. The worker had peer probing code but no selected
peer; recovery.log contained only control-healthy. The operator address remained
100.114.74.44. Manual router-side netcheck/ping restored access; this does not
isolate the underlying network failure or which command established the path.

Added one-time support_operator_ip_v1 migration to the existing package postinst
migration pipeline. Missing values receive 100.114.74.44. Explicit empty values
and custom addresses are preserved. No worker/session lifecycle changes.

Validation on existing VMware OpenWrt 25.12.5 and 24.10.8:

- tests/support_operator_migration.sh passed with candidate modules staged in
  /tmp: missing, empty, custom and idempotent repeat cases.
- Complete tests/support_session_vm.sh passed on both: healthy/transient/control
  recovery, peer success/failure/invalid address, cancellation and expiry during
  hung down/up/status/auth/ping/netcheck, child cleanup, temporary SSH revocation,
  preservation of customer keys and an independent daemon, health parser cases.
- Real tailscaled with synthetic CLI responses; VM24 used a temporary binary
  copied from VM25. No real tailnet credentials or customer sessions used.
- Package inventories and full ubus service lists before/after matched byte for
  byte. Baselines saved under tmp/support-operator-migration. Staging removed.
- git diff --check passed. WSL local execution unavailable (access denied).

No package upgrade, release publication, or reproduction of the customer's real
NAT/DERP failure was performed. Package postinst already invokes this migration
module; validation here exercises its fixture model and support lifecycle on both
OpenWrt versions, not an installed release artifact.
