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
