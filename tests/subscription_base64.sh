#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
{
  printf '%s\n' 'function as_string(value) { return value == null ? "" : "" + value; }'
  for spec in 'subscription/parser.uc base64_decode' 'subscription/share_link.uc base64_encode'; do
    read -r path name <<< "$spec"
    awk -v name="$name" '$0 ~ "^function " name "\\(" { emit = 1 }
         emit { print }
         emit && /^}/ { exit }' "$ROOT_DIR/forkop/files/usr/lib/$path"
  done
  cat <<'UCODE'
let cases = [
    { input: "aGVsbG8=", expected: "hello" },
    { input: "aGVsbG8", expected: "hello" },
    { input: " Z g\n\t", expected: "f" },
    { input: "Zm8", expected: "fo" },
    { input: "--__", expected: chr(251) + chr(239) + chr(255) },
    { input: "", expected: null },
    { input: "a", expected: null }
];
for (let test in cases) {
    if (base64_decode(test.input) != test.expected) die("decode failed\n");
    if (test.expected != null && base64_decode(base64_encode(test.expected)) != test.expected) die("roundtrip failed\n");
}
print("Native subscription base64: padded, unpadded, whitespace, URL-safe, invalid length and roundtrip passed\n");
UCODE
} | ucode -