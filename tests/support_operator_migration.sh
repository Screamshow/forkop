#!/bin/sh
# Run against candidate modules with LIB=/tmp/.../usr/lib/forkop.
set -eu
lib=${LIB:-/usr/lib/forkop}
dir=$(mktemp -d /tmp/forkop-peer-migration.XXXXXX)
trap 'rm -rf "$dir"' EXIT
for scenario in missing empty disabled custom; do
    case "$scenario" in
        missing) settings='{}'; expected=100.114.74.44;;
        empty) settings='{"support_operator_ip":""}'; expected=;;
        disabled) settings='{"support_operator_ip":"disabled"}'; expected=disabled;;
        custom) settings='{"support_operator_ip":"100.100.100.100"}'; expected=100.100.100.100;;
    esac
    printf '{"settings":%s}' "$settings" > "$dir/input.json"
    FORKOP_LIB="$lib" ucode -L "$lib" "$lib/config/migration.uc" migrate-fixture "$dir/input.json" > "$dir/output.json"
    EXPECTED="$expected" ucode -e 'let fs=require("fs"); let r=json(fs.readfile(ARGV[0])); assert(r.config.settings.support_operator_ip == getenv("EXPECTED")); assert(index(r.config.settings.applied_migrations,"support_operator_ip_v1") >= 0); fs.writefile(ARGV[1],sprintf("%J",r.config));' "$dir/output.json" "$dir/again.json"
    FORKOP_LIB="$lib" ucode -L "$lib" "$lib/config/migration.uc" migrate-fixture "$dir/again.json" > "$dir/repeat.json"
    ucode -e 'let r=json(require("fs").readfile(ARGV[0])); assert(!r.changed); assert(length(r.operations)==0);' "$dir/repeat.json"
    echo "$scenario: migration and repeat passed"
done
