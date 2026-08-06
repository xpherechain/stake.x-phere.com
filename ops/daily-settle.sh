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

ZERO=0x0000000000000000000000000000000000000000
# 설정 유효성 검증: 플레이스홀더/빈 값이면 조용히 죽지 말고 경보 후 중단.
# (.env 가 .env.example 로 덮어써지면 모든 스크립트가 무력화되므로 필수)
config_error=""
[ "${DIST:-}" = "$ZERO" ] && config_error="DIST가 플레이스홀더(0x0)"
[ "${VAULT:-$ZERO}" = "$ZERO" ] && config_error="${config_error:+$config_error, }VAULT가 플레이스홀더(0x0)"
[ -z "${SETTLE_PK:-}" ] && [ -z "${COLLECTOR_PK:-}" ] && \
  config_error="${config_error:+$config_error, }서명 키가 모두 비어 있음"

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

if [ -n "$config_error" ]; then
  log "CONFIG ERROR: $config_error — 중단"
  notify "🚨 [XP Vault] 설정 오류로 정산 중단${nl}${config_error}${nl}ops/.env 확인 필요 (.env.example 로 덮어써졌을 가능성)"
  exit 1
fi

# 1) 스윕 (경로 B: COLLECTOR_PK 있을 때만)
#    SWEEP_LIMIT_WEI = "에폭당 투입 예산" — 부분 스윕 모드.
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
#    SETTLE_HOUR_UTC 설정 시 "그 시각 이후 그날의 첫 기회"에만 정산한다
#    (예: 0 → 매일 00:00 UTC = 09:00 KST 이후 첫 슬롯). 특정 슬롯에만
#    한정하면 tx 체결이 몇 초 늦어질 때 그날을 통째로 건너뛰므로,
#    시각 하한 + 하루 1회 조건으로 판정한다. 비우면 매 슬롯 시도.
if [ -n "${SETTLE_HOUR_UTC:-}" ]; then
  now_h=$(date -u +%-H)
  today=$(date -u +%F)
  last_ts=$(cast call "$DIST" "lastSettlement()(uint64,uint256,uint256,uint256)" --rpc-url "$RPC" \
            | sed -n 1p | awk '{print $1}')
  last_day=$(date -u -d "@$last_ts" +%F 2>/dev/null || date -u -r "$last_ts" +%F)
  if [ "$now_h" -lt "$SETTLE_HOUR_UTC" ] || [ "$last_day" = "$today" ]; then
    log "settle deferred (anchor ${SETTLE_HOUR_UTC}:00 UTC, last settled $last_day)"
    log "done"
    exit 0
  fi
fi
#    드리프트 방지: 정산 tx가 크론 시작보다 몇 초 늦게 체결되므로, 다음날
#    크론은 항상 몇 초 못 미쳐 스킵하고 정산이 매일 한 슬롯(2h)씩 밀린다.
#    가능 시각이 5분 이내로 임박했으면 그만큼 기다렸다가 진행한다.
NEXT_TS=$(cast call "$DIST" "nextSettleTime()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
NOW_TS=$(date -u +%s)
WAIT=$((NEXT_TS - NOW_TS))
if [ "$WAIT" -gt 0 ] && [ "$WAIT" -le 300 ]; then
  log "settle eligible in ${WAIT}s — waiting"
  sleep $((WAIT + 3))
fi
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
