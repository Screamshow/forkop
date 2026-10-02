# Binary rule-set validation without JSON expansion

The customer reproduction identified `sing-box rule-set decompile` launched
by `singbox/ruleset_cache.uc refresh-if-due-and-reload` as the OOM victim.
The working proxy survived. The auxiliary process expanded HaGeZi Pro into
source JSON while the working proxy was resident.

Binary validation now uses `sing-box rule-set match --format binary` with
the reserved probe name `forkop-validation.invalid`. A non-match succeeds.
The command parses the binary and constructs every rule; malformed,
truncated, or unsupported inputs fail. It does not export source JSON.
This applies to the rule-set cache and the source-download validation in
the list cache. Decompilation needed to extract subnet lists is unchanged.

The upstream implementation uses `srs.Read(..., false)` for matching and
`srs.Read(..., true)` for decompilation:

- https://github.com/SagerNet/sing-box/blob/v1.12.22/cmd/sing-box/cmd_rule_set_match.go
- https://github.com/SagerNet/sing-box/blob/v1.12.22/cmd/sing-box/cmd_rule_set_decompile.go

## OpenWrt 24 VM verification, 2026-10-03

Existing VMware VM, 256 MiB configured RAM, 207096 KiB reported MemTotal,
no swap, `sing-box-tiny 1.12.22-r1`. Package and service state were recorded
before the tests. No package upgrades or persistent router configuration
changes were needed; the modified source was exercised from an isolated
directory under `/tmp`.

HaGeZi Pro fixture: 1784157 bytes from the public Forkop mirror.

| Operation | Sampled peak RSS | Result |
| --- | ---: | --- |
| Old decompile | 139740 KiB | Exit 137, kernel OOM kill |
| Binary match | 32380 KiB | Exit 0 |

RSS was sampled from `/proc`; these are observed peaks, not hard limits.
A temporary proxy runtime loaded the same large binary (28836 KiB RSS).
With that runtime and the existing VM proxy running, the following passed
without additional OOM events or loss of either runtime:

- `tests/ruleset_binary_validation_vm.sh`: real large and nested rule sets,
  malformed/truncated/unsupported rejection, marker invalidation after file
  replacement, full cache publication, unchanged refresh, preservation of
  the previous valid cache after a corrupt download.
- `tests/ruleset_cache.sh`: cache materialization and refresh regressions.
- `tests/list_srs_validation_cache.sh`: validation memoization and checksum
  rejection, with a self-contained cache fixture.

The temporary runtime was stopped after testing. The existing managed
proxy retained its original PID. The VM is x86/64; this does not establish
an exact RSS bound for the customer's ARM router or arbitrary rule sets.

## Extended verification, 2026-10-03

Both current x86/64 Extended artifacts from the Forkop mirror report
`1.14.1-extended-2.7.2` and support `rule-set match --format binary`.
The ordinary IPK and compressed archive hashes were checked against the
published manifest. Their extracted binaries were run in isolation without
replacing the installed cores or upgrading packages.

Both passed the real binary validation and full cache publication tests
above. Ordinary Extended ran on the existing OpenWrt 25 VM (1 GiB RAM);
compressed Extended ran on the existing OpenWrt 24 VM (256 MiB RAM), with
its binary stored on disk. Storing the compressed binary in tmpfs caused
an initial OOM, so that result is not representative of a disk installation.

Observed match peak RSS for the same large fixture:

- Ordinary Extended: 76248 KiB.
- Compressed Extended: 113688 KiB.

Crucially, compressed Extended is not OOM-safe on the 256 MiB test VM when
the matching process runs beside another compressed Extended runtime.
The temporary resident core used 102272 KiB RSS. Launching validation
triggered one additional OOM which killed that resident core; validation
then finished with status 0. The installed tiny core retained PID 3527.
The temporary runtime and disk-staged compressed binary were cleaned up.

Therefore CLI compatibility is confirmed for these artifacts, but canary.6
does not guarantee safe concurrent validation with compressed Extended on
low-RAM devices. A successful validation exit alone is insufficient: the
resident service and kernel OOM counter must also be checked.

## Sequential checks, 2026-10-03

`service/sing-box-check.sh` now serializes memory-heavy commands with the
managed service. It uses the existing reload lock, including a lock held by
an ancestor during an update, and a checker lock which prevents unrelated
Forkop starts while validation runs. Downloads and publication remain in
their original callers. Successful unchanged-file validation markers still
avoid spawning a checker.

Before pausing a running core, the wrapper restores the native dnsmasq
transaction and waits for its listener. Conflicting or unavailable DNS
rollback is rejected before stopping the core. After the checker exits it
restarts the previous runtime, waits for readiness, then restores managed
DNS. A failed check still resumes the old runtime. Failed restoration makes
the whole operation fail and leaves native DNS available. TERM/INT/HUP
cleanup terminates and waits for the checker before restarting the service.
An explicit Forkop stop during a check is respected.

This path covers SRS validation, subnet extraction by decompile, full config
validation and diagnostic proxy probes. It adds no nftables rules. Existing
lifecycle firewall behavior is unchanged. Watchdog ignores reload locks
whose recorded owner has exited instead of remaining suspended forever.

Verified on the existing OpenWrt 24 VM with 256 MiB RAM and no swap using
tiny 1.12.22 and compressed Extended 1.14.1-extended-2.7.2. The compressed
test temporarily replaced the managed binary and loaded the large SRS into
its resident configuration; the original binary/config were restored after
testing. Ordinary Extended checks also passed on the OpenWrt 25 VM.

- `tests/sing_box_check.sh`: ordering, validation/stop/start failures,
  foreign runtime, unsafe DNS, inherited lock, stopped service and TERM cleanup.
- `tests/sing_box_check_vm.sh`: native DNS during checking, old runtime
  restoration after invalid SRS, native DNS after injected restart failure,
  nested real reload lock, refusal of unrelated starts, interruption recovery,
  unchanged nftables policy and no new kernel OOM events.
- Real binary/cache publication tests and validation memoization passed.
- DNS transaction tests include dependent scoped/ported DNS addresses.

The broader `tests/sing_box_runtime.sh` error-propagation fixture was adapted
to isolate service state. The suite later stops at an existing missing
Discord subnet ruleset fixture; the unchanged baseline also exits 2 there.
Targeted transition and parser tests above pass independently. These x86 VM
results do not establish a universal memory bound for arbitrary rule sets:
one checker or one runtime can still exceed a device's available RAM.
