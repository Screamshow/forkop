# sing-box X 1.0.1 — Clash API route match evidence

## Reproduction

Read-only diagnostics on the user-authorized router at 192.168.90.1 reproduced
the reported behavior with X 1.0.0 (upstream 1.14.2, APK revision 2).
Live connections to `chatgpt.com` and `persistent.oaistatic.com` returned a
logical rule containing `domain_suffix=[dell.com 2ip.io vencord.dev...]`,
an empty `rulePayload` and an empty `destinationIP`. The complete runtime
configuration includes `chatgpt.com` and `oaistatic.com` in the suffix list.
Forkop deliberately cannot reconstruct an exact match from that abbreviated
logical expression, so it displays “Exact match unavailable”.

## Change

X captures positive inline destination evidence during actual rule evaluation
and includes it in the existing Clash API `rulePayload` field. The rule's
original description, route selection and connection metadata remain intact.
Supported evidence is domain, suffix, keyword, RE2 regex and destination CIDR,
including a DNS-resolved address absent from the API's final destinationIP.
Evidence is connection-local. Failed, inverted, deferred and opaque rule-set
evaluations do not expose a positive destination entry. Logical AND combines
successful child evidence; OR retains the selected definite branch.
The implementation does not rerun the routing engine in an API request.

Forkop's monitoring formatter prefers this evidence to its legacy rule parser.
The two reproduced rows therefore display `domain_suffix=chatgpt.com` and
`domain_suffix=oaistatic.com`. Legacy cores without evidence keep their existing
behavior; default routes discard stale payloads. Binary rule sets and purely
negative/device rules retain the existing fallback rather than claiming an
exact positive destination entry.

## Local validation

- All upstream rule tests, Clash API tests and added payload regression tests
  passed with the X build tags and required `-checklinkname=0` linker flag.
- Route and DNS package tests passed.
- All 554 frontend tests passed (52 files), including 14 monitoring tests.
- TypeScript validation and LuCI bundle build passed.
- Reapplying the source preparation scripts succeeded without modifying the
  already patched source. Python and shell syntax checks passed.
- The x86-64 UPX binary passed `upx -t` and ran on both existing VMware VMs.

## VM integration

OpenWrt 25 at 192.168.1.1 and OpenWrt 24 at 192.168.241.2 ran the candidate in
an isolated temporary directory with separate loopback-only SOCKS, Clash API
and HTTP listeners. Installed sing-box/Forkop services were not stopped or
replaced. The probe captured and compared complete global package/service
state and Forkop/sing-box configuration hashes before and after.

Both VMs passed seven real SOCKS/HTTP requests and exact API assertions:

| Host | rulePayload | Outbound |
|---|---|---|
| chatgpt.com | domain_suffix=chatgpt.com | VPN-out |
| persistent.oaistatic.com | domain_suffix=oaistatic.com | VPN-out |
| keyword.example | domain_keyword=keyword | VPN-out |
| regex.example | domain_regex=^regex\\.example$ | VPN-out |
| cidr.example | ip_cidr=127.0.0.1 | VPN-out |
| default.example | empty | fallback-out |
| failed.example | empty | fallback-out |

All seven API objects had empty destinationIP, intentionally reproducing the
original metadata limitation. The failed logical branch and default route
never inherited evidence from an earlier condition/action. The HTTP requests
all completed successfully, and package/configuration/service snapshots were
byte-for-byte unchanged. Test processes were terminated by the probe.

The router at 192.168.90.1 remains on its existing installation; it was used
only for read-only reproduction during this task.

## Release verification

Stable release: https://github.com/Screamshow/sing-box-x/releases/tag/1.0.1

Successful build and race checks:
https://github.com/Screamshow/sing-box-x/actions/runs/37664492872

Mirror catalog: https://mirror.51343.ru/forkop/sing-box-x/latest.json

Release manifest:
https://mirror.51343.ru/forkop/sing-box-x/releases/1.0.1/manifest.json

- X application 1.0.1, upstream 1.14.2, APK 1.0.1-r1, IPK 1.0.1-1.
- All CI asset hashes and SHA256SUMS passed verification before publication.
- The final CI x86-64 binary is byte-for-byte identical to the candidate run
  on both VMs: SHA-256 `ef461190a690c2643982b95839d429e75e7acdd72c8e48deff72b814cd91a410`.
- The existing mirror publisher verified GitHub asset digests, signed both APKs
  using the existing mirror identity and verified both signatures.
- Public latest.json and manifest agree on release/package identity; all seven
  public assets passed mirror URL, length and SHA-256 validation.
- Signed x86-64 APK installation/reinstallation passed in an isolated package
  root on OpenWrt 25. x86-64 IPK installation/reinstallation passed in an
  isolated root on OpenWrt 24. Both preserved the modified UCI conffile and
  accepted the test configuration. Global packages, configs and running
  service snapshots were unchanged.
- Temporary probe processes and directories were removed from both VMs.
- ARM64 was built, UPX-tested, packaged and signature/hash-verified; its new
  binary was not installed or executed on the live ARM64 router in this task.

| Architecture | UPX binary bytes | APK installed payload bytes |
|---|---:|---:|
| aarch64_cortex-a53 | 8,537,372 | 8,539,655 |
| x86_64 | 9,863,528 | 9,865,799 |

The release uses the successful manual CI build's immutable assets. Creating
the release also triggered a redundant tag build; that duplicate was cancelled
because its publish step would attempt to recreate the existing release.
The monitoring formatter and rebuilt LuCI bundle are included in Forkop main;
they were not deployed to 192.168.90.1 as part of this release task.
