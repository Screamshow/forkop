#!/usr/bin/env bash
set -euo pipefail

# Kept as the legacy entrypoint used by local and downstream test runners.
# DNS rollback is transaction-based since 1.3.11-canary.2, so the previous
# assertions about forkop_server/forkop_noresolv backup options are obsolete.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec bash "$ROOT_DIR/tests/dns_rollback_transaction.sh"
