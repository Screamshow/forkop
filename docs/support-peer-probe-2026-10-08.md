# Reverse Tailscale path probe

The previous support session was visible in the tailnet but operator-side
Tailscale ping and TCP/22 timed out before SSH authentication. Recreating the
session did not help. The user then ran router-side netcheck and ping to
100.114.74.44; ping returned over a direct UDP endpoint in 33 ms. This supports
an outbound NAT/path establishment hypothesis but does not isolate which
command helped, establish the root cause, or independently prove SSH recovery.

## Candidate behavior

`forkop.settings.support_operator_ip` explicitly selects one operator IPv4
address in 100.64.0.0/10. The default configuration contains the user-selected
100.114.74.44. Empty, malformed or non-Tailscale addresses disable probes.
The worker reads the setting once after temporary SSH authorization. Existing
installations retaining their UCI configuration need to set it explicitly:

```sh
uci set forkop.settings.support_operator_ip='100.114.74.44'
uci commit forkop
```

This takes effect in the next explicitly authorized support session. To disable:

```sh
uci set forkop.settings.support_operator_ip=''
uci commit forkop
```

After a healthy coordination check, the worker immediately sends one reverse
ping, then waits at least 60 seconds after completion before the next probe.
Ping uses --c=1 --timeout=5s --until-direct=false with a 7-second external
deadline. A working DERP path counts as success. On failure, netcheck is allowed
at most once every 300 seconds, bounded externally to 10 seconds, followed by
one further ping. No peers are enumerated. Only this worker's daemon/socket is
used; DNS, routes, firewall and package state are not changed.

Failed peer probes do not change the connected phase, invoke down/up, or claim
SSH failure. Ping success is not an SSH readiness test. Existing coordination
recovery stays separate. Probe commands share the existing tracked-process
cleanup and monotonic session deadline; they never refresh authorization or
extend the session. Fixed events are kept in the RAM-only recovery.log without
raw CLI output or credentials.

## Validation

- WSL Ubuntu: sh syntax checks of worker and extended VM test passed.
- tests/support_peer_probe.sh passed: strict address validation, successful
  ping, failed ping/netcheck retry, netcheck backoff, unchanged control phase,
  external timeout, cancellation and expiry of a hung command with child cleanup.
- shellcheck -S warning of worker and portable test passed.
- tests/support_session_vm.sh extended with successful/failed/invalid peer and
  hung ping/netcheck cancellation/expiry cases. These OpenWrt integration cases
  have NOT run: both existing VMware VMs were listed running, but SSH to
  192.168.1.1 and 192.168.241.2 timed out, including an unsandboxed retry for VM25.
  No VM package, service or configuration mutations were performed.

Candidate is local source only: no package built, router installation, release
or mirror publication. Real Lite/OpenWrt runtime and real SSH recovery remain
to be verified during an active authorized session.

## Integration follow-up

After VM connectivity returned, the complete extended support_session_vm.sh
suite passed on OpenWrt 25.12.5 (192.168.1.1) and 24.10.8 (192.168.241.2).
Candidate worker/helpers were staged under /tmp/forkop-peer-validation.
VM25 used its installed real tailscaled; VM24 used a temporary copy of that
binary under /tmp without installing any package. CLI responses were synthetic;
no real auth keys or tailnet authorizations were used.

Both passed healthy/transient/recover/persistent coordination cases, successful,
failed and invalid peer cases, and cancellation plus expiry during hung down,
up, status, initial authorization, ping and netcheck commands. Assertions covered
unchanged session identity/deadline, retry limits, customer-key preservation,
SSH revocation, child-process cleanup and survival of an independent daemon.
Health-parser fixtures passed on both versions. Package inventories and full
procd service lists before/after matched byte for byte on both VMs.

These results validate the worker lifecycle on OpenWrt but do not demonstrate
the original real-network failure being fixed. Actual Lite CLI and real SSH
recovery during a customer-authorized session remain distinct validation steps.

## Live Lite session

With a freshly supplied one-use auth key, the candidate ran on VM25 using the
existing local 1.98.3-r2 amd64 Lite artifact (executable reports
1.98.3-forkop-lite), staged under /tmp. No packages were installed. The key was
transferred in a private file, removed locally after transfer and removed by
the worker after authorization. The active test session used a 120-second TTL
and the production support socket/status path so the existing SSH gate could
validate the session. Original /etc/dropbear/authorized_keys was absent; the
worker created and later removed only its temporary operator authorization.

The assigned address was 100.121.157.70. Automatic reverse probes succeeded at
uptimes 41583 and 41645 (62 seconds apart). SSH to that address using the separate
support operator identity succeeded and returned the OpenWrt release. Operator
Tailscale ping also succeeded over a direct endpoint, at 1 ms. Coordination
recovery count remained zero; no netcheck fallback was necessary.

At unchanged deadline 41697 the worker exited successfully, phase became stopped,
the socket disappeared and temporary operator authorization was removed. A new
SSH attempt over the Tailscale address timed out. Package inventory and full
procd service list matched the captured baseline byte for byte. Temporary Lite
files and support runtime artifacts were removed after saving non-secret status
and event evidence under tmp/support-peer-validation/live.

This confirms the real Lite command path, periodic reverse probes, SSH access
and expiry cleanup. The original connectivity failure did not reproduce on this
local VM network, so this is not proof that the same NAT/DERP failure is cured.
