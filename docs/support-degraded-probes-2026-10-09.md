# Support peer probes during degraded coordination

The support worker previously skipped reverse peer probes when coordination
health was degraded. An authorized router can still have a usable peer path
in that state, so the worker now probes in connected and degraded phases.

Existing limits remain: one ping per 60 seconds, netcheck only after failed
ping and at most once per 300 seconds, followed by one retry. CLI commands
retain their external timeouts and the session's monotonic deadline. The
configured operator address is validated and no other peers are enumerated.

Probe success does not clear the degraded phase, authorize SSH, extend the
session or initiate down/up. Coordination recovery and the connected-only
SSH gate remain unchanged. Tests cover successful and failed peer probes
while coordination is continuously unhealthy, with no control recovery,
and check that the phase remains degraded while the session is active.

Validation uses the existing VMware OpenWrt 24/25 VMs, a real isolated
tailscaled and synthetic CLI responses without real auth credentials. The
full lifecycle suite also checks retries, deadlines, customer-key preservation,
cancellation/expiry of hung CLI children and survival of an independent daemon.
VM24 uses a temporary daemon executable in /tmp; no package is installed.
Before testing, package inventories and procd service state are captured.
This validates lifecycle behavior, not a cure for the customer's specific
NAT/control-server failure. Real-network effectiveness still needs observation.

Both full VM suites passed, including degraded-success/degraded-failure,
all cancellation/expiry cases and health-parser fixtures. Package inventories
and full procd service lists matched before/after byte-for-byte on both VMs;
Forkop remained running with DNS configured. Portable peer-probe tests and
shell syntax checks also passed. Logs: tmp/support-degraded-validation/.
