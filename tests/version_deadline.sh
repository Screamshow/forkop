#!/bin/sh
set -eu
ROOT="${FORKOP_TEST_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
SOURCE="${FORKOP_TEST_VALIDATOR:-$ROOT/forkop/files/usr/lib/config/validator.uc}"
WORK=$(mktemp -d /tmp/forkop-version-deadline.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
{
    printf '%s\n' 'let fs = require("fs"); function as_string(v) { return v == null ? "" : "" + v; }'
    sed -n '/^function shell_quote(/,/^}/p; /^function command_from_args(/,/^}/p; /^function command_output(/,/^}/p; /^function command_output_from_args(/,/^}/p; /^function bounded_command_output_from_args(/,/^}/p' "$SOURCE"
    cat <<'UCODE'
let fast = ARGV[0];
let hang = ARGV[1];
let pidfile = ARGV[2];
let began = clock(true);
let value = bounded_command_output_from_args([fast, "literal ' quote; $(touch /not-executed)"], 2);
let ended = clock(true);
let elapsed = ended[0]-began[0]+(ended[1]-began[1])/1000000000;
if (value != "literal ' quote; $(touch /not-executed)\n" || elapsed > 0.8) die("fast response or quoting failed\n");
if (bounded_command_output_from_args([fast, "error"], 2) != "") die("failed command output accepted\n");
began = clock(true);
if (bounded_command_output_from_args([hang, pidfile], 1) != "") die("partial timed-out output accepted\n");
ended = clock(true);
elapsed = ended[0]-began[0]+(ended[1]-began[1])/1000000000;
if (elapsed < 0.9 || elapsed > 2) die("deadline failed\n");
let pid = trim(fs.readfile(pidfile));
if (fs.stat("/proc/"+pid) != null) die("timed-out child survived or was not reaped\n");
print("Version deadline checks passed: fast result, literal arguments, failure, timeout, child cleanup\n");
UCODE
} > "$WORK/check.uc"
printf '#!/bin/sh\n[ "$1" != error ] || { echo partial; exit 3; }\nprintf "%%s\\n" "$1"\n' > "$WORK/fast"
printf '#!/bin/sh\necho $$ > "$1"\necho partial\nexec sleep 30\n' > "$WORK/hang"
chmod +x "$WORK/fast" "$WORK/hang"
ucode "$WORK/check.uc" "$WORK/fast" "$WORK/hang" "$WORK/pid"