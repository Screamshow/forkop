#!/bin/sh
# Sourced by the support worker. Only the private Lite directory is provisioned.
install_lite() {
    lite=${FORKOP_SUPPORT_LITE_DIR:-/usr/lib/forkop-support}
    metadata=${FORKOP_SUPPORT_LITE_METADATA:-/usr/lib/forkop/support/lite.json}
    export FORKOP_SUPPORT_LITE_METADATA="$metadata"
    values=$(ucode -e 'let fs = require("fs"); let m = json(fs.readfile(getenv("FORKOP_SUPPORT_LITE_METADATA"))); let p = fs.popen("uname -m", "r"); let arch = trim(p.read("all")); p.close(); let a = m.assets[arch]; if (!a || !match(a.sha256, /^[0-9a-f]{64}$/) || a.size < 1 || !match(a.url, /^https:\/\/mirror\.51343\.ru\/forkop\/support\/tailscale-lite\/[A-Za-z0-9._\/-]+$/)) die("Invalid Lite metadata"); printf("%s %s %d", a.url, a.sha256, a.size);' 2>> "$dir/package.log") || { error='Tailscale Lite is unavailable for this architecture'; return 1; }
    set -- $values
    url=$1 hash=$2 bytes=$3
    required_kib=$(( (bytes + 1023) / 1024 + 1024 ))
    free_kib=$(df -Pk "$(dirname "$lite")" | awk 'END {print $4}')
    case "$free_kib" in ''|*[!0-9]*) free_kib=0; error='Unable to check free storage'; return 1;; esac
    if [ "$free_kib" -lt "$required_kib" ]; then error='Not enough free storage to install Tailscale'; return 1; fi
    state
    # The download lives in RAM; require space there before fetching it.
    tmp_kib=$(df -Pk "$dir" | awk 'END {print $4}')
    memory_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    case "$tmp_kib:$memory_kib" in *[!0-9:]*|:|*:|:*) error='Unable to check free memory'; return 1;; esac
    if [ "$tmp_kib" -lt "$(( (bytes + 1023) / 1024 ))" ] || [ "$memory_kib" -lt "$(( (bytes + 1023) / 1024 + 8192 ))" ]; then
        error='Not enough free memory to download Tailscale Lite'; return 1
    fi
    if [ -e "$lite" ] || [ -L "$lite" ]; then error='The Tailscale Lite directory already exists'; return 1; fi
    download="$dir/lite.download"
    if ! curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 180 --max-filesize "$bytes" -o "$download" "$url" >> "$dir/package.log" 2>&1; then
        rm -f "$download"; error='Tailscale Lite download failed'; return 1
    fi
    if [ "$(wc -c < "$download")" -ne "$bytes" ] || [ "$(sha256sum "$download" | cut -d' ' -f1)" != "$hash" ]; then
        rm -f "$download"; error='Tailscale Lite verification failed'; return 1
    fi
    # Check again after download; no system Tailscale files are changed.
    free_kib=$(df -Pk "$(dirname "$lite")" | awk 'END {print $4}')
    case "$free_kib" in ''|*[!0-9]*) free_kib=0; rm -f "$download"; error='Unable to check free storage'; return 1;; esac
    if [ "$free_kib" -lt "$required_kib" ]; then rm -f "$download"; error='Not enough free storage to install Tailscale'; return 1; fi
    if ! mkdir "$lite"; then rm -f "$download"; error='Cannot create Tailscale Lite directory'; return 1; fi
    lite_installing=1
    if ! cp "$download" "$lite/tailscale.combined" || ! chmod 755 "$lite" "$lite/tailscale.combined" ||
        ! ln -s tailscale.combined "$lite/tailscale" || ! ln -s tailscale.combined "$lite/tailscaled"; then
        rm -f "$download" "$lite/tailscale" "$lite/tailscaled" "$lite/tailscale.combined"
        rmdir "$lite" 2>/dev/null || true
        error='Tailscale Lite installation failed'; return 1
    fi
    if ! printf 'forkop-tailscale-lite\n' > "$lite/.forkop-lite"; then
        error='Tailscale Lite installation failed'; return 1
    fi
    lite_installing=0
    rm -f "$download"
}
