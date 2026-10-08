#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for provider in nfqueue byedpi; do
  {
    cat <<'UCODE'
let files = {};
let calls = [];
const BYEDPI_PID_DIR = "owned/pid";
const BYEDPI_CHILD_PID_DIR = "owned/child-pid";
const BYEDPI_LOG_DIR = "owned/log";
function pidfiles_in_dir(dir) { return files[dir] || []; }
function kill_pidfile_process(path, signal) {
    push(calls, ["kill", path, signal]);
    // Supervisors can remove a child PID file after TERM.
    if (path == "self-removing" && signal == "")
        files[BYEDPI_CHILD_PID_DIR] = [];
}
function command_success_from_args(args) { push(calls, args); return true; }
UCODE
    awk '/^function stop_runtime\(/ { emit = 1 }
         emit { print }
         emit && /^}/ { exit }' "$ROOT_DIR/forkop/files/usr/lib/providers/$provider/runtime.uc"
    cat <<'UCODE'
let cfg = { pid_dir: BYEDPI_PID_DIR, child_pid_dir: BYEDPI_CHILD_PID_DIR,
            log_dir: BYEDPI_LOG_DIR, hostlist_dir: "", legacy_runtime_base: "" };
let cases = [
    { name: "absent", supervisors: null, children: null, waits: 0 },
    { name: "empty", supervisors: [], children: [], waits: 0 },
    { name: "supervisor", supervisors: ["supervisor"], children: [], waits: 1 },
    { name: "child", supervisors: [], children: ["child"], waits: 1 },
    { name: "stale PID file", supervisors: ["stale"], children: [], waits: 1 },
    { name: "TERM removes child PID file", supervisors: [], children: ["self-removing"], waits: 1 },
    { name: "both", supervisors: ["supervisor"], children: ["child"], waits: 1 }
];
for (let test in cases) {
    files = { "owned/pid": test.supervisors, "owned/child-pid": test.children,
              "external/pid": ["manager"] };
    calls = [];
    stop_runtime(cfg);
    let waits = 0;
    let term = 0;
    let force = 0;
    for (let call in calls) {
        if (call[0] == "sleep") { waits++; if (call[1] != "1") die("wrong grace period\n"); }
        if (call[0] != "kill") continue;
        if (call[1] == "manager") die("external process touched\n");
        if (call[2] == "") { if (waits > 0) die("TERM after wait\n"); term++; }
        if (call[2] == "9") { if (waits != 1) die("KILL without grace period\n"); force++; }
    }
    let tracked = length(test.supervisors || []) + length(test.children || []);
    if (waits != test.waits || term != tracked) die("wrong shutdown: " + test.name + "\n");
    if (force != tracked - (test.name == "TERM removes child PID file" ? 1 : 0)) die("wrong final rescan\n");
    if (calls[length(calls)-1][0] != "rm") die("cleanup skipped\n");
    print("PASS: ", test.name, "\n");
}
UCODE
  } | ucode -
  printf '%s shutdown checks passed\n' "$provider"
done