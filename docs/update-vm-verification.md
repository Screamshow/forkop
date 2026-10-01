# Update and rollback VM verification

Verified on 2026-10-01 using the existing VMware OpenWrt VMs.

| VM | Manager | Original Forkop/LuCI/ru release | Test target |
| --- | --- | --- | --- |
| OpenWrt 25, 192.168.1.1 | apk | 1.14.8 | 1.14.9-canary.2 (APK version 1.14.9_rc2) |
| OpenWrt 24, 192.168.241.2 | opkg | 1.14.8-canary.7 | 1.14.9-canary.2 |

Package inventories, configuration archives, APK world and enabled/running
service state were captured before changing either VM. Each case restored the
original Forkop packages, configuration, backups and enabled/running state.

## Results

Each cell covers both an enabled/running service and a disabled/stopped service:
24 main cases passed, plus two delayed-start rollback cases.

| Scenario | OpenWrt 25/apk | OpenWrt 24/opkg |
| --- | --- | --- |
| Standalone installer: successful update | PASS in both states | PASS in both states |
| Standalone installer: failure and automatic rollback | PASS in both states | PASS in both states |
| Ordinary LuCI update worker: successful update | PASS in both states | PASS in both states |
| Ordinary LuCI update worker: failure and automatic rollback | PASS in both states | PASS in both states |
| Exact-version LuCI worker: successful update | PASS in both states | PASS in both states |
| Exact-version LuCI worker: failure and automatic rollback | PASS in both states | PASS in both states |
| LuCI rollback with an explicit two-second start delay | PASS; delayed start exercised | PASS; delayed start exercised |

Fault injection executes the real package manager first, after installing the
target backend and its hooks. It then commits a test configuration change and
returns exit code 42. Verification requires the original package versions,
configuration without that change, expected service state, and an explicit
successful-rollback message. An `incomplete rollback` response fails the test.

Successful updates must contain the configuration from immediately before the
transaction in the single managed backup. Configuration comparisons normalize
CRLF line endings. Disabled/stopped cases take their transaction snapshot after
the intentional stop, since stopping can commit configuration changes.

Final checks confirmed the complete installed-package inventories match the
original snapshots on both VMs. APK world is unchanged. Both VMs have their
original Forkop versions, configuration and enabled/running service restored.
The VM-local HTTP test servers have exited.

## Fixes confirmed by integration tests

- Older package hooks stop Forkop twice. A private lifecycle adapter accepts an
  already stopped state only after checking the process, nftables table and DNS
  instance. APK needs `--preserve-env` to retain this adapter in its hook environment.
- APK rollback restores the matching Forkop/LuCI/ru package set in one offline
  transaction.
- Configuration is restored before old package hooks and reapplied afterward,
  because those hooks can migrate options again.
- LuCI uses an internal stop and waits for the transition before restoring the
  snapshot. It preserves enabled/stopped state and waits explicitly for a new
  start, avoiding a race before the start worker appears.
- Both package builders include the executable lifecycle adapter; the standalone
  builder restores its executable permission after normalizing file modes.

The installer backup and rollback regression scripts and release-plan/catalog
tests also passed on both VMs, including corrupt archives, missing rollback
releases and full release asset resolution. Installer and harness shell syntax
checks and `git diff --check` passed.

## Test method and scope

Harness: `tests/forkop_update_vm.sh`. It stages the working-copy installer and
LuCI worker under `/tmp/forkop-update-review`; it invokes the same worker used by
LuCI directly, without automating the browser UI. Package installation,
downgrade and lifecycle hooks are real, using published archives verified by
SHA256. Package hooks use the installed library, not the test helper library.

The isolated mirror listens on `127.0.0.1:18089` and serves the verified original
and target archives. Both channel fixtures select the same target to exercise
the transaction paths. Previously refreshed package indexes are reused; the
wrapper skips only index refresh and the requested fault is injected only into
an actual install operation. Live mirror availability, clean installation,
legacy-product migration and power-loss recovery are outside this VM matrix.

Run only on the designated disposable test VMs, after capturing their state.
Do not overwrite an existing initial snapshot with `prepare`.

```sh
sh /tmp/forkop-update-review/tests/forkop_update_vm.sh ORIGINAL_VERSION prepare
sh /tmp/forkop-update-review/tests/forkop_update_vm.sh ORIGINAL_VERSION luci-failure
FORKOP_VM_TEST_STOPPED=1 sh /tmp/forkop-update-review/tests/forkop_update_vm.sh ORIGINAL_VERSION version-success
FORKOP_VM_DELAY_START=1 sh /tmp/forkop-update-review/tests/forkop_update_vm.sh ORIGINAL_VERSION luci-failure
```

These changes are local to the working copy; no release was published.
