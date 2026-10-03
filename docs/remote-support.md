# Remote support in LuCI

The optional Remote support card in Components provisions an absent Tailscale
using a standalone Lite binary from the Forkop mirror and starts a separate,
temporary userspace daemon. An existing
Tailscale installation is reused without upgrading it or changing its service,
configuration, socket, state, DNS, routes or login. Lite lives in
`/usr/lib/forkop-support` and never registers or starts the standard service.
Lite removal only deletes its own marked directory. No automatic uninstall occurs.

## Session authorization

The operator supplies a one-use ephemeral Tailscale auth key. The client enters
it in the password field and explicitly allows a 30-minute session. LuCI sends
it in an authenticated, CSRF-protected POST. It is stored in a mode-0600 file in
a mode-0700 runtime directory and deleted after authentication or cancellation.
It is never stored in UCI, status output or process arguments. The daemon's
identity is in memory (`--state=mem:`), so reboot requires a fresh authorization.
The key's own expiry does not expire an already authorized support session.

The operator must configure a restrictive tailnet policy **before issuing keys**:
allow only the support operator to reach support-tagged devices and only on the
required ports (normally TCP 22); disallow clients reaching one another or the
operator's machine. The default allow-all policy is unsuitable for deployment
to clients. The component does not have tailnet administration credentials and
cannot create or verify that policy.

Userspace networking forwards permitted inbound traffic to local router ports.
The UI explicitly grants access to local router services, not read-only
diagnostics. The client need not provide an SSH password: the Tailscale key is
not an SSH key. After Tailscale authentication, the worker adds the bundled
support operator public key to `/etc/dropbear/authorized_keys` with a forced
session gate and forwarding disabled. The operator private key remains outside
the repository on the operator computer. Other authorized keys are preserved,
including edits made during a session. Symlink authorization files are rejected
rather than replaced. The default OpenWrt Dropbear root/public-key settings are
required; custom servers or configurations disabling root/key authentication
need separate integration. No dedicated SSH server, LAN routes or exit node are
created by the product. Full root
SSH access can change the whole router, including session controls.

## Lifecycle

LuCI opens a connection-details dialog when an active support session first
reports its Tailscale IPv4 address. The dialog contains the IP and remaining
minutes, can copy only the IP without auth/SSH keys, and offers immediate
disconnect. It can be reopened from the card. Polling updates the status and
disables copying/disconnect when the session stops or status is unavailable.
The UI flow was checked against a clearly labelled mocked API preview; the
browser reported successful copying, but the automation's separate virtual
clipboard could not verify a subsequent paste.

`forkop-support` is a separate procd service with no session respawn. Its boot
hook only removes leftover support SSH authorization; it never starts a session.
The first session enables that cleanup hook.
Its worker uses monotonic uptime for a 30-minute deadline, independent of LuCI
and wall-clock corrections. Cancellation or expiry terminates its own daemon,
closing its transport, and removes credentials, temporary SSH authorization and
the startup lock. A forced-command gate rejects new SSH shells outside the active
session and monotonic deadline, including leftover authorization after reboot.
Package
replacement and full Forkop uninstall stop this service. Main Tailscale is not
logged out or stopped by session shutdown. Stopping the transport does not
guarantee cancellation of commands deliberately detached by a root operator.

Provisioning is asynchronous. It never upgrades an existing client. A partially
installed client needs manual repair. It does not provide a cancel button during
package installation, because interrupting a package transaction can leave it
inconsistent.

The Remove Tailscale button removes the OpenWrt-managed package after explicit
confirmation. It is available only with support disconnected and the main
Tailscale service both stopped and disabled. The worker rechecks these conditions
before invoking `apk del tailscale` or `opkg remove tailscale`. It does not
explicitly erase the main client's configuration or identity files. Package
manager conffile/dependency handling still applies; other applications lose the
Tailscale binaries. Installation and removal cannot be cancelled in LuCI.

## Validation

On the existing OpenWrt 25 VM, two Tailscale 1.98.3 instances joined the test
tailnet, established direct connections, and used approximately 81 MiB combined
RSS. SSH through the userspace support instance worked; stopping it preserved
the main instance's transport. Kernel-mode SSH through the main instance was
not verified (it failed both during and after parallel operation). Configuration
hashes and routes were restored after stopping both instances.

`tests/support_session_vm.sh` verifies the candidate worker's timer, credential
permissions and cancellation with a mocked auth CLI, without consuming auth keys.
The status API and invalid-request checks also passed on OpenWrt 24 with Tailscale
absent. HTTP integration checks passed on OpenWrt 25: GET returned 405, missing
CSRF returned 403, authorized status returned 200, and read-only mutation returned
403. The LuCI card was visually checked and its consent/key gating was exercised.
Actual OpenWrt 24 connections, different tailnets, existing exit-node/subnet-router configurations,
Filogic memory measurements and interrupted package installs require further
integration coverage before production rollout. No automatic compatibility
guarantee is made for arbitrary third-party Tailscale builds.

The candidate authenticated successfully with a fresh one-use key on VM25.
Its upstream network returned FakeIP addresses even with Forkop stopped; the
control client then failed TLS while fetching the control key. A temporary
`/etc/hosts` override using a real address obtained through DNS-over-HTTPS allowed
authentication. The override was removed after the test. This is a test workaround,
not a product feature: the upstream FakeIP resolver must exclude the Tailscale
control domains for normal operation. The auth worker also enforces a separate
60-second timeout rather than relying solely on the CLI timeout.

SSH through the candidate's Tailscale address succeeded while Forkop remained
running, and Tailscale ping reported a direct connection. Removal HTTP tests
rejected missing confirmation, read-only users, and an enabled main client. A
real remove/reinstall cycle preserved every other installed package and restored
the exact package baseline with standard Tailscale autostart disabled. Mock APK
and OPKG workers also covered success and failure cleanup. The stalled-auth test
verified deadline expiry and credential/socket cleanup.

The new operator SSH key was tested on VM25 using a temporary LAN-only Dropbear
listener with password authentication disabled and a mocked Tailscale auth CLI.
Public-key login succeeded while the candidate worker was connected; after
cancellation it was rejected and the authorization file was removed. This proves
the SSH lifecycle, not a new tailnet registration. The key-management fixture
passed on both VM25 and VM24, including permissions, idempotence, preserving
client edits and rejecting symlinks. Boot cleanup and rejection of leftover
authorization outside a session also passed. A fresh auth key is required to
repeat the complete Tailscale flow with the new SSH authorization.

During regression testing, the old full-uninstall fixture selected the host APK
manager on the OpenWrt 25 VM and removed the installed Forkop packages and their
now-unused dependencies. The original 1.14.9 packages and sing-box-tiny 1.13.21-r1
were restored; installed package versions match the baseline and both services
run again. DNS configuration was regenerated during recovery, so a byte-for-byte
restoration of the original DHCP file is not claimed. The fixture manager
selection now only accepts executables inside its explicit fixture root; the
corrected regression passed on OpenWrt 25 with real package state unchanged.

Lite installation uses pinned per-architecture file sizes and SHA-256 from
`support/lite.json`. Flash preflight requires the exact binary size plus 1 MiB;
RAM preflight requires download space plus 8 MiB available memory. Failed downloads
and interrupted copies are cleaned up. The file is verified before becoming
executable. Existing destination directories are never overwritten.

The pinned upstream v1.98.3 source produces a stripped multicall binary with
CLI, userspace netstack, local socket identity, routing/port detection and port
mapping. Build tags remove optional features; no UPX is used. ARM64 is 16,711,842
bytes (15.94 MiB); AMD64 is 17,997,986 bytes (17.16 MiB). Rebuild with
`scripts/build-tailscale-lite.sh` from the pinned source revision.

VM tests downloaded Lite from the public mirror, rejected insufficient storage
and tampered content, started its real daemon with synthetic authorization,
expired the session and removed Lite while another standard daemon stayed alive.
The installed system package list, binaries and configuration hashes were unchanged.
A real tailnet registration with Lite and real Filogic RAM measurements remain
unverified and require a fresh auth key / device testing.

The r2 Lite build restores tailnetlock, whose omission caused the CLI to fail after successful registration with 'tailnet lock is not supported by this binary'. Real authorization, connected worker state, direct ping and operator-key SSH through the support Tailscale IP passed on VM25. The VM required a temporary controlplane hosts override due to upstream FakeIP; the original hosts file was restored and the session/credentials revoked afterward.
