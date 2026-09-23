#!/bin/sh
# VM-only fault injector. Put a copy named "apk" first in PATH.
set -eu

if [ "${1:-}" = add ]; then
  for arg in "$@"; do
    [ "$arg" = --simulate ] && exec /usr/bin/apk "$@"
  done
  case "${FORKOP_TEST_APK_FAIL_MODE:-}" in
    target)
      for arg in "$@"; do
        case "$arg" in
          */sing-box-extended*.apk)
            printf '%s\n' 'injected package installation failure' >&2
            exit 42
            ;;
        esac
      done
      ;;
    tiny)
      for arg in "$@"; do
        case "$arg" in
          */sing-box-tiny-*.apk)
            printf '%s\n' 'injected tiny package installation failure' >&2
            exit 42
            ;;
        esac
      done
      ;;
    all)
      printf '%s\n' 'injected target and rollback installation failure' >&2
      exit 42
      ;;
  esac
fi

exec /usr/bin/apk "$@"
