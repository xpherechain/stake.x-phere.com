#!/usr/bin/env bash
# ============================================================
# 파트너별 유치 TVL 조회 (오프체인 커미션 정산의 온체인 근거).
# 사용: ops/partner-tvl.sh [추가슬러그...]
#   기본으로 ankr·nansen·DIRECT 표시, 인자로 슬러그 추가 조회 가능.
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"
set -a; source ./.env; set +a
: "${RPC:?}"; : "${VAULT:?}"

SLUGS=(ankr nansen "$@")
e() { cast to-unit "$1" ether; }
TOTAL=$(cast call "$VAULT" "totalAssets()(uint256)" --rpc-url "$RPC" | awk '{print $1}')

printf "%-22s %16s %8s\n" "PARTNER" "TVL(XP)" "SHARE"
printf "%s\n" "------------------------------------------------"
sum=0
for s in "${SLUGS[@]}"; do
  PID=$(cast keccak "$s")
  T=$(cast call "$VAULT" "partnerTVL(bytes32)(uint256)" "$PID" --rpc-url "$RPC" | awk '{print $1}')
  PCT=$(awk "BEGIN{printf \"%.2f%%\", ($T)/($TOTAL+0.000001)*100}")
  printf "%-22s %16s %8s\n" "$s" "$(e $T)" "$PCT"
done
DPID=$(cast keccak "DIRECT")
DT=$(cast call "$VAULT" "partnerTVL(bytes32)(uint256)" "$DPID" --rpc-url "$RPC" | awk '{print $1}')
printf "%-22s %16s %8s\n" "(direct)" "$(e $DT)" "$(awk "BEGIN{printf \"%.2f%%\", ($DT)/($TOTAL+0.000001)*100}")"
printf "%s\n" "------------------------------------------------"
printf "%-22s %16s\n" "TOTAL TVL" "$(e $TOTAL)"
