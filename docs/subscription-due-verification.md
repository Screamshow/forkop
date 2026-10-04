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
