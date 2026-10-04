# Subscription scheduling tolerance

Verified on 2026-10-05 using the existing VMware OpenWrt 25.12.5
(`192.168.1.1`) and OpenWrt 24.10.8 (`192.168.241.2`) VMs.

Subscription intervals of at least one hour now allow a due check up to
60 seconds before the exact elapsed interval. This prevents a download
completed a few seconds after a cron boundary from missing the next hourly
check. The default 4h interval and existing cron frequency are unchanged.
Short intervals remain exact. A timestamp in the future still postpones
the update; no allowance is applied across a backwards clock jump.

`tests/subscription_due.sh` passed all 18 cases on both VMs using their
native ucode runtimes. Cases cover 1h/4h jitter, both sides of the 60-second
boundary, recent/manual refresh timestamps, short intervals, overdue and
missing timestamps, invalid input and clock rollback. The public
subscription due-status fixture was tested with the default 4h interval;
the list-update fixture retains its exact threshold.

Sources were copied under `/tmp/forkop-subscription-due-test` and executed
there. Package inventories and complete ubus service snapshots were
captured before and after and matched. No packages, live configuration,
cron entries or services were changed. Tests use synthetic timestamps;
they do not download provider subscriptions or restart sing-box. The
customer router at `192.168.90.1` was not modified.

Limitation: this is a bounded scheduling tolerance, not a new scheduler.
A download finishing more than 60 seconds after the matching cron boundary
can still miss that boundary on the next interval. Larger delays and clock
changes require a separate scheduling design; automatic refresh may occur
up to 60 seconds early with this fix.

## Release publication

Stable 1.16.2 was published on 2026-10-05 from commit
`64c9caf8d55db19f806d514e67b7ff9b1165ef41`. GitHub Actions run
`37244597243` completed successfully and published six packages. The release
body was explicitly set from `docs/releases/1.16.2.md` after the workflow
initially substituted the commit subject.

Both mirror sync services completed. The stable archive and stable/latest
pointers were published under `/forkop/updates/releases/1.16.2/`, preserving
the previous pointers under `/srv/mirror/backups/forkop-pre-1.16.2`.
All six stable package hashes matched GitHub asset digests and public HTTPS
downloads. The public stable/latest pointers, release manifest and catalog
were checked. Canary remained at 1.15.1-canary.7; its public manifest and all
six package hashes also passed verification.

The catalog generator reported existing checksum mismatches in historical
archives 1.1.2, 1.1.3, 1.1.4, 1.1.5 and 1.2.2 and omitted those entries.
The new stable release and current canary were included and verified.
