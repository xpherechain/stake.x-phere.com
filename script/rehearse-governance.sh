#!/usr/bin/env bash
# ============================================================
# Governance (Timelock) rehearsal — the one testnet path not yet
# exercised by rehearse.sh. Proves the mainnet parameter-change flow:
#   Safe → Timelock.schedule → wait(delay) → Timelock.execute
#
# Uses setStakeCap as the sample param (visible on the admin console),
# changes 100,000 → 120,000, verifies, then reverts to 100,000 so the
# testnet state stays consistent with docs.
#
# Required env:
#   RPC   testnet RPC   PK   deployer key (== Safe on testnet)
#   VAULT Vault addr    TL   Timelock addr
# ============================================================
set -euo pipefail
: "${RPC:?}"; : "${PK:?}"; : "${VAULT:?}"; : "${TL:?}"
DELAY=120
PRED=0x0000000000000000000000000000000000000000000000000000000000000000
e() { cast to-unit "$1" ether; }
cap() { cast call $VAULT "stakeCap()(uint256)" --rpc-url $RPC | awk '{print $1}'; }

change_cap() { # $1 = new cap in whole XP, $2 = salt
  local NEW_WEI SALT DATA
  NEW_WEI=$(cast to-wei "$1" ether)
  SALT=$2
  DATA=$(cast calldata "setStakeCap(uint256)" $NEW_WEI)
  echo "  schedule setStakeCap($1 XP) via Timelock (delay ${DELAY}s)…"
  cast send $TL "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
    $VAULT 0 $DATA $PRED $SALT $DELAY --rpc-url $RPC --private-key $PK >/dev/null
  local OPHASH READY
  OPHASH=$(cast call $TL "hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)" \
    $VAULT 0 $DATA $PRED $SALT --rpc-url $RPC | awk '{print $1}')
  READY=$(cast call $TL "isOperationPending(bytes32)(bool)" $OPHASH --rpc-url $RPC | awk '{print $1}')
  echo "  op=$OPHASH pending=$READY  waiting ${DELAY}s+ … $(date +%H:%M:%S)"
  sleep $((DELAY + 15))
  echo "  execute … $(date +%H:%M:%S)"
  cast send $TL "execute(address,uint256,bytes,bytes32,bytes32)" \
    $VAULT 0 $DATA $PRED $SALT --rpc-url $RPC --private-key $PK >/dev/null
  echo "  stakeCap now: $(e $(cap)) XP"
}

echo "════════ GOVERNANCE (TIMELOCK) REHEARSAL ════════"
echo "vault=$VAULT  timelock=$TL"
echo "before: stakeCap = $(e $(cap)) XP"
echo
echo "[1] forward change 100000 → 120000"
change_cap 120000 0x1111111111111111111111111111111111111111111111111111111111111111
echo
echo "[2] revert 120000 → 100000 (keep testnet consistent with docs)"
change_cap 100000 0x2222222222222222222222222222222222222222222222222222222222222222
echo
echo "════════ DONE ════════"
echo "final: stakeCap = $(e $(cap)) XP  (should be 100000)"
echo "→ Safe→Timelock.schedule→wait→execute 파라미터 변경 경로 테스트넷 검증 완료."
