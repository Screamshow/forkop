#!/bin/sh
set -eu

# Run on OpenWrt with a valid SRS fixture at the supplied path.
fixture="$1"
lib="${FORKOP_LIB:-/usr/lib/forkop}"
updates="${FORKOP_UPDATES_UC:-$lib/components/updates.uc}"
work="$(mktemp -d /tmp/forkop-srs-validation.XXXXXX)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/sing-box" <<'EOF'
#!/bin/sh
if [ "${1:-}" = rule-set ] && [ "${2:-}" = decompile ]; then
    printf '1\n' >> "$FORKOP_TEST_DECOMPILE_LOG"
fi
exec /usr/bin/sing-box "$@"
EOF
chmod +x "$work/bin/sing-box"
export FORKOP_TEST_DECOMPILE_LOG="$work/decompile.log"
export PATH="$work/bin:$PATH"

cp -R /etc/forkop/list-cache "$work/cache"
cp "$fixture" "$work/cache/source-99"
size="$(wc -c < "$work/cache/source-99")"
digest="$(md5sum "$work/cache/source-99" | cut -d ' ' -f 1)"
signature="$(ucode -L "$lib" "$lib/service/state.uc" list-update-signature)"
ucode -e 'let fs = require("fs"); let p = ARGV[0]; let m = json(fs.readfile(p)); m.signature = ARGV[3]; push(m.files, { name: "source-99", kind: "source", url: "https://test.invalid/fixture.srs", source_format: "srs", size: int(ARGV[1]), md5: ARGV[2] }); fs.writefile(p, sprintf("%J\n", m));' "$work/cache/manifest.json" "$size" "$digest" "$signature"

cache_valid() {
    FORKOP_LIB="$lib" \
    FORKOP_PERSISTENT_LIST_CACHE_DIR="$work/cache" \
    FORKOP_PERSISTENT_LIST_CACHE_MANIFEST="$work/cache/manifest.json" \
    FORKOP_LIST_SRS_VALIDATION_DIR="$work/validated" \
    ucode -L "$lib" "$updates" list-cache-valid
}

cache_valid
[ -f "$work/validated/$digest" ]
cache_valid
[ "$(wc -l < "$work/decompile.log")" -eq 1 ]
printf 'corrupt' >> "$work/cache/source-99"
if cache_valid; then
    echo 'corrupted SRS passed checksum validation' >&2
    exit 1
fi
cp "$work/cache/source-99" "$work/cache/source-100"
printf 'invalid SRS\n' > "$work/cache/source-100"
bad_size="$(wc -c < "$work/cache/source-100")"
bad_digest="$(md5sum "$work/cache/source-100" | cut -d ' ' -f 1)"
ucode -e 'let fs = require("fs"); let p = ARGV[0]; let m = json(fs.readfile(p)); m.files = filter(m.files, e => e.name != "source-99"); push(m.files, { name: "source-100", kind: "source", url: "https://test.invalid/bad.srs", source_format: "srs", size: int(ARGV[1]), md5: ARGV[2] }); fs.writefile(p, sprintf("%J\n", m));' "$work/cache/manifest.json" "$bad_size" "$bad_digest"
if cache_valid || [ -e "$work/validated/$bad_digest" ]; then
    echo 'invalid SRS was accepted or marked valid' >&2
    exit 1
fi
echo 'SRS validation cache and checksum rejection passed'
