#!/usr/bin/env bash
# ============================================================
# 매일 1회: 전용 수령 지갑 → Distributor 스윕 후 settle().
# 경로 B(전용 EOA) 운영자용 메인 스크립트.
#   - 경로 A(프로토콜이 Distributor로 직접 지급)면 COLLECTOR_PK를 비워두면
#     스윕 단계를 건너뛰고 settle만 수행한다.
#   - settle은 permissionless라 실패해도 자금 유실 없음(다음 실행/누구나 재호출).
#   - 정산 성공/실패는 Slack(SLACK_WEBHOOK)·Telegram(TG_*)으로 알림.
# 사용: ops/daily-settle.sh   (crontab 에서 호출)
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"
set -a; source ./.env; set +a
: "${RPC:?}"; : "${DIST:?}"
log() { echo "[$(date -u +%FT%TZ)] $*"; }
nl=$'\n'

notify() { # $1 = multiline message
  if [ -n "${SLACK_WEBHOOK:-}" ]; then
    SLACK_WEBHOOK="$SLACK_WEBHOOK" python3 - "$1" <<'PY' || true
import json, os, sys, urllib.request
req = urllib.request.Request(
    os.environ["SLACK_WEBHOOK"],
    json.dumps({"text": sys.argv[1]}).encode(),
    {"Content-Type": "application/json"},
)
urllib.request.urlopen(req, timeout=10)
PY
  fi
  if [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ]; then
    curl -s "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TG_CHAT}" --data-urlencode "text=$1" >/dev/null || true
  fi
}

# 1) 스윕 (경로 B: COLLECTOR_PK 있을 때만)
#    SWEEP_LIMIT_WEI = "에폭당 투입 예산" — 가드런치 정책 C(부분 스윕).
#    Distributor 대기 잔고가 예산에 찰 때까지만 채운다. settle이 하루 1번
#    잔고를 소진하므로 자연히 '하루 SWEEP_LIMIT_WEI'가 강제된다.
#    (크론이 2시간마다 돌아도 예산 초과 투입이 불가능)
SWEPT="0"
if [ -n "${COLLECTOR_PK:-}" ]; then
  COLLECTOR=$(cast wallet address --private-key "$COLLECTOR_PK")
  BAL=$(cast balance "$COLLECTOR" --rpc-url "$RPC")
  SWEEP=$(python3 -c "print(max(0, $BAL - ${GAS_RESERVE_WEI:-0}))")
  if [ -n "${SWEEP_LIMIT_WEI:-}" ]; then
    PEND_NOW=$(cast call "$DIST" "pendingSettlement()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
    SWEEP=$(python3 -c "print(min($SWEEP, max(0, ${SWEEP_LIMIT_WEI} - $PEND_NOW)))")
  fi
  # NOTE: wei amounts exceed bash's 64-bit integers — compare via python
  if python3 -c "exit(0 if int('$SWEEP') > 0 else 1)"; then
    log "sweep $(cast to-unit $SWEEP ether) XP  $COLLECTOR -> $DIST"
    if cast send "$DIST" --value "$SWEEP" --rpc-url "$RPC" --private-key "$COLLECTOR_PK" >/dev/null; then
      SWEPT=$(cast to-unit $SWEEP ether)
    else
      log "sweep FAILED"
      notify "🚨 [XP Vault] 스윕 실패 — 수령지갑→Distributor 전송 에러. 서버/가스 확인 필요."
    fi
  else
    log "sweep skip (collector balance <= gas reserve)"
  fi
fi

# 2) settle (에폭 경과 + minSettle 충족 시)
READ=$(cast call "$DIST" "canSettle()(bool,string)" --rpc-url "$RPC")
OK=$(echo "$READ" | head -1 | awk '{print $1}')
if [ "$OK" = "true" ]; then
  PEND=$(cast call "$DIST" "pendingSettlement()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
  B0=$(cast call $DIST 'totalBurned()(uint256)' --rpc-url $RPC | awk '{print $1}')
  D0=$(cast call $DIST 'totalDistributed()(uint256)' --rpc-url $RPC | awk '{print $1}')
  log "settle pending=$(cast to-unit $PEND ether) XP"
  if cast send "$DIST" "settle()" --rpc-url "$RPC" --private-key "${SETTLE_PK:-$COLLECTOR_PK}" >/dev/null; then
    B1=$(cast call $DIST 'totalBurned()(uint256)' --rpc-url $RPC | awk '{print $1}')
    D1=$(cast call $DIST 'totalDistributed()(uint256)' --rpc-url $RPC | awk '{print $1}')
    BURNED=$(python3 -c "print(($B1-$B0)/1e18)")
    DISTED=$(python3 -c "print(($D1-$D0)/1e18)")
    log "settled. burned=+$BURNED distributed=+$DISTED (lifetime burned $(cast to-unit $B1 ether) XP)"
    notify "🔥 [XP Vault] 에폭 정산 완료${nl}정산액: $(cast to-unit $PEND ether) XP${nl}→ 소각: $BURNED XP · 스테이커: $DISTED XP${nl}누적 소각: $(cast to-unit $B1 ether) XP"
    ./record-stats.sh || log "record-stats failed (non-fatal)"
  else
    log "settle FAILED"
    notify "🚨 [XP Vault] settle 실패 — 가스/RPC 확인 필요. (permissionless — 수동: ops/settle-only.sh)"
  fi
else
  log "settle skip: $(echo "$READ" | tail -1)"
fi
log "done"
