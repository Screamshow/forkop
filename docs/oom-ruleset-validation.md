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
