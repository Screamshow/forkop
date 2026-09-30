#!/bin/sh
# VM-only Forkop init wrapper: fail the first start of extended, then allow
# the rollback to use the real init script. Requires a dedicated marker path.
set -eu
marker="${FORKOP_TEST_START_FAILURE_MARKER:?missing test marker}"
if [ "${1:-}" = start ] && [ ! -e "$marker" ]; then
  case "$(sing-box version | head -n 1)" in
    *extended*)
      : >"$marker"
      echo 'injected extended startup failure' >&2
      exit 42
      ;;
  esac
fi
exec /etc/init.d/forkop "$@"
