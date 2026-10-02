#!/bin/sh
set -eu
umask 077
dir=${FORKOP_SUPPORT_DIR:-/var/run/forkop/support}
daemon_pid=
auth_pid=
phase=stopped
error=
free_kib=0
required_kib=0
uptime_seconds() { cut -d. -f1 /proc/uptime; }
deadline=$(( $(uptime_seconds) + ${FORKOP_SUPPORT_TTL:-1800} ))
state() {
    printf '{"phase":"%s","deadline":%s,"error":"%s","free_kib":%s,"required_kib":%s}\n' "$phase" "$deadline" "$error" "$free_kib" "$required_kib" > "$dir/status.new"
    mv "$dir/status.new" "$dir/status.json"
}
cleanup() {
    trap - EXIT TERM INT
    case "$phase" in starting|connected) phase=stopped;; esac
    state
    # Revoke SSH authorization before closing the support transport.
    ucode /usr/lib/forkop/support/ssh-access.uc remove >/dev/null 2>&1 || true
    [ -z "$auth_pid" ] || kill "$auth_pid" 2>/dev/null || true
    [ -z "$daemon_pid" ] || kill "$daemon_pid" 2>/dev/null || true
    [ -z "$daemon_pid" ] || wait "$daemon_pid" 2>/dev/null || true
    rm -f "$dir/auth.key" "$dir/socket" "$dir/operation"
    rmdir "$dir/lock" 2>/dev/null || true
    state
}
trap cleanup EXIT
trap 'phase=stopped; exit 0' TERM INT
if [ "$(cat "$dir/operation")" = remove ]; then
    phase=removing; state
    # Recheck immediately before the transaction; never stop another instance.
    if /etc/init.d/tailscale enabled >/dev/null 2>&1; then
        phase=failed; error='Stop and disable the existing Tailscale service before removing it'; exit 1
    fi
    for proc in /proc/[0-9]*/cmdline; do
        args=$(tr '\000' ' ' < "$proc" 2>/dev/null) || continue
        executable=${args%% *}
        case "${executable##*/}" in
            tailscaled) phase=failed; error='Stop and disable the existing Tailscale service before removing it'; exit 1;;
        esac
    done
    if command -v apk >/dev/null 2>&1; then
        apk del tailscale >/dev/null 2>&1 || { phase=failed; error='Tailscale removal failed'; exit 1; }
    else
        opkg remove tailscale >/dev/null 2>&1 || { phase=failed; error='Tailscale removal failed'; exit 1; }
    fi
    phase=stopped; exit 0
fi
if [ "$(cat "$dir/operation")" = install ]; then
    : > "$dir/package.log"
    phase=installing; state
    # Only provision an absent installation. Never upgrade or stop a user's client.
    if command -v tailscale >/dev/null 2>&1 || command -v tailscaled >/dev/null 2>&1; then
        phase=failed; error='An existing Tailscale installation needs manual repair'; exit 1
    fi
    # Check the filesystem containing the binaries, including extroot setups.
    # Reserve 4 MiB for dependencies/metadata; unknown package size uses 28 MiB.
    free_kib=$(df -Pk /usr/bin | awk 'END { print $4 }')
    case "$free_kib" in ''|*[!0-9]*) phase=failed; error='Unable to check free storage'; free_kib=0; exit 1;; esac
    package_bytes=29360128
    if ! command -v apk >/dev/null 2>&1; then
        indexed_bytes=$(opkg info tailscale 2>/dev/null | awk '/^Installed-Size:/ {print $2; exit}')
        case "$indexed_bytes" in ''|*[!0-9]*|0) ;; *) package_bytes=$indexed_bytes;; esac
    fi
    required_kib=$(( (package_bytes + 1023) / 1024 + 4096 ))
    if [ "$free_kib" -lt "$required_kib" ]; then
        phase=failed; error='Not enough free storage to install Tailscale'; exit 1
    fi
    state
    if command -v apk >/dev/null 2>&1; then
        apk add tailscale > "$dir/package.log" 2>&1 || { phase=failed; error='Tailscale installation failed'; exit 1; }
    else
        opkg update > "$dir/package.log" 2>&1 && opkg install tailscale >> "$dir/package.log" 2>&1 || { phase=failed; error='Tailscale installation failed'; exit 1; }
    fi
    # Package installation can automatically start its standard service.
    /etc/init.d/tailscale stop >/dev/null 2>&1 || true
    /etc/init.d/tailscale disable >/dev/null 2>&1 || true
    phase=stopped; exit 0
fi
[ -s "$dir/auth.key" ] || { phase=failed; error='Missing temporary auth key'; exit 1; }
phase=starting; state
tailscaled --tun=userspace-networking --state=mem: --statedir="$dir" --socket="$dir/socket" --port=0 --no-logs-no-support >/dev/null 2>&1 &
daemon_pid=$!
count=0
while [ ! -S "$dir/socket" ]; do
    kill -0 "$daemon_pid" 2>/dev/null || { phase=failed; error='Tailscale failed to start'; exit 1; }
    count=$((count + 1)); [ "$count" -lt 15 ] || { phase=failed; error='Tailscale startup timed out'; exit 1; }
    sleep 1
done
# Credentials only enter tailscale via a root-readable file, never argv.
tailscale --socket="$dir/socket" up --hostname="forkop-support-$(cat /proc/sys/kernel/hostname)" --accept-dns=false --accept-routes=false --netfilter-mode=off --auth-key="file:$dir/auth.key" --timeout=60s >/dev/null 2>&1 &
auth_pid=$!
auth_deadline=$(( $(uptime_seconds) + 60 ))
[ "$auth_deadline" -le "$deadline" ] || auth_deadline=$deadline
while kill -0 "$auth_pid" 2>/dev/null; do
    if [ "$(uptime_seconds)" -ge "$auth_deadline" ]; then
        phase=failed; error='Tailscale authorization failed or timed out'; exit 1
    fi
    sleep 1
done
if ! wait "$auth_pid"; then
    auth_pid=; phase=failed; error='Tailscale authorization failed or timed out'; exit 1
fi
auth_pid=
rm -f "$dir/auth.key"
ucode /usr/lib/forkop/support/ssh-access.uc add >/dev/null 2>&1 || { phase=failed; error='Temporary SSH authorization failed'; exit 1; }
phase=connected; state
while [ "$(uptime_seconds)" -lt "$deadline" ]; do
    kill -0 "$daemon_pid" 2>/dev/null || { phase=failed; error='Tailscale connection process exited'; exit 1; }
    sleep 1
done
phase=stopped
