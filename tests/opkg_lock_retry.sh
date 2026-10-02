#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
{
cat <<'UCODE'
let last_logged_output = "";
let calls = 0;
let waits = 0;
let failures = 0;
let output = "";
function init_tmp_dir() {}
function make_tmp_file(name) { return "mock-output"; }
function owner_pid() { return 1; }
function updates_log(message, level) {}
function as_string(value) { return "" + value; }
function shell_quote(value) { return value; }
function command_status(command) { calls++; return calls <= failures ? 255 : 0; }
function read_file(path) { return calls <= failures ? output : "success"; }
function remove_file(path) {}
function command_success_from_args(args) {
    assert(args[0] == "sleep" && args[1] == "2", "unexpected command");
    waits++;
    return true;
}
UCODE
sed -n '/^function run_logged(description, command) {/,/^}/p' "$ROOT/forkop/files/usr/lib/components/action.uc"
cat <<'UCODE'
output = "opkg_conf_load: Could not lock /var/lock/opkg.lock: Resource temporarily unavailable.";
failures = 2;
assert(run_logged("install", "opkg install mock"), "transient lock did not recover");
assert(calls == 3 && waits == 2 && last_logged_output == "success", "incorrect retry state");
calls = 0; waits = 0; failures = 100;
assert(!run_logged("install", "opkg install mock"), "persistent lock accepted");
assert(calls == 16 && waits == 15, "retry bound incorrect");
calls = 0; waits = 0;
output = "postinst failed";
assert(!run_logged("install", "opkg install mock"), "hook error accepted");
assert(calls == 1 && waits == 0, "hook error retried");
calls = 0; waits = 0; failures = 0;
assert(run_logged("install", "opkg install mock"), "success rejected");
assert(calls == 1 && waits == 0, "success retried");
print("opkg lock retry tests passed\n");
UCODE
} | ucode -
