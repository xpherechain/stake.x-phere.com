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
# foundry(cast)를 어떤 실행 환경에서도 찾도록 PATH 보강
# (cron, sudo -u 는 로그인 셸을 거치지 않아 ~/.foundry/bin 이 빠진다)
export PATH="$PATH:$HOME/.foundry/bin:/home/xpops/.foundry/bin:/usr/local/bin"
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

  # 1a) 유니온 노드 입금.
  #     보상은 검증인 순번이 돌아올 때마다 589 XP씩 들어오므로, 유입 건마다
  #     알리면 하루 백 건을 넘는다. 그 빈도에서는 아무도 읽지 않고, 정작
  #     읽어야 할 실패 알림이 그 사이에 묻힌다.
  #
  #     대신 누적만 해두고 하루 한 번 합계로 보고한다. 개별 유입은 정상
  #     동작이라 알릴 가치가 없고, 이상 신호는 "들어와야 할 게 안 들어온
  #     것"인데 그건 합계로만 보인다.
  mkdir -p ./state
  LAST_BAL_FILE=./state/collector-balance.txt
  ACC_FILE=./state/inflow-accum.txt
  ACC_DAY_FILE=./state/inflow-day.txt
  if [ -f "$LAST_BAL_FILE" ]; then
    LAST_BAL=$(cat "$LAST_BAL_FILE")
    INFLOW=$(python3 -c "print(max(0, $BAL - $LAST_BAL))")
    if python3 -c "exit(0 if int('$INFLOW') > 0 else 1)"; then
      ACC=$(cat "$ACC_FILE" 2>/dev/null || echo 0)
      python3 -c "print($ACC + $INFLOW)" > "$ACC_FILE"
      log "node deposit +$(cast to-unit $INFLOW ether) XP (누적 $(cast to-unit $(cat $ACC_FILE) ether))"
    fi

    # 하루 한 번 합계 보고. 날짜가 바뀐 첫 실행에서만 나가므로 정확히 1건이다.
    TODAY=$(date -u +%F)
    if [ "$(cat "$ACC_DAY_FILE" 2>/dev/null)" != "$TODAY" ]; then
      ACC=$(cat "$ACC_FILE" 2>/dev/null || echo 0)
      if python3 -c "exit(0 if int('$ACC') >= int('${DEPOSIT_ALERT_WEI:-1000000000000000000000}') else 1)"; then
        notify "🟢 [XP Vault] 노드 보상 24시간 누적${nl}수량: $(cast to-unit $ACC ether) XP${nl}수령지갑 잔고: $(cast to-unit $BAL ether) XP"
      fi
      echo "$TODAY" > "$ACC_DAY_FILE"
      echo 0 > "$ACC_FILE"
    fi
  else
    # 첫 실행: 기준점만 잡고 알리지 않는다.
    date -u +%F > "$ACC_DAY_FILE"
    echo 0 > "$ACC_FILE"
  fi

  SWEEP=$(python3 -c "print(max(0, $BAL - ${GAS_RESERVE_WEI:-0}))")
  # PEND_NOW is only meaningful in partial-sweep mode, but the log line below
  # reads it either way — under `set -u` an unset one kills the script right
  # before the transfer, so give it a value in both modes.
  PEND_NOW=0
  if [ -n "${SWEEP_LIMIT_WEI:-}" ]; then
    PEND_NOW=$(cast call "$DIST" "pendingSettlement()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
    SWEEP=$(python3 -c "print(min($SWEEP, max(0, ${SWEEP_LIMIT_WEI} - $PEND_NOW)))")
  fi
  # NOTE: wei amounts exceed bash's 64-bit integers — compare via python
  if python3 -c "exit(0 if int('$SWEEP') > 0 else 1)"; then
    if [ -n "${SWEEP_LIMIT_WEI:-}" ]; then
      log "sweep $(cast to-unit $SWEEP ether) XP -> distributor (budget $(cast to-unit $PEND_NOW ether)/$(cast to-unit ${SWEEP_LIMIT_WEI} ether) XP before)"
    else
      log "sweep $(cast to-unit $SWEEP ether) XP -> distributor (full sweep)"
    fi
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

# 1b) 잔여분 콜드월렛 대피 (COLD_ADDR 설정 시)
#     부분 스윕에서 예산을 초과해 남는 보상은 수령지갑(핫월렛)에 계속 쌓인다.
#     수령주소는 노드 설정상 변경할 수 없으므로 잔고를 낮게 유지하는 것이
#     유일한 방어책 — 예산 충전 후 남는 전액을 콜드월렛으로 옮긴다.
#     실패해도 정산은 계속 진행한다(자금은 수령지갑에 그대로 남음).
if [ -n "${COLLECTOR_PK:-}" ] && [ -n "${COLD_ADDR:-}" ]; then
  BAL2=$(cast balance "$COLLECTOR" --rpc-url "$RPC")
  EVAC=$(python3 -c "print(max(0, $BAL2 - ${GAS_RESERVE_WEI:-0}))")
  MIN_EVAC="${MIN_EVACUATE_WEI:-1000000000000000000000}" # 기본 1,000 XP 이상일 때만
  # 방어: 정산 예산이 아직 안 찼으면 대피하지 않는다. 스윕이 이미 예산을
  # 우선 충전하므로 정상 흐름에서는 발생하지 않지만, 어떤 이유로든 예산이
  # 미달인 상태에서 자금이 콜드월렛으로 빠지는 일은 없어야 한다.
  BUDGET_OK=1
  if [ -n "${SWEEP_LIMIT_WEI:-}" ]; then
    PEND_CHK=$(cast call "$DIST" "pendingSettlement()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
    python3 -c "exit(0 if int('$PEND_CHK') >= int('${SWEEP_LIMIT_WEI}') else 1)" || BUDGET_OK=0
  fi
  if [ "$BUDGET_OK" = "0" ]; then
    log "evacuate skip — settle budget not yet funded ($(cast to-unit $PEND_CHK ether)/$(cast to-unit ${SWEEP_LIMIT_WEI} ether) XP)"
  elif python3 -c "exit(0 if int('$EVAC') >= int('$MIN_EVAC') else 1)"; then
    PEND_AFTER=$(cast call "$DIST" "pendingSettlement()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
    log "evacuate $(cast to-unit $EVAC ether) XP -> cold (settle budget already funded: $(cast to-unit $PEND_AFTER ether)/$(cast to-unit ${SWEEP_LIMIT_WEI:-0} ether) XP)"
    if cast send "$COLD_ADDR" --value "$EVAC" --rpc-url "$RPC" --private-key "$COLLECTOR_PK" >/dev/null; then
      # 성공은 로그만 남긴다. 정상 동작이 하루 여러 번 반복되는 일이라
      # 슬랙으로 보내면 정작 봐야 할 알림이 묻힌다. 실패는 그대로 알린다.
      log "evacuated $(cast to-unit $EVAC ether) XP -> cold"
    else
      log "evacuate FAILED"
      notify "🚨 [XP Vault] 콜드월렛 대피 실패 — 수령지갑에 $(cast to-unit $EVAC ether) XP 잔류. 가스/RPC 확인 필요."
    fi
  fi
fi

# 수령지갑 잔고를 기록해 둔다. 다음 실행에서 이 값과의 차이로 노드 입금을
# 판정하므로, 스윕·대피가 모두 끝난 뒤여야 한다.
if [ -n "${COLLECTOR_PK:-}" ]; then
  mkdir -p ./state
  cast balance "$COLLECTOR" --rpc-url "$RPC" > ./state/collector-balance.txt 2>/dev/null || true
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
    # 정산 결과만 보내면 "그래서 지금 총 얼마인데"를 매번 따로 조회하게 된다.
    S_TVL=$(cast call "$VAULT" "totalAssets()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
    S_CAP=$(cast call "$VAULT" "stakeCap()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
    S_PR=$(cast call "$VAULT" "totalPendingRedeem()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
    S_RR=$(cast call "$VAULT" "rewardReserves()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
    S_APR=$(python3 -c "print(f'{$PEND*${DIST_RATIO_BPS:-6000}/10000*365/max($S_TVL,$S_CAP)*100:.2f}')")
    x(){ cast to-unit "${1:-0}" ether | awk '{printf "%\047.2f", $1}'; }
    notify "🔥 [XP Vault] 에폭 정산 완료${nl}정산액: $(x $PEND) XP${nl}→ 소각: $BURNED XP · 스테이커: $DISTED XP${nl}누적 소각: $(x $B1) XP${nl}${nl}📊 정산 후 현황${nl}  총 스테이킹  $(x $S_TVL) XP  (캡 $(x $S_CAP))${nl}  인출 대기    $(x $S_PR) XP${nl}  이자 대기    $(x $S_RR) XP${nl}  이번 정산 기준 APR  ${S_APR}%"
    ./record-stats.sh || log "record-stats failed (non-fatal)"
  else
    log "settle FAILED"
    notify "🚨 [XP Vault] settle 실패 — 가스/RPC 확인 필요. (permissionless — 수동: ops/settle-only.sh)"
  fi
else
  log "settle skip: $(echo "$READ" | tail -1)"
fi
log "done"
