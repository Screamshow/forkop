# Startup stability threshold and current backend reboot checks

## Scope

Tests on 2026-10-08 used the existing OpenWrt 25 (192.168.1.1) and OpenWrt 24 (192.168.241.2) VMware VMs. The current repository backend was overlaid from a checksummed archive, including the SRS digest reuse, native process/version checks, operation-local version reuse and verified DNS reload helper. No package database or sing-box executable changes were made. This is source integration coverage, not an APK/IPK installation test.

Package/service state, original backend, UCI and sing-box configuration were saved in `/root/forkop-boot-stability-20261008` before mutation. The customer router was neither rebooted nor changed in this experiment. Repository and customer-router startup defaults remain 8 seconds. No release or publication was performed.

## What the threshold means

`service/lifecycle.uc` defaults `FORKOP_SING_BOX_START_STABLE_MIN_AGE` to 8 and verification timeout to 10 seconds. The check requires the managed core to have reached that age as well as current process ownership, listening ports, API and routing readiness. This is a minimum process age, not eight additional seconds after every readiness check, and not a protocol requirement.

It protects against declaring success and leaving DNS forwarded to a core that fails shortly after initially becoming ready. The number 8 is an empirical observation window; these tests do not establish that it is the minimum necessary value. No finite age proves that a process will never fail later. The existing watchdog's startup grace and failure interval make it unsuitable as an immediate replacement for this startup check.

## Functional reboot verification

Both VMs were rebooted once with the entire current backend and its default 8-second threshold. Both reached `running=1`, `enabled=1`, `dns_configured=1`, with one managed sing-box, a watchdog readiness marker, localhost DNS and external `example.com` resolution. Original core binary hashes were unchanged. Boot IDs changed on both machines.

The OpenWrt 24 staging script had returned nonzero during its pre-reboot readiness check; it did not produce a diagnostic explanation in its captured log. Its subsequent reboot and explicit post-boot checks passed. The failed staging check is not counted as a successful warm-start trial.

Post-boot checks occurred at uptime 26.35 seconds on OpenWrt 25 and 41.39 seconds on OpenWrt 24. These are observation times after SSH reconnection, not measured boot completion durations. There is no paired total-boot speed claim, and reduced thresholds were tested with warm restarts, not reboot.

## Healthy warm restart measurements

Two consecutive trials at each threshold, with the same candidate backend and VM configuration:

| Minimum core age | OpenWrt 25, seconds | OpenWrt 24, seconds |
| --- | --- | --- |
| 8 | 10.41 / 10.40 | 10.43 / 10.44 |
| 5 | 7.37 / 7.40 | 7.46 / 7.45 |
| 2 | 4.38 / 4.32 | 4.41 / 4.47 |

These are full warm restart wall times on these VMs. Each successful trial also checked stable runtime and localhost DNS. They do not predict customer-router reboot performance.

## Injected early failure

A worker identified the newly started procd-managed sing-box PID, verified ownership and start ticks, and sent SIGKILL when that process reached approximately 3 seconds of age. It did not kill a stale or unrelated process. Tests used thresholds 8, 5 and 2 on both VMs.

* At 8 and 5 seconds, `forkop restart` returned failure and its recovery removed DNS forwarding to the failed core. Every subsequent external DNS probe succeeded on both VMs.
* At 2 seconds, `forkop restart` had already returned success before the injected failure. DNS remained forwarded to the absent core. External DNS queries timed out until procd restarted the process; then queries succeeded again. On OpenWrt 25 three successive probes timed out; this confirms an observed interruption, not a precisely measured outage duration.

The first fault-test run accidentally used an unavailable external `timeout` utility: its DNS results (`127`) are invalid. Its PID, forwarding and restart results remain usable. The confirmation run used `dig +time=1 +tries=1` directly and checked both exit status and DNS response status, rejecting SERVFAIL. Conclusions about DNS above use only this repaired confirmation run.

## Decision and limits

Removing the age check or reducing it to 2 seconds would lose protection demonstrated by the injected failure. Five seconds is a plausible candidate and saved about 3 seconds per healthy warm restart; it detected the tested crash at age 3. This does not cover failures between ages 5 and 8, delayed initialization on slower hardware, repeated respawn, or sustained memory pressure. The production threshold was therefore left unchanged pending broader failure-window testing or a redesigned transactional health check.

Successful current-backend reboots on both x86 VMs add evidence for a controlled customer pilot. They do not establish universal safety across customer configurations and architectures. Tested failure handling and compatibility limits of DNS reload remain described in `config-dns-optimization-2026-10-08.md`.

Scripts and result logs are stored under `tmp/optimization-review-20261008/boot-stability`. Both VMs are restored to their original backend/configuration after tests and checked for one managed core, working DNS, unchanged package lists and unchanged core hashes; temporary production substitutions are removed.

On OpenWrt 24 the original backend's restoration restart also returned nonzero while DHCP renewed its WAN lease. A subsequent explicit readiness check passed without further code changes: one core, running/enabled/DNS-configured status, external DNS, original core hash and package list. This transient readiness failure is recorded rather than presenting the restoration script itself as passing on that VM.
