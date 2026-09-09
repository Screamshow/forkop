#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_UC="$ROOT_DIR/forkop/files/usr/lib/diagnostics/runtime.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# The report is an explicitly confidential artifact. Logging sanitization must
# never silently turn it into a masked diagnostic report.
grep -Fq 'global_check("raw", "raw")' "$RUNTIME_UC" ||
  fail "support report no longer requests raw global diagnostics"
grep -Fq 'show_sing_box_config("raw")' "$RUNTIME_UC" ||
  fail "support report no longer includes raw generated sing-box config"
grep -Fq 'support_report_file("/etc/config/forkop", FORKOP_CONFIG)' "$RUNTIME_UC" ||
  fail "support report no longer includes raw Forkop UCI config"
grep -Fq 'CONFIDENTIAL SUPPORT REPORT' "$RUNTIME_UC" ||
  fail "support report confidentiality warning is missing"

printf 'support report raw-data contract checks passed\n'
