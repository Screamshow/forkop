#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
UPDATES_UC="$FORKOP_LIB/components/updates.uc"
STATE_UC="$FORKOP_LIB/service/state.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/cache" "$WORK_DIR/runtime-rulesets" "$WORK_DIR/bin"
cat >"$WORK_DIR/uci.state" <<'EOF_UCI'
forkop.settings=settings
forkop.settings.update_interval=1d
forkop.alpha=section
forkop.alpha.enabled=1
forkop.alpha.action=connection
forkop.alpha.remote_domain_lists=https://lists.test/domains.txt
EOF_UCI
cat >"$WORK_DIR/cache/alpha-remote-domains-ruleset.json" <<'EOF_RULESET'
{"version":3,"rules":[{"domain_suffix":["old.example"]}]}
EOF_RULESET
printf 'cached.example\n' >"$WORK_DIR/cache/source-1"

signature="$(FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  ucode -L "$FORKOP_LIB" "$STATE_UC" list-update-signature)"
ruleset_md5="$(md5sum "$WORK_DIR/cache/alpha-remote-domains-ruleset.json" | cut -d' ' -f1)"
source_md5="$(md5sum "$WORK_DIR/cache/source-1" | cut -d' ' -f1)"
cat >"$WORK_DIR/cache/manifest.json" <<EOF_MANIFEST
{"format":"1","signature":"$signature","files":{"alpha-remote-domains-ruleset.json":"$ruleset_md5"},"sources":[{"name":"source-1","url":"https://lists.test/domains.txt","format":"plain","md5":"$source_md5"}]}
EOF_MANIFEST
printf '2000000000\n' >"$WORK_DIR/cache/last-success.timestamp"

cache_cmd() {
  PATH="$WORK_DIR/bin:$PATH" \
  FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/cache" \
  FORKOP_RULESET_CACHE_DIR="$WORK_DIR/ruleset-cache" \
  FORKOP_PERSISTENT_LIST_CACHE_MANIFEST="$WORK_DIR/cache/manifest.json" \
  FORKOP_LIST_UPDATE_STATE_FILE="$WORK_DIR/cache/last-success.timestamp" \
  FORKOP_LIST_UPDATE_RUNTIME_STATE_FILE="$WORK_DIR/runtime-last-success.timestamp" \
  FORKOP_LIST_UPDATE_RUNTIME_SIGNATURE_FILE="$WORK_DIR/runtime-signature" \
  TMP_RULESET_FOLDER="$WORK_DIR/runtime-rulesets" \
  FORKOP_LIB="$FORKOP_LIB" \
    ucode -L "$FORKOP_LIB" "$UPDATES_UC" "$@"
}

cat >"$WORK_DIR/bin/wget" <<'EOF_WGET'
#!/bin/sh
printf 'network attempted\n' >>"$LIST_CACHE_WGET_LOG"
exit 1
EOF_WGET
chmod +x "$WORK_DIR/bin/wget"
export LIST_CACHE_WGET_LOG="$WORK_DIR/wget.log"
: >"$LIST_CACHE_WGET_LOG"

cache_cmd list-cache-valid || fail "valid persistent cache was rejected"
cache_cmd restore-list-cache || fail "valid persistent cache was not restored"
cmp "$WORK_DIR/cache/alpha-remote-domains-ruleset.json" \
  "$WORK_DIR/runtime-rulesets/alpha-remote-domains-ruleset.json" ||
  fail "restored materialized list differs from persistent cache"

# A newer RAM-only update must survive service reload preparation instead of
# being overwritten by the older but still valid persistent cache.
cat >"$WORK_DIR/runtime-rulesets/alpha-remote-domains-ruleset.json" <<'EOF_RUNTIME_NEW'
{"version":3,"rules":[{"domain_suffix":["runtime-new.example"]}]}
EOF_RUNTIME_NEW
printf '2000000001\n' >"$WORK_DIR/runtime-last-success.timestamp"
printf '%s\n' "$signature" >"$WORK_DIR/runtime-signature"
cache_cmd runtime-list-cache-active || fail "newer RAM-only list state was not recognized"
cache_cmd restore-list-cache || fail "RAM-only list state was rejected during reload preparation"
grep -Fq 'runtime-new.example' "$WORK_DIR/runtime-rulesets/alpha-remote-domains-ruleset.json" ||
  fail "older persistent cache overwrote newer RAM-only lists"
cache_cmd apply-list-cache || fail "RAM-only list state could not bypass persistent cache application"
grep -Fq 'runtime-new.example' "$WORK_DIR/runtime-rulesets/alpha-remote-domains-ruleset.json" ||
  fail "persistent cache application overwrote newer RAM-only lists"
rm -f "$WORK_DIR/runtime-last-success.timestamp" "$WORK_DIR/runtime-signature"

# Recover the previous complete generation if power is lost between the two
# atomic directory renames, and discard an untrusted incomplete stage.
mv "$WORK_DIR/cache" "$WORK_DIR/cache.previous"
mkdir -p "$WORK_DIR/cache.stage"
printf 'incomplete\n' >"$WORK_DIR/cache.stage/source-1"
cache_cmd list-cache-valid || fail "interrupted persistent cache swap was not recovered"
[ -d "$WORK_DIR/cache" ] || fail "previous persistent cache generation was not restored"
[ ! -e "$WORK_DIR/cache.previous" ] || fail "recovered previous cache generation was not consumed"
[ ! -e "$WORK_DIR/cache.stage" ] || fail "incomplete staged cache generation was not removed"

# Local routing conditions do not invalidate source cache identity.
sed -i 's/forkop.alpha.action=connection/forkop.alpha.action=block/' "$WORK_DIR/uci.state"
cache_cmd list-cache-valid || fail "local action change invalidated list cache"

cache_cmd apply-list-cache || fail "cached sources could not be applied offline"
[ ! -s "$LIST_CACHE_WGET_LOG" ] || fail "offline cache application attempted network I/O"
grep -Fq 'cached.example' "$WORK_DIR/runtime-rulesets/alpha-remote-domains-ruleset.json" ||
  fail "cached source content was not materialized"

# Source changes and corruption must be rejected before use.
sed -i 's#domains.txt#changed.txt#' "$WORK_DIR/uci.state"
if cache_cmd list-cache-valid; then
  fail "changed source URL reused a stale cache generation"
fi
sed -i 's#changed.txt#domains.txt#' "$WORK_DIR/uci.state"
printf 'corrupt\n' >>"$WORK_DIR/cache/source-1"
if cache_cmd list-cache-valid; then
  fail "corrupt cached source was accepted"
fi

# Flash quota applies only to persistence. With 10 MiB available and an
# 8 MiB reserve, a 1 MiB generation fits while a 3 MiB generation does not.
FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=10485760 \
FORKOP_PERSISTENT_LIST_CACHE_MAX_BYTES=8388608 \
FORKOP_PERSISTENT_LIST_CACHE_MIN_FREE_BYTES=8388608 \
  cache_cmd list-cache-capacity 1048576 ||
  fail "a cache generation fitting above the flash reserve was rejected"
if FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=10485760 \
  FORKOP_PERSISTENT_LIST_CACHE_MAX_BYTES=8388608 \
  FORKOP_PERSISTENT_LIST_CACHE_MIN_FREE_BYTES=8388608 \
    cache_cmd list-cache-capacity 3145728; then
  fail "a cache generation crossing the flash reserve was accepted"
fi
if FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=33554432 \
  FORKOP_PERSISTENT_LIST_CACHE_MAX_BYTES=8388608 \
  FORKOP_PERSISTENT_LIST_CACHE_MIN_FREE_BYTES=8388608 \
    cache_cmd list-cache-capacity 9437184; then
  fail "a cache generation exceeding the absolute quota was accepted"
fi
mkdir -p "$WORK_DIR/ruleset-cache"
dd if=/dev/zero of="$WORK_DIR/ruleset-cache/existing.srs" bs=1024 count=7680 2>/dev/null
if FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=33554432 \
  FORKOP_PERSISTENT_LIST_CACHE_MAX_BYTES=8388608 \
  FORKOP_PERSISTENT_LIST_CACHE_MIN_FREE_BYTES=8388608 \
    cache_cmd list-cache-capacity 1048576; then
  fail "combined list and remote rule-set caches exceeded the shared quota"
fi
rm -rf "$WORK_DIR/ruleset-cache"

# A failed persistence attempt must leave the previous complete cache intact.
mkdir -p "$WORK_DIR/quota-runtime" "$WORK_DIR/quota-cache"
cat >"$WORK_DIR/quota-runtime/alpha-lists-ruleset.json" <<'EOF_QUOTA_RULESET'
{"version":3,"rules":[{"domain_suffix":["first.example"]}]}
EOF_QUOTA_RULESET
quota_cmd() {
  FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" \
  FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/quota-cache" \
  FORKOP_RULESET_CACHE_DIR="$WORK_DIR/quota-ruleset-cache" \
  FORKOP_PERSISTENT_LIST_CACHE_MANIFEST="$WORK_DIR/quota-cache/manifest.json" \
  FORKOP_LIST_UPDATE_STATE_FILE="$WORK_DIR/quota-cache/last-success.timestamp" \
  TMP_RULESET_FOLDER="$WORK_DIR/quota-runtime" \
  FORKOP_LIB="$FORKOP_LIB" \
    ucode -L "$FORKOP_LIB" "$UPDATES_UC" "$@"
}
FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=33554432 quota_cmd persist-list-cache 100 ||
  fail "a fitting persistent cache was not committed"
first_md5="$(md5sum "$WORK_DIR/quota-cache/alpha-lists-ruleset.json" | cut -d' ' -f1)"
cat >"$WORK_DIR/quota-runtime/alpha-lists-ruleset.json" <<'EOF_QUOTA_CHANGED'
{"version":3,"rules":[{"domain_suffix":["second.example"]}]}
EOF_QUOTA_CHANGED
if FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=8390000 quota_cmd persist-list-cache 200; then
  fail "persistent cache committed despite violating the free-space reserve"
fi
[ "$first_md5" = "$(md5sum "$WORK_DIR/quota-cache/alpha-lists-ruleset.json" | cut -d' ' -f1)" ] ||
  fail "failed persistence replaced the previous complete cache"
[ "$(cat "$WORK_DIR/quota-cache/last-success.timestamp")" = 100 ] ||
  fail "failed persistence changed the previous success timestamp"

# The streaming limit wrapper must preserve proxy variables for wget.
cat >"$WORK_DIR/bin/wget" <<'EOF_PROXY_WGET'
#!/bin/sh
[ "${http_proxy:-}" = 'http://127.0.0.1:18080' ] || exit 1
[ "${https_proxy:-}" = 'http://127.0.0.1:18080' ] || exit 1
while [ "$#" -gt 0 ]; do
  if [ "$1" = -O ]; then
    printf 'proxied.example\n' >"$2"
    exit 0
  fi
  shift
done
exit 1
EOF_PROXY_WGET
chmod +x "$WORK_DIR/bin/wget"
PATH="$WORK_DIR/bin:$PATH" FORKOP_LIST_DOWNLOAD_MIN_FREE_BYTES=0 FORKOP_LIB="$FORKOP_LIB" \
  ucode -L "$FORKOP_LIB" "$UPDATES_UC" download-list-file \
    https://lists.test/proxied "$WORK_DIR/proxied" 127.0.0.1:18080 ||
  fail "temporary-space limit wrapper dropped the service proxy environment"
grep -Fq 'proxied.example' "$WORK_DIR/proxied" || fail "proxied fixture download was not written"

printf 'persistent list cache checks passed\n'
