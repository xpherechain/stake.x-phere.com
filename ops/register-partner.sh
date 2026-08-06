#!/usr/bin/env bash
# ============================================================
# 신규 파트너(KOL·회사·플랫폼) 등록 — 1분 완료 절차의 온체인 파트.
#
# 사용:  PM_PK=0x<PARTNER_MANAGER키> ./register-partner.sh <slug> [subCapXP]
#   예:  PM_PK=... ./register-partner.sh cryptokim 0
#
# PARTNER_MANAGER_ROLE 보유 지갑(임시 거버넌스 EOA)의 키가 필요하다.
# 등록 후 프론트 반영: web/config.js 의 partners 배열에 슬러그 추가 → push.
# 파트너에게 전달: https://stake.x-phere.com/?ref=<slug>
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"
# foundry(cast)를 어떤 실행 환경에서도 찾도록 PATH 보강
# (cron, sudo -u 는 로그인 셸을 거치지 않아 ~/.foundry/bin 이 빠진다)
export PATH="$PATH:$HOME/.foundry/bin:/home/xpops/.foundry/bin:/usr/local/bin"
set -a; source ./.env; set +a
: "${RPC:?}"; : "${VAULT:?}"; : "${PM_PK:?PARTNER_MANAGER 키를 PM_PK 로 넘기세요}"
SLUG="${1:?슬러그를 지정하세요 (예: cryptokim)}"
SUBCAP_XP="${2:-0}"

# slug 검증: 소문자·숫자·하이픈만 (프론트 ?ref 캡처 규칙과 일치)
[[ "$SLUG" =~ ^[a-z0-9-]{2,32}$ ]] || { echo "슬러그는 소문자/숫자/하이픈 2~32자"; exit 1; }

PID=$(cast keccak "$SLUG")
SUBCAP_WEI=$(cast to-wei "$SUBCAP_XP" ether)
echo "slug=$SLUG  partnerId=$PID  subCap=${SUBCAP_XP} XP"

# 중복 등록 방지: 이미 TVL 조회가 성공하면 등록 여부와 무관하게 tx로 확인
cast send "$VAULT" "registerPartner(bytes32,uint256)" "$PID" "$SUBCAP_WEI" \
  --rpc-url "$RPC" --private-key "$PM_PK"

echo ""
echo "✓ 온체인 등록 완료. 남은 절차:"
echo "  1) web/config.js partners 배열에 \"$SLUG\" 추가 후 push (프론트 ?ref 허용목록)"
echo "  2) 파트너에게 전달: https://stake.x-phere.com/?ref=$SLUG"
echo "  3) TVL 확인: ./partner-tvl.sh $SLUG"
