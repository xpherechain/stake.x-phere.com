#!/usr/bin/env bash
# ============================================================
# 상태 점검 + 이상 시 Slack/Telegram 알림. cron 으로 30분~4시간마다.
# 점검: ①정산 지연(nextSettleTime 초과) ②지급능력 불변식 ③수령지갑 잔고 누적
# 알림 채널: SLACK_WEBHOOK / TG_TOKEN+TG_CHAT — 설정된 채널 모두로 발송.
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"
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

# ③ 수령지갑 잔고 누적(스윕 실패/부재 징후) — 임계 초과 시 알림
#    부분 스윕 모드에선 어느 정도 누적이 정상이므로 임계는 넉넉히.
COLLECTOR_ALERT_WEI="${COLLECTOR_ALERT_WEI:-100000000000000000000000}" # 100,000 XP
if [ -n "${COLLECTOR_PK:-}" ]; then
  cb=$(cast balance "$(cast wallet address --private-key "$COLLECTOR_PK")" --rpc-url "$RPC")
  if python3 -c "exit(0 if $cb > $COLLECTOR_ALERT_WEI else 1)"; then
    alerts+="⚠ 수령지갑 잔고 $(cast to-unit $cb ether) XP 누적 — 스윕/대피 확인${nl}"
  fi
fi

if [ -n "$alerts" ]; then
  echo "$alerts"
  notify "[XP Vault]${nl}${alerts}"
  exit 1
fi
echo "[$(date -u +%FT%TZ)] ok"
