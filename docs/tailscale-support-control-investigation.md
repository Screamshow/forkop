# Temporary support control connection investigation

Observed on OpenWrt 24.10.5, arm64, Tailscale 1.98.3-forkop-lite,
2026-10-05. Customer support was closed after diagnostics; further work
must use the existing OpenWrt VMs and synthetic fixtures.

## Evidence

- Authentication and the first network map succeeded.
- Both streaming and non-streaming `/machine/map` requests subsequently
  timed out at the client's two-minute watchdog interval.
- DNS, HTTPS over IPv4/IPv6, UDP and DERP connectivity succeeded.
- A router-originated Tailscale ping to the operator established peer
  reachability. SSH then worked while the control connection was unhealthy.
  This does not prove idle peer connections need periodic pings.
- `status --json` eventually reported a coordination-server health warning.
- Fresh `debug ts2021` handshakes and `whoami` requests succeeded over the
  default port-80 path and with `TS_FORCE_NOISE_443=true`.
- `down` followed by `up` with the existing preferences recreated the Noise
  client, obtained a new network map, and completed a lightweight update in
  51 ms. SSH and online status recovered. No recurrence was observed during
  the following approximately three minutes, which is insufficient to prove
  a permanent fix.

## Established limitations in Forkop

`support/worker.sh` marks a session connected after successful `up`, then
only checks the daemon PID. `support/session.uc` derives active state from
procd and exposes the cached phase. Neither checks coordination health.
Thus the support card can offer an IP while the control connection is lost.

The diagnostic `debug break-tcp-conns` endpoint returned HTTP 404 in this
Lite build. Do not rely on it for recovery.

The CLI is `/usr/lib/forkop-support/tailscale`, outside the interactive PATH.
An unqualified `tailscale: not found` does not imply the client is missing.

## Recovery verified in this session

Within the same live daemon, use its support socket and preserve preferences:

```sh
cli=/usr/lib/forkop-support/tailscale
socket=/var/run/forkop/support/socket
"$cli" --socket="$socket" down
"$cli" --socket="$socket" up --timeout=20s \
  --accept-dns=false --accept-routes=false \
  --hostname="forkop-support-$(cat /proc/sys/kernel/hostname)" \
  --netfilter-mode=off
```

Do not restart the memory-state daemon or supply a reused auth key. Do not
extend the original session deadline or re-authorize SSH after expiry.

## Local investigation and candidate recovery requirements

The initial trigger remains unknown. Inspect the reused Noise/HTTP2 transport
after request cancellation and compare Lite with the unmodified upstream
build. A cached Noise client by itself is not proof of a transport bug.

Before introducing an automatic workaround, test on the existing VMs:

1. A synthetic status fixture with a live PID, Running backend and a
   coordination health warning must not appear fully connected.
2. Temporary network failures must not trigger an immediate reconnect.
3. Persistent control failure may trigger bounded down/up with all existing
   preferences, without daemon restart or another authentication key.
4. Recovery must retain the original deadline and stop on cancellation;
   no retry, background task or authorized key may survive session expiry.
5. Healthy idle sessions must remain reachable without generated peer traffic.
6. Compare control recovery with peer-ping behavior. Peer pings must not be
   treated as proof that coordination health has recovered.

No automatic ping or recovery loop has been deployed as part of this
investigation. No upstream Tailscale patch has yet been validated.

## Candidate implementation and checks (2026-10-05)

The repository now contains a bounded recovery workaround; it has not been
released or deployed to a customer router. The evidence above remains historical
and does not establish the original cause or a permanent Tailscale fix.

- The API creates a UUID and monotonic 30-minute deadline before starting the
  worker. The worker retains both throughout recovery. LuCI claims the announcement through an authenticated POST.
  An atomic per-session directory in RAM prevents repeats across reloads and tabs. Close only hides
  the dialog; Connection details opens it manually; Disconnect now stops the
  session, including during degraded/recovering phases. A new UUID permits a
  new automatic announcement even if the IP is unchanged. Detached cards and
  stale polling responses cannot announce an old session after an operation.
- The worker checks its own daemon PID every second and bounded `status --json`
  about every ten seconds. `health.uc` requires BackendState=Running and rejects
  missing/malformed status and coordination/network-map/control-server warnings.
  Self.Online=false alone and unrelated DNS warnings do not trigger recovery.
  This uses the English Health string interface in 1.98.3-forkop-lite, rather
  than an unavailable debug endpoint. Health warnings can themselves appear
  late: upstream's out-of-sync warning has an eight-minute visibility delay.
- The first bad check changes the phase to degraded and blocks new SSH shells
  through the existing connected-phase gate. Sixty seconds of continuously bad
  checks permits down/up. At most three attempts are allowed per session, with
  at least 120 seconds between starts; a healthy check resets the bad-duration
  timer, but does not reset the attempt count or rate limit. Attempts run
  serially in the worker; there is no detached recovery loop.
- Recovery uses the exact Lite CLI path, the same socket and daemon, with
  `--timeout=20s --accept-dns=false --accept-routes=false`, the original hostname
  and `--netfilter-mode=off`. It supplies no auth key and never calls SSH add.
  CLI completion is logged separately from a verified healthy status. After
  the limit, monitoring continues in degraded state until health returns,
  cancellation or the original deadline; there is no automatic fourth attempt.
- Status/down commands have a five-second worker limit; recovery up has a
  22-second outer limit. Every wait checks the session deadline. Cancellation
  marks the session stopped before removing the temporary SSH line, freezes
  and kills tracked CLI descendants, and closes the separate daemon. Recovery
  events use fixed messages in `/var/run/forkop/support/recovery.log`, without
  credentials or raw CLI errors. All monitoring state/logs remain in RAM.

Confirmed checks on existing VMware OpenWrt 24.10.8 and 25.12.5:

- `tests/support_session_vm.sh` used the real 1.98.3-forkop-lite r2 daemon and
  synthetic CLI fixtures, accelerated timing, separate authorized_keys and
  candidate files entirely under /tmp. No real auth key or registration was
  used. Healthy status, transient coordination failure, recovered status and
  persistent failure met their expected retry counts (0, 0, 1, 3).
- Tests checked API-created identity/deadline preservation, all recovery up
  flags, absence of a recovery auth key, rate limiting, one daemon start, and
  survival of a separate independent daemon. The worker PATH deliberately
  excluded the main Tailscale binaries.
- Cancellation and expiry during stalled down, up, status and initial auth
  checked temporary SSH removal, preservation of pre-existing key content,
  socket/lock/credential removal and absence of remaining test processes.
- `tests/support_session_api_vm.sh` / `support_session_api.uc` exercised API
  start/stop, UUID renewal, connected/degraded/recovering projections and
  remaining time using a mocked service and ubus, without editing system UCI.
- Frontend tests exercise Close, manual reopening, polling, tab/card replacement,
  module reload with server acknowledgement, a new session with the same IP,
  recovery labels and Disconnect now. These are DOM-fixture tests, not a real
  browser visual acceptance test. All 545 frontend tests passed; TypeScript,
  changed-file ESLint and the LuCI bundle build passed.

Limitations: deterministic fixtures prove the worker's policy and lifecycle,
not recovery of the original hung Noise transport. A live tailnet endurance test,
upstream-versus-Lite comparison and diagnosis of the original hang remain open.
No periodic peer pings, force-443 workaround or upstream transport patch were
added. Reload deduplication is now independent of browser storage.

After the isolated checks, both VM package lists and all original procd service
running states/PIDs matched their pre-test snapshots exactly. Neither VM had a
system /etc/dropbear/authorized_keys file before or after the tests. Temporary
candidate binaries and test directories were removed; local snapshots and test
output are retained under tmp/support-recovery-checks (not release artifacts).

## Additional real VM and browser checks

The user authorized direct candidate installation on the disposable VMs without
backups and waived a full 30-minute wait. Package/service state was recorded.
The candidate worker, API, controller and compiled LuCI bundle were installed on
both VMs; their production package version numbers were not changed.

On VM25, a real session using the user-supplied reusable test auth key registered
with Tailscale 1.98.3-forkop-lite. Operator-public-key SSH through the support
Tailscale IP succeeded. The key was streamed to the VM request over SSH stdin,
not stored in a repository file or supplied in process argv. Its worker credential
file was removed after initial authentication. No customer router was contacted.

Initially Self.Online was false and Health empty while SSH worked. This confirms
that Self.Online alone is insufficient; it does not prove control health or
long-term stability. A deliberate `down` on the support socket subsequently
produced degraded status. The production 60-second grace elapsed without an
earlier attempt; at uptime 98623 the worker ran its first recovery, commands
completed at 98625, and healthy status returned at 98636. SSH worked again.
The support daemon PID remained 30478, UUID remained unchanged, deadline stayed
99870 and the inspected DNS/routes/hostname/netfilter preferences were preserved.
This was a deliberate backend-down test, not reproduction of the original hang.

Actual LuCI checks covered automatic announcement, Close leaving the active
card, manual reopening, switching tabs, polling and full page reload. Manual
candidate copies do not change LuCI's package-based resource cache version;
the first reload checks were therefore using an old cached bundle. The resource
version was refreshed on the test VMs and the tests repeated on fresh resources.
The implementation now uses server-side atomic acknowledgement, including tests
with unavailable browser storage and transient acknowledgement-request errors.
After acknowledgement, no automatic dialog returned for that same session.
A new real session produced a new UUID and automatically opened the dialog.

The first real session was ended with LuCI Disconnect now. Socket, daemon and
temporary authorized key disappeared and subsequent SSH timed out. For a second
real session only the VM's request deadline was temporarily reduced to 45 seconds;
the repository keeps 1800 seconds and the VM source was restored immediately.
That session expired at its original short deadline, removed its auth credential,
socket and temporary SSH key and left no support daemon. Its new IP did not
establish operator SSH within that short window, so SSH success for the second
45-second session is not claimed. No recurring pings were introduced.

VM24 lacked Lite and had insufficient flash space for its binary. The incomplete
copy was removed; a temporary RAM installation with a bind mount enabled API
checks, then the mount and binary were removed. API start/stop, phase projection,
wrong/duplicate/unhealthy/stopped announcement rejection passed on both VMs.
No package-manager install, firewall change or primary Tailscale restart was used.
Russian PO was compiled to LMO for the test VMs using the upstream LuCI converter.
All 545 frontend tests, TypeScript, changed-file ESLint and final bundle build
passed again after the server acknowledgement change.

Final HTTP checks passed on both VMs: GET rejected (405), missing CSRF rejected
(403), authenticated status accepted (200), wrong-session announcement denied,
and read-only stop/announce/remove rejected (403). The English VM24 LuCI page
loaded the candidate and correctly offered Lite installation after temporary
Lite was removed. Both package lists remained unchanged; all pre-existing
service PIDs/running states were unchanged. A stopped procd support instance
left after expiry was removed with the support service stop command. Both VMs
ended with no support socket or temporary authorized key. Candidate code and
translation updates remain on the disposable VMs; no release was published.

## Ordinary OpenWrt package verification (2026-10-05)

VM25 was restored to the ordinary APK `tailscale` 1.98.3-r1 with no Lite
installation. Its primary daemon remained running while a support session
authenticated using the supplied reusable test auth key and started a separate
userspace daemon. The session reached `connected`; the credential file was
removed after authentication. SSH over the support Tailscale IP succeeded.

Because this VM permits passwordless SSH, key authentication was also checked
with a temporary Dropbear listener on port 2222, password login disabled, and
the operator client restricted to its support identity and public-key auth.
The server recorded successful public-key authentication and the command
executed. A client offering no key was rejected with `Permission denied
(publickey)`. This listener used the real temporary authorized_keys entry and
forced-command gate, without changing the normal SSH service.

Cancellation removed the temporary SSH authorization, auth file, socket and
support daemon. A subsequent connection to the support IP timed out. The test
listener and its RAM files were removed. The primary daemon PID (12544) and
SHA-256 of its state file stayed unchanged. This establishes working ordinary
package authentication and access for this short test, not long-term stability
or the cause of the earlier control-connection stalls. No recurring pings were
used. VM fixtures additionally exposed and fixed NUL-separated procfs argument
handling in primary-daemon detection; both VM24 and VM25 passed those cases.
