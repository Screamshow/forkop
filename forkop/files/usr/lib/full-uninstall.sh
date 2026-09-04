#!/bin/sh
set -eu
umask 077

# An optional filesystem root is used only by the isolated regression tests.
ROOT="${FORKOP_UNINSTALL_ROOT:-}"
if [ -n "$ROOT" ]; then ROOT="$(cd "$ROOT" && pwd -P)"; fi
MIRROR="${FORKOP_MIRROR_BASE_URL:-}"
if [ -z "$MIRROR" ]; then MIRROR="$(uci -q get forkop.settings.mirror_base_url 2>/dev/null || true)"; fi
MIRROR="${MIRROR:-https://mirror.51343.ru}"
BIN="$ROOT/usr/bin/forkop"
LOCK="$ROOT/tmp/forkop-full-uninstall.lock"
COMPONENT_LOCK="$ROOT/var/run/forkop/component-action.lock"
PACKAGES="luci-i18n-forkop-ru luci-app-forkop forkop sing-box sing-box-tiny sing-box-extended"
PHASE=preflight

has_mirror() {
    grep -Fq "${MIRROR%/}/" "$1" || grep -Fq 'mirror.51343.ru/' "$1"
}

repository_plan() {
    : > "$JOB/repositories"
    for file in "$ROOT/etc/opkg/distfeeds.conf" "$ROOT/etc/opkg/customfeeds.conf" \
        "$ROOT/etc/apk/repositories" "$ROOT"/etc/apk/repositories.d/*.list; do
        [ -f "$file" ] || continue
        [ "$file" != "$ROOT/etc/apk/repositories.d/forkop.list" ] || continue
        source="${file}.pre-forkop-mirror"
        if [ -f "$source" ] && ! has_mirror "$source"; then
            :
        elif has_mirror "$file"; then
            source="$ROOT/rom${file#"$ROOT"}"
            if [ ! -f "$source" ] || has_mirror "$source"; then
                echo "Cannot restore original repositories: $file" >&2
                return 1
            fi
        else
            continue
        fi
        printf '%s|%s\n' "$file" "$source" >> "$JOB/repositories"
    done
}

installed() {
    if [ "$MANAGER" = apk ]; then apk info -e "$1" >/dev/null 2>&1
    else opkg status "$1" 2>/dev/null | grep -q '^Status: .* installed$'; fi
}

state() {
    printf '{"state":"%s","phase":"%s"}\n' "$1" "$PHASE" > "$STATUS.new"
    chmod 644 "$STATUS.new"
    mv "$STATUS.new" "$STATUS"
}

finish() {
    code=$?
    trap - EXIT
    if [ "$code" -ne 0 ]; then state failed; fi
    rm -f "$COMPONENT_LOCK/pid"
    rmdir "$COMPONENT_LOCK" 2>/dev/null || true
    rm -f "$LOCK/pid"
    rmdir "$LOCK" 2>/dev/null || true
    # A short-lived, non-sensitive status file remains readable after LuCI is
    # uninstalled, so the browser never has to guess whether removal succeeded.
    (sleep 300; rm -f "$STATUS" "$STATUS.new") </dev/null >/dev/null 2>&1 &
    exit "$code"
}

run() {
    trap finish EXIT
    state running
    repository_plan
    if command -v apk >/dev/null 2>&1; then MANAGER=apk
    elif command -v opkg >/dev/null 2>&1; then MANAGER=opkg
    else return 1; fi

    PHASE=stop
    state running
    if [ -x "$ROOT/etc/init.d/forkop" ]; then
        "$ROOT/etc/init.d/forkop" stop
        "$ROOT/etc/init.d/forkop" disable
    fi
    if [ -x "$BIN" ]; then "$BIN" dnsmasq_restore; fi
    if [ -x "$ROOT/etc/init.d/sing-box" ]; then
        "$ROOT/etc/init.d/sing-box" stop
        "$ROOT/etc/init.d/sing-box" disable
    fi

    PHASE=repositories
    state running
    while IFS='|' read -r file source; do
        cp "$source" "$file.forkop-restore"
        chmod 644 "$file.forkop-restore"
        mv "$file.forkop-restore" "$file"
    done < "$JOB/repositories"
    rm -f "$ROOT/etc/apk/repositories.d/forkop.list" "$ROOT/etc/apk/keys/forkop-mirror.pem"

    PHASE=packages
    state running
    set --
    for package in $PACKAGES; do
        if installed "$package"; then set -- "$@" "$package"; fi
    done
    if [ "$#" -gt 0 ]; then
        if [ "$MANAGER" = apk ]; then apk del "$@"
        else opkg remove "$@"; fi
    fi
    for package in $PACKAGES; do
        if installed "$package"; then echo "Package was not removed: $package" >&2; return 1; fi
    done

    PHASE=files
    state running
    # Only known product paths are removed. Never recursively delete a path
    # supplied by a UCI option (it might point at /etc or other system data).
    for directory in /etc/forkop /etc/sing-box /tmp/sing-box /usr/lib/forkop \
        /usr/share/forkop /www/luci-static/resources/view/forkop; do
        rm -rf "$ROOT$directory"
    done
    for file in /etc/config/forkop /etc/config/sing-box /etc/config/forkop-opkg \
        /etc/config/sing-box-opkg /usr/bin/forkop /usr/bin/sing-box /usr/lib/libcronet.so \
        /etc/init.d/forkop /etc/init.d/sing-box /etc/uci-defaults/50_luci-forkop \
        /usr/share/luci/menu.d/luci-app-forkop.json /usr/share/rpcd/acl.d/luci-app-forkop.json; do
        rm -f "$ROOT$file"
    done
    for file in "$ROOT"/usr/lib/lua/luci/i18n/forkop.* \
        "$ROOT"/tmp/luci-indexcache* "$ROOT"/tmp/luci-modulecache/*; do
        [ ! -f "$file" ] || rm -f "$file"
    done
    while IFS='|' read -r file source; do
        rm -f "${file}.pre-forkop-mirror"
    done < "$JOB/repositories"
    # Leave the component lock intact until finish() releases it.
    for item in "$ROOT"/var/run/forkop/*; do
        [ "$item" = "$COMPONENT_LOCK" ] || rm -rf "$item"
    done
    PHASE=complete
    state complete
}

case "${1:-}" in
    start)
        mkdir -p "$ROOT/tmp" "$ROOT/www" "$ROOT/var/run/forkop"
        if ! mkdir "$LOCK" 2>/dev/null; then
            echo '{"success":false,"message":"Removal is already running"}'
            exit 1
        fi
        if ! mkdir "$COMPONENT_LOCK" 2>/dev/null; then
            rmdir "$LOCK"
            echo '{"success":false,"message":"Another component action is running"}'
            exit 1
        fi
        trap 'rm -f "$LOCK/pid" "$COMPONENT_LOCK/pid"; rmdir "$LOCK" "$COMPONENT_LOCK" 2>/dev/null || true' EXIT
        printf '%s\n' "$$" > "$LOCK/pid"
        printf '%s\n' "$$" > "$COMPONENT_LOCK/pid"
        JOB="$(mktemp -d "$ROOT/tmp/forkop-uninstall.XXXXXX")"
        STATUS="$ROOT/www/$(basename "$JOB").json"
        cp "$0" "$JOB/worker.sh"
        state running
        sh "$JOB/worker.sh" worker "$JOB" "$STATUS" > "$JOB/output.log" 2>&1 </dev/null 1000>&- &
        trap - EXIT
        printf '{"success":true,"status_url":"/%s.json"}\n' "$(basename "$JOB")"
        ;;
    worker)
        JOB="$2"
        STATUS="$3"
        printf '%s\n' "$$" > "$LOCK/pid"
        printf '%s\n' "$$" > "$COMPONENT_LOCK/pid"
        run
        ;;
    *) exit 2 ;;
esac
