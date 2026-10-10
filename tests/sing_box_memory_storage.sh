#!/bin/sh
set -eu
lib=${FORKOP_TEST_LIB:-/usr/lib/forkop}
action=${FORKOP_TEST_ACTION:-$lib/components/action.uc}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
run() { ucode -L "$lib" "$action" "$@"; }
[ "$(run temporary-capacity-fixture 100000 12000)" = 12000 ] || fail 'tmpfs hides physical RAM shortage'
[ "$(run temporary-capacity-fixture 6000 12000)" = 6000 ] || fail 'tmpfs quota ignored'
[ "$(run temporary-capacity-fixture 100000 -1)" = -1 ] || fail 'unknown RAM accepted'
if run download-limit-fixture 8192 "$work/download" >/dev/null 2>&1; then fail 'download started without workspace'; fi
[ ! -f "$work/download" ] || fail 'failed download created file'
if run download-limit-fixture 8193 "$work/download" >/dev/null 2>&1; then fail 'oversized download accepted'; fi
[ "$(wc -c <"$work/download")" -eq 1024 ] || fail 'download exceeded physical RAM budget'

mkdir -p "$work/archive"
dd if=/dev/zero of="$work/archive/sing-box" bs=1024 count=1024 2>/dev/null
tar -czf "$work/target.tar.gz" -C "$work/archive" sing-box
run archive-install-fixture "$work/target.tar.gz" sing-box "$work/installed"
cmp "$work/archive/sing-box" "$work/installed" || fail 'streamed payload changed'
[ -x "$work/installed" ] || fail 'streamed binary mode wrong'
if run archive-install-fixture "$work/target.tar.gz" missing "$work/installed" >/dev/null 2>&1; then fail 'missing member accepted'; fi
cmp "$work/archive/sing-box" "$work/installed" || fail 'failed extraction replaced target'
printf invalid >"$work/broken.tar.gz"
if run archive-install-fixture "$work/broken.tar.gz" sing-box "$work/installed" >/dev/null 2>&1; then fail 'broken archive accepted'; fi
cmp "$work/archive/sing-box" "$work/installed" || fail 'broken archive replaced target'
[ -z "$(find "$work" -name '*.forkop-new.*')" ] || fail 'partial flash file retained'
echo 'Physical RAM budget, bounded downloads and streamed install failures: OK'
