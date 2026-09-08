#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT_DIR/build.sh"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ "$(bash "$BUILD" --check-version 1.3.9)" = "1.3.9" ] ||
  fail "plain release version was rejected"
[ "$(bash "$BUILD" --check-version 1.3.9-7)" = "1.3.9-7" ] ||
  fail "numeric package revision was rejected"

for version in 1.3.9-qa.urltest 1.3.9-rc1 1.3.9- 1.3 1.3.9.1; do
  if bash "$BUILD" --check-version "$version" >"/dev/null" 2>"$WORK_DIR/error"; then
    fail "invalid version '$version' was accepted"
  fi
  grep -Fq 'x.y.z-N (numeric package revision)' "$WORK_DIR/error" || {
    fail "invalid version '$version' did not receive the early validation error"
  }
done

printf 'build version checks passed\n'
