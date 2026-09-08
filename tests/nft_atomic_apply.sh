#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
NFT_UC="$FORKOP_LIB/nft/apply.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/nft" <<'EOF_NFT'
#!/bin/sh
printf '%s\n' "$*" >>"$NFT_ATOMIC_LOG"
[ -n "${NFT_ATOMIC_CAPTURE:-}" ] && [ "$1" = "-f" ] && cat "$2" >>"$NFT_ATOMIC_CAPTURE"
[ "${NFT_ATOMIC_FAIL:-}" = "$1 $2" ] && exit 1
[ "$1" = "list" ] && exit 1
exit 0
EOF_NFT
chmod +x "$WORK_DIR/bin/nft"
printf '149.154.160.0/20\n2001:db8::/32\n' >"$WORK_DIR/telegram.txt"
: >"$WORK_DIR/nft.log"

PATH="$WORK_DIR/bin:$PATH" NFT_ATOMIC_LOG="$WORK_DIR/nft.log" \
FORKOP_NFT_BATCH_FILE="$WORK_DIR/candidate.nft" \
  ucode -L "$FORKOP_LIB" "$NFT_UC" nft-add-file-chunks-to-set \
    "$WORK_DIR/telegram.txt" ForkopTable forkop_subnets ips '' 5000
[ ! -s "$WORK_DIR/nft.log" ] || fail "candidate preparation touched active nft"
grep -Fq 'add element inet ForkopTable forkop_subnets { 149.154.160.0/20,2001:db8::/32 }' "$WORK_DIR/candidate.nft" ||
  fail "candidate lost Telegram IPv4 CIDR"

PATH="$WORK_DIR/bin:$PATH" NFT_ATOMIC_LOG="$WORK_DIR/nft.log" \
  ucode -L "$FORKOP_LIB" "$NFT_UC" nft-apply-candidate-batch "$WORK_DIR/candidate.nft"
[ "$(wc -l <"$WORK_DIR/nft.log")" -eq 2 ] || fail "candidate was not applied as one check/apply pair"
grep -Fxq -- "-c -f $WORK_DIR/candidate.nft" "$WORK_DIR/nft.log" || fail "candidate syntax check missing"
grep -Fxq -- "-f $WORK_DIR/candidate.nft" "$WORK_DIR/nft.log" || fail "candidate apply missing"

: >"$WORK_DIR/nft.log"
if PATH="$WORK_DIR/bin:$PATH" NFT_ATOMIC_LOG="$WORK_DIR/nft.log" FORKOP_NFT_CANDIDATE_FAIL_PHASE=prepare \
  FORKOP_NFT_BATCH_FILE="$WORK_DIR/prepare-failed.nft" \
  ucode -L "$FORKOP_LIB" "$NFT_UC" nft-add-file-chunks-to-set \
    "$WORK_DIR/telegram.txt" ForkopTable forkop_subnets ips '' 5000; then
  fail "injected candidate preparation failure was accepted"
fi
[ ! -s "$WORK_DIR/nft.log" ] || fail "preparation failure touched live nft"

: >"$WORK_DIR/nft.log"
if PATH="$WORK_DIR/bin:$PATH" NFT_ATOMIC_LOG="$WORK_DIR/nft.log" NFT_ATOMIC_FAIL='-c -f' \
  ucode -L "$FORKOP_LIB" "$NFT_UC" nft-apply-candidate-batch "$WORK_DIR/candidate.nft"; then
  fail "invalid candidate check was accepted"
fi
[ "$(wc -l <"$WORK_DIR/nft.log")" -eq 1 ] || fail "apply ran after failed candidate validation"

for phase in check apply; do
  : >"$WORK_DIR/nft.log"
  if PATH="$WORK_DIR/bin:$PATH" NFT_ATOMIC_LOG="$WORK_DIR/nft.log" FORKOP_NFT_CANDIDATE_FAIL_PHASE="$phase" \
    ucode -L "$FORKOP_LIB" "$NFT_UC" nft-apply-candidate-batch "$WORK_DIR/candidate.nft"; then
    fail "injected candidate $phase failure was accepted"
  fi
  if [ "$phase" = check ]; then
    [ ! -s "$WORK_DIR/nft.log" ] || fail "injected candidate check failure touched nft"
  else
    [ "$(wc -l <"$WORK_DIR/nft.log")" -eq 1 ] &&
      grep -Fxq -- "-c -f $WORK_DIR/candidate.nft" "$WORK_DIR/nft.log" ||
      fail "injected candidate apply failure did not stop before live apply"
  fi
done

# The cross-component guard is a separate, real nft transaction. It must not
# be appended to the final candidate: while sing-box changes generation, this
# hook drops marked protected packets before the TPROXY hook can deliver them
# to a process with a different route config.
: >"$WORK_DIR/nft.log"
: >"$WORK_DIR/guard.nft"
PATH="$WORK_DIR/bin:$PATH" NFT_ATOMIC_LOG="$WORK_DIR/nft.log" NFT_ATOMIC_CAPTURE="$WORK_DIR/guard.nft" \
  ucode -L "$FORKOP_LIB" "$NFT_UC" install-transition-guard ForkopTable 0x04000000
[ "$(wc -l <"$WORK_DIR/nft.log")" -eq 3 ] || fail "transition guard was not checked, presence-checked, and atomically applied"
grep -Fq 'add chain inet ForkopTable forkop_transition_guard { type filter hook prerouting priority -101; policy accept; }' "$WORK_DIR/guard.nft" ||
  fail "transition guard hook was not built"
grep -Fq 'meta mark & 0x04000000 == 0x04000000 counter drop' "$WORK_DIR/guard.nft" ||
  fail "transition guard does not fail closed for protected traffic"

printf 'transition guard checks passed\n'
printf 'atomic nft candidate checks passed\n'
