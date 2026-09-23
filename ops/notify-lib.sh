#!/usr/bin/env bash
# ============================================================
# 알림 공통부 — daily-settle.sh 와 monitor.sh 가 source 한다.
#
# 정기 알림은 하루 "일일 요약" 한 건뿐이다. 예전에는 세 건이 따로 나갔다:
#   00:00 UTC  🟢 노드 보상 24시간 누적   (daily-settle.sh)
#   정산 시각  🔥 에폭 정산 완료          (daily-settle.sh)
#   09:00 UTC  📊 일일 현황               (monitor.sh)
# 셋이 총 스테이킹·인출 대기·이자 대기·누적 소각·수령지갑 잔고를 그대로
# 반복해서, 읽는 쪽에서 무엇이 새 정보인지 구분할 수 없었다. 정산 시각
# 기준 한 건으로 합쳤다.
#
# 실패 알림(🚨)은 여기 해당하지 않는다 — 종전대로 즉시, 건별로 나간다.
# 합칠 수 있는 것은 "정기적으로 같은 수치를 반복하는" 알림뿐이다.
# ============================================================

NL=$'\n'
DIGEST_FILE="${DIGEST_FILE:-./state/digest-day.txt}"

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

xpfmt() { cast to-unit "${1:-0}" ether | awk '{printf "%\047.2f", $1}'; }

# 일일 요약이 오늘 이미 나갔는가. 두 스크립트가 별도 프로세스라 파일로 맞춘다.
digest_sent_today() {
  [ "$(cat "$DIGEST_FILE" 2>/dev/null)" = "$(date -u +%F)" ]
}
mark_digest_sent() {
  mkdir -p "$(dirname "$DIGEST_FILE")"
  date -u +%F > "$DIGEST_FILE"
}
# 첫 설치일에는 유입 집계가 부분치다 — 하루치인 것처럼 읽히면 안 된다.
digest_ever_sent() { [ -f "$DIGEST_FILE" ]; }

# status_block <staked> <cap> <predeem> <reserves> <held> <pend> <burned> <next>
#   held 가 비면(WXP 미설정) 볼트 보유 줄을 생략한다.
# 두 경로가 같은 블록을 쓰도록 여기 한 곳에서만 만든다 — 모양이 갈리면
# 합친 의미가 없다.
status_block() {
  local staked=$1 cap=$2 predeem=$3 reserves=$4 held=$5 pend=$6 burned=$7 next=$8
  local now util till s
  now=$(date -u +%s)
  util=$(python3 -c "print(f'{$staked/$cap*100:.2f}' if $cap else '0')")
  till=$(python3 -c "
d=$next-$now
print('%dh %dm 후' % (d//3600,(d%3600)//60) if d>0 else '%dh %dm 지연' % (-d//3600,(-d%3600)//60))")
  s="📊 현황 ($(date -u '+%m-%d %H:%M')Z)${NL}"
  s+="  총 스테이킹   $(xpfmt "$staked") XP  (캡 $(xpfmt "$cap") · ${util}%)${NL}"
  s+="  인출 대기     $(xpfmt "$predeem") XP${NL}"
  s+="  이자 대기     $(xpfmt "$reserves") XP  ← 미청구 보상${NL}"
  if [ -n "$held" ]; then
    local free
    free=$(python3 -c "print(max(0, $held - ($staked + $predeem + $reserves)))")
    s+="  볼트 보유     $(xpfmt "$held") XP  (여유 $(xpfmt "$free"))${NL}"
  fi
  s+="  정산 대기     $(xpfmt "$pend") XP  → 다음 정산 ${till}${NL}"
  s+="  누적 소각     $(xpfmt "$burned") XP"
  printf '%s' "$s"
}
