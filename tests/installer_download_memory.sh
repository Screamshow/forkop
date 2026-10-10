#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed '/^main "\$@"$/d' "$ROOT/install.sh" >"$work/library.sh"
. "$work/library.sh"
warn() { :; }
fail() { echo "FAIL: $*" >&2; exit 1; }
TMP_DIR="$work"
FETCHER=curl
temporary_available_space_kb() { echo "$capacity"; }
curl() {
    for output do :; done
    dd if=/dev/zero of="$output" bs=1024 count=4 2>/dev/null
}
capacity=8192
if download_file_once ignored "$work/too-small" >/dev/null 2>&1; then fail 'download started without RAM workspace'; fi
[ ! -e "$work/too-small" ] || fail 'rejected download created output'
capacity=8193
if download_file_once ignored "$work/limited" >/dev/null 2>&1; then fail 'oversized download accepted'; fi
[ "$(wc -c <"$work/limited")" -eq 1024 ] || fail 'download exceeded budget'
dd if=/dev/zero of="$work/parent" bs=1024 count=4 2>/dev/null
[ "$(wc -c <"$work/parent")" -eq 4096 ] || fail 'file limit leaked into installer'
capacity=8196
download_file_once ignored "$work/exact"
[ "$(wc -c <"$work/exact")" -eq 4096 ] || fail 'exact download rejected'
echo 'Installer RAM limit, exact boundary and isolated download limit: OK'
