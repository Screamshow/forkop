# Forkop test environments

Use the existing VMware OpenWrt virtual machines for integration diagnostics;
do not create a replacement VM unless the user asks.

- SSH identity (never print, copy, or commit its contents):
  `C:\\Users\\Evidence\\.ssh\\codex_router_key`.
- OpenWRT 25: `root@192.168.1.1` (VMware x86/64; host-only LAN).
- OpenWRT 24: `root@192.168.241.2` (OpenWrt 24.10 x86/64 VMware VM), with
  VM definition at
  `C:\\Users\\Evidence\\Documents\\Virtual Machines\\OpenWRT 24\\OpenWRT 24.vmx`.

Before a test that changes a VM (package install/upgrade, service start/stop,
configuration, firewall, or reboot), first capture the current package and
service state, state the intended mutation, and keep the test scoped to the
VM. Read-only diagnostics over SSH are allowed.

# Forkop mirror

- Mirror SSH: `root@192.168.200.138` (`Openwrt-Mirror`).
- SSH identity (never print, copy, or commit its contents):
  `C:\\Users\\Evidence\\.ssh\\codex_forkop_mt6000`.
- Canary sync service: `forkop-canary-mirror.service`; the timer normally runs
  it periodically. Check the published release and then start the service to
  sync a requested release immediately. Verify the public `canary.json`,
  `releases.json`, release manifest, and package hashes afterward.

# Forkop temporary customer support

- Operator SSH identity: `C:\Users\Evidence\.ssh\forkop_support_ed25519`.
  Never print, copy, or commit the private key contents. Use the file directly
  with `ssh -i`; it stays on the operator computer, outside the repository.
- Public key bundled in `forkop/files/usr/lib/support/operator.pub`.
- Use this identity only for customer-authorized diagnostics during an active
  LuCI "Allow for 30 minutes" support session and within the user's requested
  scope. Connect as `root` to the Tailscale address reported by the support card.
  Do not reuse the VM or mirror identities for customer support.
- The support worker temporarily authorizes this public key after Tailscale
  authentication, then revokes it on cancellation or expiry. The forced-command
  gate rejects new SSH shells outside the active session. Existing customer
  keys must be preserved.
- This SSH identity is separate from a one-use Tailscale auth key. The latter
  must be freshly supplied when needed; never assume previously used auth keys
  remain usable. Access requires the operator host to be connected to the
  permitted tailnet and the router to have an active support session.
