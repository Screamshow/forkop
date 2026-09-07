#!/usr/bin/env bash
set -euo pipefail

UCODE_VERSION="v0.0.20250529"
SING_BOX_VERSION="1.13.4"
LOCAL_PREFIX="${HOME}/.local"

for command_name in cmake cc git curl tar node; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$command_name" >&2
    printf 'Install the Ubuntu build prerequisites, then rerun this script.\n' >&2
    exit 1
  }
done

mkdir -p "$LOCAL_PREFIX/bin" "$LOCAL_PREFIX/lib"

if ! LD_LIBRARY_PATH="$LOCAL_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  "$LOCAL_PREFIX/bin/ucode" -e 'exit(0)' >/dev/null 2>&1; then
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' EXIT
  git clone --depth 1 --branch "$UCODE_VERSION" https://github.com/jow-/ucode.git "$work_dir/ucode"
  cmake -S "$work_dir/ucode" -B "$work_dir/ucode/build" \
    -DCMAKE_INSTALL_PREFIX="$LOCAL_PREFIX" \
    -DUBUS_SUPPORT=OFF -DUCI_SUPPORT=OFF -DULOOP_SUPPORT=OFF
  cmake --build "$work_dir/ucode/build" --parallel
  cmake --install "$work_dir/ucode/build"
fi

if ! "$LOCAL_PREFIX/bin/sing-box" version 2>/dev/null | grep -Fq "sing-box version $SING_BOX_VERSION"; then
  architecture="$(uname -m)"
  case "$architecture" in
    x86_64) archive_arch="amd64" ;;
    aarch64) archive_arch="arm64" ;;
    *) printf 'Unsupported WSL architecture: %s\n' "$architecture" >&2; exit 1 ;;
  esac
  archive="$(mktemp)"
  extract_dir="$(mktemp -d)"
  curl -fL --retry 3 -o "$archive" \
    "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${archive_arch}.tar.gz"
  tar -xzf "$archive" -C "$extract_dir"
  install -m 0755 \
    "$extract_dir/sing-box-${SING_BOX_VERSION}-linux-${archive_arch}/sing-box" \
    "$LOCAL_PREFIX/bin/sing-box"
  rm -f "$archive"
  rm -rf "$extract_dir"
fi

printf 'WSL backend environment is ready.\n'
LD_LIBRARY_PATH="$LOCAL_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$LOCAL_PREFIX/bin/ucode" -e 'print("ucode: ready\n")'
"$LOCAL_PREFIX/bin/sing-box" version | sed -n '1p'
node --version
