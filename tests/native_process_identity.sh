#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
{
  cat <<'UCODE'
let links = {};
let fs = { readlink: function(path) { return links[path]; } };
function as_string(value) { return value == null ? "" : "" + value; }
UCODE
  awk '/^function path_basename\(/ { emit = 1 }
       /^function hup_sing_box_runtime\(/ { emit = 0 }
       emit { print }' "$ROOT_DIR/forkop/files/usr/lib/service/state.uc"
  cat <<'UCODE'
let cases = [
    { target: "/usr/bin/sing-box", present: true, current: true, deleted: false },
    { target: "/usr/bin/sing-box (deleted)", present: true, current: false, deleted: true },
    { target: "/tmp/foreign/sing-box", present: true, current: true, deleted: false },
    { target: "/tmp/foreign/sing-box (deleted)", present: true, current: false, deleted: true },
    { target: "/usr/bin/sing-box-test", present: false, current: false, deleted: false },
    { target: "/usr/bin/ash", present: false, current: false, deleted: false },
    { target: null, present: false, current: false, deleted: false }
];
for (let test in cases) {
    links = { "/proc/123/exe": test.target };
    if (pid_is_sing_box("123") != test.present ||
        pid_has_current_sing_box_exe("123") != test.current ||
        pid_has_deleted_sing_box_exe("123") != test.deleted)
        die("Executable identity regression\n");
}
if (pid_is_sing_box("../123") || pid_is_sing_box("123; echo injected") || pid_is_sing_box(""))
    die("Invalid PID accepted\n");
print("Native executable identity checks passed\n");
UCODE
} | ucode -