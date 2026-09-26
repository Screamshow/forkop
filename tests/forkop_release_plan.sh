#!/bin/sh

set -eu

TEST_LIB="${FORKOP_TEST_LIB:-/tmp/forkop-release-test-lib}"
ACTION_UC="$TEST_LIB/components/action.uc"
MIRROR_URL="https://mirror.example.test"
VERSION="1.2.3"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

make_release_json() {
  ext="$1"
  i18n="$2"
  missing="$3"
  assets=""

  if [ "$missing" != backend ]; then
    assets="{\"name\":\"forkop_${VERSION}.${ext}\",\"browser_download_url\":\"/forkop/releases/forkop_${VERSION}.${ext}\"}"
  fi
  if [ "$missing" != app ]; then
    [ -z "$assets" ] || assets="$assets,"
    assets="${assets}{\"name\":\"luci-app-forkop_${VERSION}.${ext}\",\"browser_download_url\":\"/forkop/releases/luci-app-forkop_${VERSION}.${ext}\"}"
  fi
  if [ "$i18n" = 1 ] && [ "$missing" != i18n ]; then
    [ -z "$assets" ] || assets="$assets,"
    assets="${assets}{\"name\":\"luci-i18n-forkop-ru_${VERSION}.${ext}\",\"browser_download_url\":\"/forkop/releases/luci-i18n-forkop-ru_${VERSION}.${ext}\"}"
  fi

  printf '{"tag_name":"%s","html_url":"/forkop/releases/%s","assets":[%s]}\n' "$VERSION" "$VERSION" "$assets"
}

run_plan() {
  make_release_json "$1" "$2" "$3" |
    env FORKOP_LIB="$TEST_LIB" FORKOP_MIRROR_BASE_URL="$MIRROR_URL" \
      ucode -L /usr/lib/forkop "$ACTION_UC" forkop-release-plan-fixture "$VERSION" "$1" "$2"
}

json_field() {
  printf '%s\n' "$1" | jsonfilter -e "@.$2"
}

for ext in ipk apk; do
  for i18n in 0 1; do
    result="$(run_plan "$ext" "$i18n" none)" || fail "$ext i18n=$i18n did not resolve"
    [ "$(json_field "$result" backend_name)" = "forkop_${VERSION}.${ext}" ] || fail "$ext backend name"
    [ "$(json_field "$result" backend_url)" = "$MIRROR_URL/forkop/releases/forkop_${VERSION}.${ext}" ] || fail "$ext backend mirror URL"
    [ "$(json_field "$result" app_name)" = "luci-app-forkop_${VERSION}.${ext}" ] || fail "$ext app name"
    [ "$(json_field "$result" app_url)" = "$MIRROR_URL/forkop/releases/luci-app-forkop_${VERSION}.${ext}" ] || fail "$ext app mirror URL"
    if [ "$i18n" = 1 ]; then
      [ "$(json_field "$result" i18n_name)" = "luci-i18n-forkop-ru_${VERSION}.${ext}" ] || fail "$ext i18n name"
      [ "$(json_field "$result" i18n_url)" = "$MIRROR_URL/forkop/releases/luci-i18n-forkop-ru_${VERSION}.${ext}" ] || fail "$ext i18n mirror URL"
    else
      [ -z "$(json_field "$result" i18n_name)" ] || fail "$ext unexpected i18n name"
      [ -z "$(json_field "$result" i18n_url)" ] || fail "$ext unexpected i18n URL"
    fi
  done

  for missing in backend app; do
    if run_plan "$ext" 0 "$missing" >/dev/null 2>&1; then
      fail "$ext accepted missing $missing asset"
    fi
  done
  if run_plan "$ext" 1 i18n >/dev/null 2>&1; then
    fail "$ext accepted missing required i18n asset"
  fi
done

valid_prefix="/release\tforkop_${VERSION}.ipk\t/forkop.ipk\tluci-app-forkop_${VERSION}.ipk\t/app.ipk"
empty_i18n="$(printf '%b\t\t\r\n' "$valid_prefix" |
  env FORKOP_LIB="$TEST_LIB" FORKOP_MIRROR_BASE_URL="$MIRROR_URL" \
    ucode -L /usr/lib/forkop "$ACTION_UC" forkop-release-plan-fixture "$VERSION" ipk 0 tsv)" ||
  fail 'CRLF terminated TSV with empty i18n fields did not resolve'
[ -z "$(json_field "$empty_i18n" i18n_url)" ] || fail 'CRLF TSV unexpectedly gained an i18n URL'

for partial_i18n in "luci-i18n-forkop-ru_${VERSION}.ipk\t" '\t/i18n.ipk'; do
  if printf '%b\t%b\r\n' "$valid_prefix" "$partial_i18n" |
      env FORKOP_LIB="$TEST_LIB" FORKOP_MIRROR_BASE_URL="$MIRROR_URL" \
        ucode -L /usr/lib/forkop "$ACTION_UC" forkop-release-plan-fixture "$VERSION" ipk 1 tsv >/dev/null 2>&1; then
    fail 'accepted a required i18n field without its matching name or URL'
  fi
done

printf 'Forkop release plan checks passed (5 positive, 8 negative)\n'

# Catalog parsing must reject incomplete, foreign, and malformed releases.
for ext in ipk apk; do
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  for case_name in valid invalid_hash invalid_url missing_translation; do
    checksum="$digest"
    prefix="/forkop/updates/releases/$VERSION/"
    [ "$case_name" != invalid_hash ] || checksum=invalid
    [ "$case_name" != invalid_url ] || prefix=https://example.test/
    translation=",{\"name\":\"luci-i18n-forkop-ru_$VERSION.$ext\",\"sha256\":\"$digest\",\"browser_download_url\":\"/forkop/updates/releases/$VERSION/luci-i18n-forkop-ru_$VERSION.$ext\"}"
    [ "$case_name" != missing_translation ] || translation=""
    result="$(printf '%s' "{\"format\":1,\"releases\":[{\"tag_name\":\"$VERSION\",\"assets\":[{\"name\":\"forkop_$VERSION.$ext\",\"sha256\":\"$checksum\",\"browser_download_url\":\"${prefix}forkop_$VERSION.$ext\"},{\"name\":\"luci-app-forkop_$VERSION.$ext\",\"sha256\":\"$digest\",\"browser_download_url\":\"/forkop/updates/releases/$VERSION/luci-app-forkop_$VERSION.$ext\"}$translation]}]}" |
      ucode -L /usr/lib/forkop "$ACTION_UC" forkop-release-catalog-fixture "$ext")"
    count="$(printf '%s' "$result" | ucode -e 'let fs = require("fs"); print(length(json(fs.open("/dev/stdin", "r").read("all"))));')"
    expected=0
    [ "$case_name" != valid ] || expected=1
    [ "$count" = "$expected" ] || fail "$ext catalog $case_name"
  done
done
printf 'Forkop catalog checks passed (2 positive, 6 negative)\n'
