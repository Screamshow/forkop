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
  FORKOP_PERSISTENT_LIST_CACHE_MANIFEST="$WORK_DIR/cache/manifest.json" \
  FORKOP_LIST_UPDATE_STATE_FILE="$WORK_DIR/cache/last-success.timestamp" \
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

printf 'persistent list cache checks passed\n'
