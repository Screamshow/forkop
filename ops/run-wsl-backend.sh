#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

ucode -e 'exit(0)' >/dev/null
sing-box version >/dev/null

find "$ROOT_DIR/forkop/files/usr/lib" -name '*.uc' -print0 | xargs -0 -n1 ucode -c -o /dev/null
find "$ROOT_DIR/forkop/files/usr/lib" -name '*.uc' -print0 | xargs -0 -n1 ucode -S -c -o /dev/null

for test_file in "$ROOT_DIR"/tests/*.sh; do
  printf 'Running %s\n' "${test_file#"$ROOT_DIR/"}"
  timeout 180 bash "$test_file"
done
