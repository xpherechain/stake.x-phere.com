#!/usr/bin/env bash
# ============================================================
# 매일 1회: 전용 수령 지갑 → Distributor 스윕 후 settle().
# 경로 B(전용 EOA) 운영자용 메인 스크립트.
#   - 경로 A(프로토콜이 Distributor로 직접 지급)면 COLLECTOR_PK를 비워두면
#     스윕 단계를 건너뛰고 settle만 수행한다.
#   - settle은 permissionless라 실패해도 자금 유실 없음(다음 실행/누구나 재호출).
#   - 정산 실패는 Slack(SLACK_WEBHOOK)·Telegram(TG_*)으로 즉시 알림.
#   - 정기 알림은 정산 직후 "일일 요약" 한 건뿐이다(정산 결과 + 노드 유입
#     + 현황). 예전의 노드보상누적·정산완료·일일현황 3건을 합친 것이다.
#     자세한 배경은 notify-lib.sh 머리말 참고.
# 사용: ops/daily-settle.sh   (crontab 에서 호출)
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"
# foundry(cast)를 어떤 실행 환경에서도 찾도록 PATH 보강
# (cron, sudo -u 는 로그인 셸을 거치지 않아 ~/.foundry/bin 이 빠진다)
export PATH="$PATH:$HOME/.foundry/bin:/home/xpops/.foundry/bin:/usr/local/bin"
set -a; source ./.env; set +a
# notify() / xpfmt() / status_block() / 일일 요약 중복 방지 플래그
source ./notify-lib.sh
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


if [ -n "$config_error" ]; then
  log "CONFIG ERROR: $config_error — 중단"
  notify "🚨 [XP Vault] 설정 오류로 정산 중단${nl}${config_error}${nl}ops/.env 확인 필요 (.env.example 로 덮어써졌을 가능성)"
  exit 1
fi


# ── 수령지갑 목록 ────────────────────────────────────────────────
# 노드마다 보상 주소가 따로 있고, 그 주소는 노드 설정에 박혀 있어 바꿀 수 없다.
# 그래서 유니온 노드가 늘면 스윕할 지갑도 는다. COLLECTOR_PK 는 기존 지갑
# 그대로 두고 COLLECTOR_PK_2 … _5 를 추가하면 된다.
#
# 노드를 Distributor 로 직접 지급하도록 설정했다면 여기 넣을 것이 없다 —
# 스윕 자체가 불필요하고, 키도 생기지 않는다(그쪽이 더 낫다).
COLLECTORS=()
[ -n "${COLLECTOR_PK:-}" ] && COLLECTORS+=("$COLLECTOR_PK")
for i in 2 3 4 5; do
  v="COLLECTOR_PK_$i"
  [ -n "${!v:-}" ] && COLLECTORS+=("${!v}")
done

mkdir -p ./state
ACC_FILE=./state/inflow-accum.txt
BAL_LINES=""

for PK in ${COLLECTORS[@]+"${COLLECTORS[@]}"}; do
  ADDR=$(cast wallet address --private-key "$PK")
  TAG="${ADDR:0:10}…"
  BAL=$(cast balance "$ADDR" --rpc-url "$RPC")

  # 1a) 노드 입금 집계.
  #     보상은 검증인 순번이 돌아올 때마다 589 XP씩 들어오므로, 유입 건마다
  #     알리면 하루 백 건을 넘는다. 그 빈도에서는 아무도 읽지 않고, 정작
  #     읽어야 할 실패 알림이 그 사이에 묻힌다. 누적만 해두고 하루 한 번
  #     합계로 보고한다 — 이상 신호는 "들어와야 할 게 안 들어온 것"인데
  #     그건 합계로만 보인다.
  BAL_FILE="./state/collector-balance-${ADDR}.txt"
  LEGACY=./state/collector-balance.txt
  # 지갑이 하나뿐이던 시절의 파일명을 물려받는다. 그냥 두면 기준점을 잃고
  # 그날 유입 전체가 "신규 입금"으로 잡히거나 통째로 빠진다.
  [ ! -f "$BAL_FILE" ] && [ -f "$LEGACY" ] && mv "$LEGACY" "$BAL_FILE"

  if [ -f "$BAL_FILE" ]; then
    LAST_BAL=$(cat "$BAL_FILE")
    INFLOW=$(python3 -c "print(max(0, $BAL - $LAST_BAL))")
    if python3 -c "exit(0 if int('$INFLOW') > 0 else 1)"; then
      ACC=$(cat "$ACC_FILE" 2>/dev/null || echo 0)
      python3 -c "print($ACC + $INFLOW)" > "$ACC_FILE"
      log "node deposit $TAG +$(cast to-unit $INFLOW ether) XP (누적 $(cast to-unit $(cat $ACC_FILE) ether))"
    fi
  fi

  # 1) 스윕 → Distributor
  #    SWEEP_LIMIT_WEI = "에폭당 투입 예산" — 부분 스윕 모드.
  #    Distributor 대기 잔고가 예산에 찰 때까지만 채운다. settle이 하루 1번
  #    잔고를 소진하므로 자연히 '하루 SWEEP_LIMIT_WEI'가 강제된다.
  #    지갑이 여럿이어도 예산은 Distributor 잔고 기준이라 전체에 한 번만
  #    적용된다 — 앞 지갑이 예산을 채우면 뒤 지갑은 자동으로 건너뛴다.
  SWEEP=$(python3 -c "print(max(0, $BAL - ${GAS_RESERVE_WEI:-0}))")
  # PEND_NOW 는 부분 스윕에서만 의미가 있지만 아래 로그가 두 모드 모두에서
  # 읽는다 — set -u 에서 미설정이면 전송 직전에 스크립트가 죽는다.
  PEND_NOW=0
  if [ -n "${SWEEP_LIMIT_WEI:-}" ]; then
    PEND_NOW=$(cast call "$DIST" "pendingSettlement()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
    SWEEP=$(python3 -c "print(min($SWEEP, max(0, ${SWEEP_LIMIT_WEI} - $PEND_NOW)))")
  fi
  # 스윕은 되돌릴 수 없다. Distributor 에는 출금 함수가 없고, 들어온 돈은
  # 다음 정산에서 스테이커 배분과 소각으로 갈린다. 그래서 "노드 보상이라기엔
  # 말이 안 되는 금액"은 보내지 않고 사람을 부른다.
  #
  # 2026-09-16, 새 수령지갑이 35,000,000 XP 의 경유지로 쓰였다. 63초 머물다
  # 나갔고 그 사이에 크론이 돌지 않아 넘어갔지만, 10분 주기로 도는 이상
  # 다음에도 빗나가리라는 보장이 없다. 스윕됐다면 2,100만이 배분되고
  # 1,400만이 소각된 뒤 회수할 방법이 없었다.
  #
  # 수령지갑은 노드 보상 전용이어야 한다. 이 한도는 그 규칙이 깨졌을 때
  # 손실 대신 알림이 나가게 하는 마지막 방어선이다.
  MAX_SWEEP="${MAX_SWEEP_WEI:-1000000000000000000000000}" # 기본 1,000,000 XP
  if python3 -c "exit(0 if int('$SWEEP') > int('$MAX_SWEEP') else 1)"; then
    log "sweep BLOCKED $TAG — $(cast to-unit $SWEEP ether) XP exceeds cap $(cast to-unit $MAX_SWEEP ether) XP"
    # 한 번 걸리면 해결될 때까지 계속 걸린다. 10분마다 알리면 채널이 죽으므로
    # 처음 한 번과 이후 6시간마다만 보낸다.
    GUARD_FILE="./state/sweep-blocked-${ADDR}.txt"
    LASTW=$(cat "$GUARD_FILE" 2>/dev/null || echo 0)
    NOWS=$(date -u +%s)
    if [ "$((NOWS - LASTW))" -ge 21600 ]; then
      echo "$NOWS" > "$GUARD_FILE"
      notify "🚨 [XP Vault] 스윕 차단 — 수령지갑 ${TAG} 에 $(cast to-unit $SWEEP ether) XP${nl}노드 보상으로 보기에 과도한 금액이라 전송하지 않았습니다.${nl}수령지갑에 다른 자금이 섞였는지 확인하십시오. 스윕은 되돌릴 수 없습니다.${nl}정상이면 MAX_SWEEP_WEI 를 올리고 재실행하십시오."
    fi
    SWEEP=0
    BLOCKED=1
  else
    BLOCKED=0
    rm -f "./state/sweep-blocked-${ADDR}.txt" 2>/dev/null || true
  fi

  # NOTE: wei 값은 bash 의 64비트 정수를 넘는다 — 비교는 python 으로
  if python3 -c "exit(0 if int('$SWEEP') > 0 else 1)"; then
    if [ -n "${SWEEP_LIMIT_WEI:-}" ]; then
      log "sweep $TAG $(cast to-unit $SWEEP ether) XP -> distributor (budget $(cast to-unit $PEND_NOW ether)/$(cast to-unit ${SWEEP_LIMIT_WEI} ether) XP before)"
    else
      log "sweep $TAG $(cast to-unit $SWEEP ether) XP -> distributor (full sweep)"
    fi
    if ! cast send "$DIST" --value "$SWEEP" --rpc-url "$RPC" --private-key "$PK" >/dev/null; then
      log "sweep FAILED $TAG"
      notify "🚨 [XP Vault] 스윕 실패 — 수령지갑 ${TAG} → Distributor 전송 에러. 서버/가스 확인 필요."
    fi
  elif [ "$BLOCKED" = "0" ]; then
    log "sweep skip $TAG (balance <= gas reserve)"
  fi

  # 1b) 잔여분 콜드월렛 대피 (COLD_ADDR 설정 시)
  #     부분 스윕에서 예산을 초과해 남는 보상은 수령지갑(핫월렛)에 계속 쌓인다.
  #     수령주소는 노드 설정상 변경할 수 없으므로 잔고를 낮게 유지하는 것이
  #     유일한 방어책이다. 실패해도 정산은 계속 진행한다.
  if [ -n "${COLD_ADDR:-}" ]; then
    BAL2=$(cast balance "$ADDR" --rpc-url "$RPC")
    EVAC=$(python3 -c "print(max(0, $BAL2 - ${GAS_RESERVE_WEI:-0}))")
    MIN_EVAC="${MIN_EVACUATE_WEI:-1000000000000000000000}" # 기본 1,000 XP 이상일 때만
    # 방어: 정산 예산이 아직 안 찼으면 대피하지 않는다.
    BUDGET_OK=1
    if [ -n "${SWEEP_LIMIT_WEI:-}" ]; then
      PEND_CHK=$(cast call "$DIST" "pendingSettlement()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
      python3 -c "exit(0 if int('$PEND_CHK') >= int('${SWEEP_LIMIT_WEI}') else 1)" || BUDGET_OK=0
    fi
    if [ "$BUDGET_OK" = "0" ]; then
      log "evacuate skip $TAG — settle budget not yet funded"
    elif python3 -c "exit(0 if int('$EVAC') >= int('$MIN_EVAC') else 1)"; then
      log "evacuate $TAG $(cast to-unit $EVAC ether) XP -> cold"
      if cast send "$COLD_ADDR" --value "$EVAC" --rpc-url "$RPC" --private-key "$PK" >/dev/null; then
        # 성공은 로그만. 정상 동작이 하루 여러 번 반복되는 일이라 슬랙으로
        # 보내면 정작 봐야 할 알림이 묻힌다. 실패는 그대로 알린다.
        log "evacuated $TAG $(cast to-unit $EVAC ether) XP -> cold"
      else
        log "evacuate FAILED $TAG"
        notify "🚨 [XP Vault] 콜드월렛 대피 실패 — 수령지갑 ${TAG} 에 $(cast to-unit $EVAC ether) XP 잔류. 가스/RPC 확인 필요."
      fi
    fi
  fi

  # 잔고를 기록해 둔다. 다음 실행에서 이 값과의 차이로 노드 입금을 판정하므로
  # 스윕·대피가 모두 끝난 뒤여야 한다.
  cast balance "$ADDR" --rpc-url "$RPC" > "$BAL_FILE" 2>/dev/null || true
  BAL_LINES="${BAL_LINES}${nl}    ${TAG} $(xpfmt "$(cat "$BAL_FILE")") XP"
done

# 1c) 유입은 쌓기만 한다. 보고와 리셋은 아래 일일 요약에서 함께 한다.
#     예전에는 00:00 UTC 에 따로 알리고 리셋했는데, 그러면 정산 시각(06시대)
#     요약에 실을 수 있는 값이 그날 0~6시치뿐이라 하루치가 되지 않는다.
#     이제 집계 구간은 "직전 요약 이후" = 사실상 정산 간격(24h)이다.

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
    # 요약에 실을 나머지 수치. WXP 가 .env 에 없으면 볼트 보유 줄만 빠진다.
    S_HELD=""
    [ -n "${WXP:-}" ] && S_HELD=$(cast call "$WXP" "balanceOf(address)(uint256)" "$VAULT" --rpc-url "$RPC" | awk '{print $1}')
    S_NEXT=$(cast call "$DIST" "nextSettleTime()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
    S_PEND=$(cast call "$DIST" "pendingSettlement()(uint256)" --rpc-url "$RPC" | awk '{print $1}')

    # ── 일일 요약 (하루 1건) ──────────────────────────────────
    # ① 정산 결과 ② 직전 요약 이후 노드 유입 ③ 현황 ④ 수령지갑 잔고.
    # ②는 예전 "노드 보상 24시간 누적", ③은 예전 "일일 현황"이 들어온 자리다.
    MSG="🔥 [XP Vault] 일일 요약 — 에폭 정산 완료${nl}"
    MSG+="정산액: $(xpfmt $PEND) XP${nl}"
    # wei 단위 차이는 bash 64비트를 넘어 python 으로 뺀다.
    # 표기는 반드시 xpfmt 으로 — 한 메시지 안에서 자릿수가 갈리면 읽히지 않는다.
    B_DELTA=$(python3 -c "print($B1-$B0)")
    D_DELTA=$(python3 -c "print($D1-$D0)")
    MSG+="→ 소각: $(xpfmt $B_DELTA) XP · 스테이커: $(xpfmt $D_DELTA) XP${nl}"
    MSG+="누적 소각: $(xpfmt $B1) XP${nl}"
    MSG+="이번 정산 기준 APR  ${S_APR}%${nl}"
    if [ "${#COLLECTORS[@]}" -gt 0 ]; then
      ACC=$(cat "$ACC_FILE" 2>/dev/null || echo 0)
      if digest_ever_sent; then
        # 임계값 미만이면 숙이지 않고 표시만 한다 — 유입이 멈춘 날이
        # 조용해지면 그것이야말로 놓치면 안 되는 신호다.
        WARN=""
        python3 -c "exit(0 if int('$ACC') < int('${DEPOSIT_ALERT_WEI:-1000000000000000000000}') else 1)" \
          && WARN="  ⚠ 평소보다 적음"
        MSG+="${nl}🟢 노드 보상 유입 (직전 요약 이후): $(xpfmt $ACC) XP${WARN}${nl}"
      else
        MSG+="${nl}🟢 노드 보상 유입: $(xpfmt $ACC) XP  (집계 시작 이후 부분 집계)${nl}"
      fi
    fi
    MSG+="${nl}$(status_block "$S_TVL" "$S_CAP" "$S_PR" "$S_RR" "$S_HELD" "$S_PEND" "$B1" "$S_NEXT")"
    [ "${#COLLECTORS[@]}" -gt 0 ] && MSG+="${nl}  수령지갑 (${#COLLECTORS[@]}개)${BAL_LINES}"
    notify "$MSG"
    # 요약이 나갔으니 유입 집계를 새로 시작하고, monitor.sh 가 같은 날
    # 중복으로 보내지 않도록 표시한다.
    echo 0 > "$ACC_FILE"
    mark_digest_sent
    ./record-stats.sh || log "record-stats failed (non-fatal)"
  else
    log "settle FAILED"
    notify "🚨 [XP Vault] settle 실패 — 가스/RPC 확인 필요. (permissionless — 수동: ops/settle-only.sh)"
  fi
else
  log "settle skip: $(echo "$READ" | tail -1)"
fi
log "done"
