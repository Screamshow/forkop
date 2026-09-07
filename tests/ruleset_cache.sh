#!/bin/sh
set -eu
set -o pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
RULESET_CACHE_UC="$FORKOP_LIB/singbox/ruleset_cache.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/cache"
cat >"$WORK_DIR/source.json" <<'EOF'
{"version":1,"rules":[{"domain_suffix":["example.test"]}]}
EOF
printf 'mock-srs\n' >"$WORK_DIR/source.srs"

cat >"$WORK_DIR/bin/curl" <<'EOF'
#!/bin/sh
output=''
url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --proxy|--connect-timeout|--max-time) shift 2 ;;
    --fail|--location|--silent|--show-error) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  *.json) cp "$RULESET_TEST_SOURCE_JSON" "$output" ;;
  *.srs) cp "$RULESET_TEST_SOURCE_SRS" "$output" ;;
  *) exit 1 ;;
esac
EOF
cat >"$WORK_DIR/bin/sing-box" <<'EOF'
#!/bin/sh
[ "$1" = rule-set ] && [ "$2" = decompile ] || exit 1
[ -f "$3" ] || exit 1
cp "$RULESET_TEST_SOURCE_JSON" "$5"
EOF
chmod +x "$WORK_DIR/bin/curl" "$WORK_DIR/bin/sing-box"

cat >"$WORK_DIR/config.json" <<'EOF'
{"route":{"rule_set":[
  {"type":"remote","tag":"binary","format":"binary","url":"https://example.test/rules.srs","download_detour":"proxy-out","update_interval":"1d"},
  {"type":"remote","tag":"source","format":"source","url":"https://example.test/rules.json"}
]}}
EOF
cp "$WORK_DIR/config.json" "$WORK_DIR/config-prune.json"

PATH="$WORK_DIR/bin:$PATH" \
RULESET_TEST_SOURCE_JSON="$WORK_DIR/source.json" \
RULESET_TEST_SOURCE_SRS="$WORK_DIR/source.srs" \
FORKOP_RULESET_CACHE_DIR="$WORK_DIR/cache" \
FORKOP_RULESET_CACHE_MANIFEST="$WORK_DIR/cache/manifest.json" \
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" materialize-config "$WORK_DIR/config.json"

if ! ucode -e '
  let fs = require("fs");
  let config = json(fs.readfile(ARGV[0]));
  let values = config.route.rule_set;
  if (length(values) != 2) exit(1);
  for (let value in values) {
    if (value.type != "local" || value.url != null || value.download_detour != null || value.update_interval != null)
      exit(1);
    if (fs.stat(value.path) == null)
      exit(1);
  }
' "$WORK_DIR/config.json"; then
  cat "$WORK_DIR/config.json" >&2
  find "$WORK_DIR/cache" -maxdepth 1 -type f -print >&2
  fail "remote rule sets must be materialized as local validated files"
fi

printf 'orphan\n' >"$WORK_DIR/cache/aaaaaaaaaaaa.srs"
printf 'orphan validation\n' >"$WORK_DIR/cache/aaaaaaaaaaaa.srs.validated"
printf '{"version":1,"rules":[]}\n' >"$WORK_DIR/cache/bbbbbbbbbbbb.json"
printf '{"version":1,"rules":[]}\n' >"$WORK_DIR/cache/empty-cccccccccccc.json"
PATH="$WORK_DIR/bin:$PATH" \
RULESET_TEST_SOURCE_JSON="$WORK_DIR/source.json" \
RULESET_TEST_SOURCE_SRS="$WORK_DIR/source.srs" \
FORKOP_RULESET_CACHE_DIR="$WORK_DIR/cache" \
FORKOP_RULESET_CACHE_MANIFEST="$WORK_DIR/cache/manifest.json" \
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" materialize-config "$WORK_DIR/config-prune.json"
for orphan in aaaaaaaaaaaa.srs aaaaaaaaaaaa.srs.validated bbbbbbbbbbbb.json empty-cccccccccccc.json; do
  [ ! -e "$WORK_DIR/cache/$orphan" ] ||
    fail "materialization must prune stale managed rule-set cache file $orphan"
done
[ "$(find "$WORK_DIR/cache" -maxdepth 1 -type f -name '*.srs' | wc -l)" -eq 1 ] ||
  fail "materialization must retain the active binary rule-set cache"

cat >"$WORK_DIR/offline.json" <<'EOF'
{"route":{"rule_set":[{"type":"remote","tag":"offline","format":"binary","url":"https://offline.test/missing.srs"}]}}
EOF
cat >"$WORK_DIR/bin/curl" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$WORK_DIR/bin/curl"
PATH="$WORK_DIR/bin:$PATH" \
RULESET_TEST_SOURCE_JSON="$WORK_DIR/source.json" \
FORKOP_RULESET_CACHE_DIR="$WORK_DIR/cache" \
FORKOP_RULESET_CACHE_MANIFEST="$WORK_DIR/cache/manifest.json" \
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" materialize-config "$WORK_DIR/offline.json" 2>/dev/null
ucode -e '
  let fs = require("fs");
  let value = json(fs.readfile(ARGV[0])).route.rule_set[0];
  let source = json(fs.readfile(value.path));
  if (value.type != "local" || value.format != "source" || length(source.rules) != 0)
    exit(1);
' "$WORK_DIR/offline.json" || fail "first offline start must use an empty local rule set instead of blocking sing-box"

cat >"$WORK_DIR/cache-only.json" <<'EOF'
{"route":{"rule_set":[{"type":"remote","tag":"private","format":"binary","url":"https://private.test/rules.srs"}]}}
EOF
cat >"$WORK_DIR/bin/curl" <<'EOF'
#!/bin/sh
printf 'direct download attempted\n' >>"$RULESET_TEST_CURL_CALLS"
exit 1
EOF
chmod +x "$WORK_DIR/bin/curl"
: >"$WORK_DIR/curl.calls"
PATH="$WORK_DIR/bin:$PATH" \
RULESET_TEST_SOURCE_JSON="$WORK_DIR/source.json" \
RULESET_TEST_CURL_CALLS="$WORK_DIR/curl.calls" \
FORKOP_RULESET_CACHE_DIR="$WORK_DIR/cache" \
FORKOP_RULESET_CACHE_MANIFEST="$WORK_DIR/cache/manifest.json" \
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" materialize-config "$WORK_DIR/cache-only.json" cache-only 2>/dev/null
[ ! -s "$WORK_DIR/curl.calls" ] ||
  fail "proxy-only cold start must not attempt a direct rule-set download before the service proxy is ready"

fallback="$({
  FORKOP_MIRROR_BASE_URL='https://mirror.test'
  SRS_MAIN_URL='https://mirror.test/forkop/lists/rulesets/community'
  SRS_FALLBACK_MAIN_URL='https://upstream.test/community'
  export FORKOP_MIRROR_BASE_URL SRS_MAIN_URL SRS_FALLBACK_MAIN_URL
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" fallback-urls \
    'https://mirror.test/forkop/lists/rulesets/community/youtube.srs'
})"
[ "$fallback" = 'https://upstream.test/community/youtube.srs' ] ||
  fail "community rule-set fallback must preserve the asset name"

before="$(find "$WORK_DIR/cache" -maxdepth 1 -type f -name '*.srs' -exec md5sum {} \;)"
PATH="$WORK_DIR/bin:$PATH" \
RULESET_TEST_SOURCE_JSON="$WORK_DIR/source.json" \
RULESET_TEST_SOURCE_SRS="$WORK_DIR/source.srs" \
FORKOP_RULESET_CACHE_DIR="$WORK_DIR/cache" \
FORKOP_RULESET_CACHE_MANIFEST="$WORK_DIR/cache/manifest.json" \
  ucode -L "$FORKOP_LIB" "$RULESET_CACHE_UC" refresh >/dev/null 2>&1 || true
after="$(find "$WORK_DIR/cache" -maxdepth 1 -type f -name '*.srs' -exec md5sum {} \;)"
[ "$before" = "$after" ] || fail "an unchanged cached rule set must remain stable"

printf 'ruleset cache checks passed\n'
