#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELOAD_UC="$ROOT_DIR/forkop/files/usr/lib/service/reload.uc"
STATE_UC="$ROOT_DIR/forkop/files/usr/lib/service/state.uc"
LIFECYCLE_UC="$ROOT_DIR/forkop/files/usr/lib/service/lifecycle.uc"
UPDATES_UC="$ROOT_DIR/forkop/files/usr/lib/components/updates.uc"
FORKOP_LIB="${FORKOP_TEST_LIB:-$ROOT_DIR/forkop/files/usr/lib}"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cat >"$WORK_DIR/base.json" <<'JSON'
{"section":[{".name":"alpha","enabled":"1","action":"connection","ports":"80","excluded_source_ip_cidr":["192.0.2.1/32"],"source_network_interfaces":["br-lan"],"remote_domain_lists":["https://lists.test/a.lst"]},{".name":"beta","enabled":"1","action":"block","community_lists":["telegram"]}]}
JSON
cat >"$WORK_DIR/local.json" <<'JSON'
{"section":[{".name":"alpha","enabled":"1","action":"block","ports":"443","excluded_source_ip_cidr":["192.0.2.2/32"],"source_network_interfaces":["guest"],"remote_domain_lists":["https://lists.test/a.lst"]},{".name":"beta","enabled":"1","action":"block","community_lists":["telegram"]}]}
JSON
cat >"$WORK_DIR/source.json" <<'JSON'
{"section":[{".name":"alpha","enabled":"1","action":"connection","ports":"80","remote_domain_lists":["https://lists.test/b.lst"]},{".name":"beta","enabled":"1","action":"block","community_lists":["telegram"]}]}
JSON
cat >"$WORK_DIR/reordered.json" <<'JSON'
{"section":[{".name":"beta","enabled":"1","action":"block","community_lists":["telegram"]},{".name":"alpha","enabled":"1","action":"connection","ports":"80","excluded_source_ip_cidr":["192.0.2.1/32"],"source_network_interfaces":["br-lan"],"remote_domain_lists":["https://lists.test/a.lst"]}]}
JSON

list_signature() {
  ucode -L "$FORKOP_LIB" "$STATE_UC" list-update-signature-fixture "$1"
}

base_signature="$(list_signature "$WORK_DIR/base.json")"
[ "$base_signature" = "$(list_signature "$WORK_DIR/local.json")" ] ||
  fail "local routing conditions changed the list source signature"
[ "$base_signature" = "$(list_signature "$WORK_DIR/reordered.json")" ] ||
  fail "section ordering changed the list source signature"
[ "$base_signature" != "$(list_signature "$WORK_DIR/source.json")" ] ||
  fail "a changed list URL did not change the list source signature"

plan_output="$(ucode "$RELOAD_UC" plan \
  svc dns sb nft-old zq zr z2q z2r br list cron 1 sections \
  svc dns sb nft-new zq zr z2q z2r br list cron sections 0 \
  0 0 1 1 0)"
printf '%s\n' "$plan_output" | awk -F '\t' '$1 == "needs_nft_rebuild" && $2 == "1" { found = 1 } END { exit found ? 0 : 1 }' ||
  fail "local nft change did not request an nft rebuild"
printf '%s\n' "$plan_output" | awk -F '\t' '$1 == "needs_list_update" && $2 == "0" { found = 1 } END { exit found ? 0 : 1 }' ||
  fail "local nft change requested a list update"

if grep -Fq 'needs.nft_rebuild && context.has_nft_list_update_sources' "$RELOAD_UC"; then
  fail "an nft rebuild must not imply a network list update"
fi

for local_key in '.action"' '.ports"' '.source_ip_cidr"' '.excluded_source_ip_cidr"' '.interfaces"'; do
  if awk -v needle="$local_key" '
    /function append_list_update_signature_body/ { active = 1 }
    active && index($0, needle) { found = 1 }
    active && /^}/ { exit found ? 0 : 1 }
    END { if (!active || !found) exit 1 }
  ' "$STATE_UC"; then
    fail "local condition $local_key leaked into the list source signature"
  fi
done

for source_key in community_lists remote_domain_lists remote_subnet_lists rule_set rule_set_with_subnets domain_ip_lists; do
  grep -Fq ".$source_key" "$STATE_UC" ||
    fail "list source signature does not track $source_key"
done

if awk '
  /function finish_list_update/ { active = 1 }
  active && /automatic-latency-test/ { found = 1 }
  active && /^}/ { exit found ? 0 : 1 }
  END { if (!active || !found) exit 1 }
' "$UPDATES_UC"; then
  fail "ordinary list updates must not schedule automatic latency tests"
fi

grep -Fq '[ "cp", "-R", "-p", TMP_RULESET_FOLDER + "/.", list_ruleset_snapshot_dir ]' "$UPDATES_UC" ||
  fail "list updates must preserve metadata for unchanged materialized rule sets"
[ "$(grep -Fc 'SERVICE_INIT, "reload", "list-content"' "$UPDATES_UC")" -eq 1 ] ||
  fail "changed list content must request exactly one final reload"
grep -Fq 'applied && (reload_deferred || rulesets_changed || ruleset_changed)' "$UPDATES_UC" ||
  fail "list worker must coalesce deferred and committed-content reloads"
grep -Fq 'if (!applied)' "$UPDATES_UC" &&
  grep -Fq 'write_file(LIST_UPDATE_RELOAD_FILE, "1\n")' "$UPDATES_UC" ||
  fail "failed source transactions must preserve rather than execute a deferred reload"
grep -Fq 'plan.needs_sing_box_reload == 1 && plan.needs_list_update == 1' "$LIFECYCLE_UC" ||
  fail "source changes must defer an intermediate sing-box reload"

grep -Fq 'if (plan.changed_list == 1)' "$LIFECYCLE_UC" ||
  fail "rule-set refresh must be guarded by a changed source signature"

if [ "$(grep -Fc '"refresh-and-reload"' "$LIFECYCLE_UC")" -ne 1 ]; then
  fail "reload lifecycle must have exactly one conditional rule-set refresh"
fi

grep -Fq 'if (refresh_manifest(proxy_address, false) != 0)' "$ROOT_DIR/forkop/files/usr/lib/singbox/ruleset_cache.uc" ||
  fail "unchanged rule-set content must not request a reload"
grep -Fq 'if (failed && !changed)' "$ROOT_DIR/forkop/files/usr/lib/singbox/ruleset_cache.uc" ||
  fail "a failed rule-set source must not suppress reload of other successful changes"

grep -Fq 'PERSISTENT_LIST_CACHE_DIR + "/last-success.timestamp"' "$UPDATES_UC" ||
  fail "successful list update time must survive a reboot"
grep -Fq 'function prepare_list_downloads(sections, proxy_address)' "$UPDATES_UC" ||
  fail "all remote list sources must pass preflight before active state changes"
grep -Fq 'function restore_list_nft_snapshot()' "$UPDATES_UC" ||
  fail "an aborted list transaction must restore the active nftables table"
grep -Fq 'current_list_update_signature() != list_update_signature_at_start' "$UPDATES_UC" ||
  fail "a concurrent source edit must discard the stale downloaded generation"
grep -Fq 'module_background(UPDATES_UC, [ "list-update-after-start" ])' "$LIFECYCLE_UC" ||
  fail "startup must use cache-aware due scheduling instead of unconditional downloads"

grep -Fq 'if (status == 0)' "$UPDATES_UC" ||
  fail "list_update_if_due scheduling contract is missing"
grep -Fq 'if (ok && subscription_outbounds_changed)' "$UPDATES_UC" ||
  fail "subscription updates must warm latency only after outbounds changed"
grep -Fq 'subscription_outbounds_changed = true' "$UPDATES_UC" ||
  fail "successful changed subscriptions must retain automatic latency warm-up"

printf 'list update/reload policy checks passed\n'
