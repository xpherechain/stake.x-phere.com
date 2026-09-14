#!/usr/bin/env bash
# ============================================================
# 스테이킹 캡 변경 (TimelockController 48시간).
#
#   ./raise-cap.sh plan     50000000        계산만 — 서명 없음
#   ./raise-cap.sh schedule 50000000        48h 타이머 시작
#   ./raise-cap.sh status   50000000        남은 시간 / 실행 가능 여부
#   ./raise-cap.sh execute  50000000        48h 경과 후 적용
#   ./raise-cap.sh cancel   50000000        대기 중인 건 취소
#
# 같은 금액을 계속 넘기면 salt 가 같아 schedule/execute 가 반드시 맞물린다.
# 손으로 calldata 를 만들면 여기서 틀어지고, execute 가 조용히 실패한다.
#
# 서명 키: 거버넌스 EOA 0x134f29183fD9399060A3B3AE108f65D4ba23aa42.
#   키퍼 서버 키에는 아무 권한이 없다 — 서버에서 실행하지 말 것.
#
#   기본은 프롬프트 입력(cast -i)이다. 입력값은 화면에 찍히지 않고 셸 히스토리와
#   프로세스 목록(ps) 어디에도 남지 않는다. --private-key 로 명령줄에 붙이면
#   그 세 군데에 전부 남으므로 쓰지 말 것.
#
#   대안:
#     ACCOUNT=xp-gov ./raise-cap.sh ...   keystore (cast wallet import xp-gov -i)
#     LEDGER=1       ./raise-cap.sh ...   하드웨어 지갑
# ============================================================
set -euo pipefail

RPC=${RPC:-https://rpc.ankr.com/xphere_mainnet}
VAULT=0xaE4435bB474716E130be2aC8e6C244f171451064
TL=0x0737B4EEB4dA0920cE7CeE2D1eF64E0f57211F4E
GOV=0x134f29183fD9399060A3B3AE108f65D4ba23aa42
ZERO=0x0000000000000000000000000000000000000000000000000000000000000000
# 서명 방식. 기본은 프롬프트 입력 — 키가 어디에도 기록되지 않는다.
SIGNER=(--interactive)
[ -n "${ACCOUNT:-}" ] && SIGNER=(--account "$ACCOUNT")
[ "${LEDGER:-0}" = "1" ] && SIGNER=(--ledger)

CMD=${1:-}; CAP_XP=${2:-}
[ -n "$CMD" ] && [ -n "$CAP_XP" ] || { sed -n '3,12p' "$0"; exit 1; }

DATA=$(cast calldata "setStakeCap(uint256)" "$(cast to-wei "$CAP_XP" ether)")
SALT=$(cast keccak "xp-vault-stake-cap-${CAP_XP}")
ID=$(cast call "$TL" "hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)" \
       "$VAULT" 0 "$DATA" "$ZERO" "$SALT" --rpc-url "$RPC" | awk '{print $1}')

xp() { cast to-unit "$(cast call "$1" "$2" --rpc-url "$RPC" | awk '{print $1}')" ether; }

banner() {
  local CUR TVL
  CUR=$(xp "$VAULT" 'stakeCap()(uint256)')
  TVL=$(xp "$VAULT" 'totalAssets()(uint256)')
  echo "현재 캡   ${CUR} XP"
  echo "총 스테이킹 ${TVL} XP"
  echo "새 캡     ${CAP_XP} XP"
  echo "op id     ${ID}"
  echo
}

case "$CMD" in
  plan)
    banner
    # APR = distributed x 365 / TVL 이고 distributed = amount x 60% x TVL/cap 이므로
    # TVL 이 약분된다:  APR = 일일 정산액 x 60% x 365 / cap.
    # 즉 APR 은 캡과 유입량만의 함수다. 캡을 올리면 그만큼 영구히 내려가고,
    # 새 용량이 다 차도 회복되지 않는다 — 회복은 노드 수익(유입) 증가로만 가능하다.
    CURCAP=$(cast call "$VAULT" 'stakeCap()(uint256)' --rpc-url "$RPC" | awk '{print $1}')
    python3 - "$CURCAP" "$CAP_XP" <<'PY'
import sys
cur = int(sys.argv[1]) / 1e18
new = float(sys.argv[2])
print(f"APR 영향: 캡이 {cur:,.0f} → {new:,.0f} 이면")
print(f"  스테이커 몫 x{cur/new:.3f}, APR 도 x{cur/new:.3f}")
print(f"  차액은 소각으로 이동.")
print(f"  ※ 새 용량이 다 차도 APR 은 회복되지 않는다 (TVL 이 약분되므로).")
print(f"    원래 APR 로 되돌리려면 일일 유입이 {new/cur:.2f}배 되어야 한다.")
PY
    echo
    echo "schedule 로 진행하면 48시간 뒤 execute 가능."
    ;;

  schedule)
    banner
    T0=$(cast call "$TL" "getTimestamp(bytes32)(uint256)" "$ID" --rpc-url "$RPC" | awk '{print $1}')
    [ "$T0" = "0" ] || { echo "이미 등록된 건입니다 (status 로 확인)"; exit 1; }
    echo "서명 주소는 반드시 ${GOV} 여야 합니다."
    echo "다른 키를 넣으면 가스 추정 단계에서 거부되고 가스는 나가지 않습니다."
    echo "개인키를 입력하십시오 (화면에 표시되지 않음):"
    cast send "$TL" "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
      "$VAULT" 0 "$DATA" "$ZERO" "$SALT" 172800 \
      --rpc-url "$RPC" "${SIGNER[@]}"
    echo "48시간 뒤: $0 execute $CAP_XP"
    ;;

  status)
    banner
    T=$(cast call "$TL" "getTimestamp(bytes32)(uint256)" "$ID" --rpc-url "$RPC" | awk '{print $1}')
    case "$T" in
      0) echo "미등록 — schedule 부터 하십시오." ;;
      1) echo "이미 실행 완료됨." ;;
      *) NOW=$(date -u +%s)
         if [ "$NOW" -ge "$T" ]; then echo "✅ 실행 가능 (예정 시각 경과)"
         else echo "⏳ $(( (T-NOW)/3600 ))시간 $(( ((T-NOW)%3600)/60 ))분 남음"; fi
         echo "실행 가능 시각: $(date -u -r "$T" '+%Y-%m-%d %H:%M UTC') / $(TZ=Asia/Seoul date -r "$T" '+%m-%d %H:%M KST')" ;;
    esac
    ;;

  execute)
    banner
    cast send "$TL" "execute(address,uint256,bytes,bytes32,bytes32)" \
      "$VAULT" 0 "$DATA" "$ZERO" "$SALT" \
      --rpc-url "$RPC" "${SIGNER[@]}"
    echo "적용 후 캡: $(xp "$VAULT" 'stakeCap()(uint256)') XP"
    ;;

  cancel)
    banner
    cast send "$TL" "cancel(bytes32)" "$ID" --rpc-url "$RPC" "${SIGNER[@]}"
    echo "취소됨."
    ;;

  *) sed -n '3,12p' "$0"; exit 1 ;;
esac
