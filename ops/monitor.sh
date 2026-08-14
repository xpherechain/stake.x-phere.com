#!/usr/bin/env bash
# ============================================================
# 상태 점검 + 이상 시 Slack/Telegram 알림. cron 으로 30분~4시간마다.
# 점검: ①정산 지연(nextSettleTime 초과) ②지급능력 불변식 ③수령지갑 잔고 누적
# 알림 채널: SLACK_WEBHOOK / TG_TOKEN+TG_CHAT — 설정된 채널 모두로 발송.
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"
# foundry(cast)를 어떤 실행 환경에서도 찾도록 PATH 보강
# (cron, sudo -u 는 로그인 셸을 거치지 않아 ~/.foundry/bin 이 빠진다)
export PATH="$PATH:$HOME/.foundry/bin:/home/xpops/.foundry/bin:/usr/local/bin"
set -a; source ./.env; set +a
: "${RPC:?}"; : "${DIST:?}"; : "${VAULT:?}"; : "${WXP:?}"
c() { cast call "$1" "$2" ${3:-} --rpc-url "$RPC" | awk '{print $1}'; }

# 설정 유효성: 플레이스홀더면 감시 자체가 무의미하므로 즉시 경보
ZERO=0x0000000000000000000000000000000000000000
if [ "$DIST" = "$ZERO" ] || [ "$VAULT" = "$ZERO" ] || [ "$WXP" = "$ZERO" ]; then
  MSG="[XP Vault] ops/.env 설정 오류 - 컨트랙트 주소가 플레이스홀더(0x0)입니다. 키퍼/모니터링이 무력화된 상태."
  echo "$MSG"
  if [ -n "${SLACK_WEBHOOK:-}" ]; then
    SLACK_WEBHOOK="$SLACK_WEBHOOK" python3 - "$MSG" <<'PY' || true
import json, os, sys, urllib.request
req = urllib.request.Request(os.environ["SLACK_WEBHOOK"], json.dumps({"text": sys.argv[1]}).encode(), {"Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=10)
PY
  fi
  exit 1
fi

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

now=$(date -u +%s); alerts=""
nl=$'\n'

# ① 정산 지연: 다음 정산 가능 시각이 6h 넘게 지났는데 미정산 + 잔고 존재
next=$(c "$DIST" "nextSettleTime()(uint256)")
pend=$(c "$DIST" "pendingSettlement()(uint256)")
if [ "$now" -gt "$((next + 21600))" ] && [ "$pend" != "0" ]; then
  alerts+="⚠ 정산 지연 — $(cast to-unit $pend ether) XP 대기 중 (키퍼/크론 확인)${nl}"
fi

# ② 지급능력 불변식: WXP.balanceOf(vault) >= staked + pending + reserves
held=$(c "$WXP" "balanceOf(address)(uint256)" "$VAULT")
staked=$(c "$VAULT" "totalAssets()(uint256)")
predeem=$(c "$VAULT" "totalPendingRedeem()(uint256)")
reserves=$(c "$VAULT" "rewardReserves()(uint256)")
oblig=$(python3 -c "print($staked + $predeem + $reserves)")
if python3 -c "exit(0 if $held < $oblig else 1)"; then
  alerts+="🚨 불변식 위반: WXP held=$held < 의무=$oblig — 즉시 확인 필요${nl}"
fi

# ③ 수령지갑 잔고 — 전액 스윕 모드에서만 누적을 이상신호로 본다.
#    부분 스윕(SWEEP_LIMIT_WEI 설정) 중에는 예산 초과분이 수령지갑에 남는 것이
#    설계된 동작이므로 누적 자체는 경보 대상이 아니다. 그 모드의 실패 신호는
#    "Distributor 예산 미충전"이며 아래에서 따로 본다.
if [ -n "${COLLECTOR_PK:-}" ]; then
  cb=$(cast balance "$(cast wallet address --private-key "$COLLECTOR_PK")" --rpc-url "$RPC")
  if [ -z "${SWEEP_LIMIT_WEI:-}" ]; then
    COLLECTOR_ALERT_WEI="${COLLECTOR_ALERT_WEI:-100000000000000000000000}" # 100,000 XP
    if python3 -c "exit(0 if $cb > $COLLECTOR_ALERT_WEI else 1)"; then
      alerts+="⚠ 수령지갑 잔고 $(cast to-unit $cb ether) XP 누적 — 스윕 실패 의심${nl}"
    fi
  else
    # 부분 스윕: 수령지갑에 재원이 있는데도 Distributor 대기잔고가 예산에
    # 못 미치면(다음 정산분 미확보) 스윕 경로에 문제가 있다는 뜻.
    if python3 -c "exit(0 if $pend < ${SWEEP_LIMIT_WEI} and $cb > ${GAS_RESERVE_WEI:-0} else 1)"; then
      alerts+="⚠ 다음 정산분 미충전 — 대기 $(cast to-unit $pend ether) XP < 예산 $(cast to-unit ${SWEEP_LIMIT_WEI} ether) XP (수령지갑엔 $(cast to-unit $cb ether) XP 보유) — 스윕 확인${nl}"
    fi
    # 대피가 켜져 있으면 핫월렛 잔고는 낮게 유지되어야 한다 — 누적은 대피 실패 신호.
    if [ -n "${COLD_ADDR:-}" ]; then
      EVAC_ALERT="${COLLECTOR_ALERT_WEI:-20000000000000000000000}" # 기본 20,000 XP
      if python3 -c "exit(0 if $cb > $EVAC_ALERT else 1)"; then
        alerts+="⚠ 수령지갑(핫월렛) 잔고 $(cast to-unit $cb ether) XP — 콜드월렛 대피 실패 의심${nl}"
      fi
    fi
  fi
fi

# 현황 블록. 경보만 보내면 "그래서 지금 얼마인데"를 매번 손으로 조회하게 된다.
# 이미 위에서 읽은 값들이라 RPC 호출이 늘지 않는다.
xp() { cast to-unit "${1:-0}" ether | awk '{printf "%\047.2f", $1}'; }
cap=$(c "$VAULT" "stakeCap()(uint256)")
burned=$(c "$DIST" "totalBurned()(uint256)")
free=$(python3 -c "print(max(0, $held - $oblig))")
util=$(python3 -c "print(f'{$staked/$cap*100:.2f}' if $cap else '0')")
till=$(python3 -c "
d=$next-$now
print('%dh %dm 후' % (d//3600,(d%3600)//60) if d>0 else '%dh %dm 지연' % (-d//3600,(-d%3600)//60))")

state="📊 현황 ($(date -u +%m-%d\ %H:%M)Z)${nl}"
state+="  총 스테이킹   $(xp $staked) XP  (캡 $(xp $cap) · ${util}%)${nl}"
state+="  인출 대기     $(xp $predeem) XP${nl}"
state+="  이자 대기     $(xp $reserves) XP  ← 미청구 보상${nl}"
state+="  볼트 보유     $(xp $held) XP  (여유 $(xp $free))${nl}"
state+="  정산 대기     $(xp $pend) XP  → 다음 정산 ${till}${nl}"
state+="  누적 소각     $(xp $burned) XP"
if [ -n "${COLLECTOR_PK:-}" ]; then
  state+="${nl}  수령지갑      $(xp ${cb:-0}) XP"
fi

if [ -n "$alerts" ]; then
  echo "$alerts"
  notify "[XP Vault]${nl}${alerts}${nl}${state}"
  exit 1
fi
echo "[$(date -u +%FT%TZ)] ok"
echo "$state"
# 하루 한 번(09:00 UTC 근처) 이상 없어도 현황을 남긴다. 조용한 것과
# 죽은 것을 구분할 수 없으면 감시가 아니다.
if [ "${MONITOR_DIGEST:-1}" = "1" ] && [ "$(date -u +%H)" = "09" ] && [ "$(date -u +%M)" -lt 30 ]; then
  notify "[XP Vault] 일일 현황${nl}${state}"
fi
