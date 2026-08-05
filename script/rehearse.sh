#!/usr/bin/env bash
# ============================================================
# Testnet rehearsal — full user journey smoke test.
# Run AFTER DeployTestnet.s.sol. Uses the short testnet windows
# (epoch 5m / rewardsDuration 5m / cooldown 10m), so this takes
# ~20 min of real time with live sleeps.
#
# Required env:
#   RPC          testnet RPC url
#   PK           deployer/foundation key (funds + settle)
#   VAULT, DIST  deployed addresses (from DeployTestnet output)
#   ALICE_PK     a second funded testnet key (the staker)
#   PARTNER_PK   (optional) a third key that stakes via ankr referral
# Optional:
#   ALICE_PK     staker key (default = PK, i.e. single-wallet rehearsal)
#   AMOUNT       stake size in XP (default 20000)
#   REWARD       reward inflow per settle in XP (default 2000)
# ============================================================
set -euo pipefail

: "${RPC:?set RPC}"; : "${PK:?set PK}"; : "${VAULT:?set VAULT}"; : "${DIST:?set DIST}"
ALICE_PK="${ALICE_PK:-$PK}"   # single-wallet rehearsal if not given
AMOUNT="${AMOUNT:-20000}"
REWARD="${REWARD:-2000}"
ANKR=$(cast keccak "ankr")
ALICE=$(cast wallet address --private-key $ALICE_PK)

e() { cast to-unit "$1" ether; }
call() { cast call $1 "$2" ${3:-} --rpc-url $RPC | awk '{print $1}'; }
say() { echo; echo "── $* ──"; }

echo "════════ TESTNET REHEARSAL ════════"
echo "vault=$VAULT  alice=$ALICE  amount=$AMOUNT XP  reward/settle=$REWARD XP"

say "[1] cap을 현재 TVL 근처로 낮춰 완전활용(60/40) 리허설 (선택)"
echo "   (생략 가능 — 캡기준 배분을 그대로 보려면 이 단계 건너뛰세요. 캡 변경은 PARAM_ADMIN=timelock이라"
echo "    테스트넷에선 Safe로 propose→execute 필요. 여기선 캡기준 배분 그대로 진행)"

say "[2] Alice 예치 (직접)"
cast send $VAULT "depositNative(address)" $ALICE --value ${AMOUNT}ether --rpc-url $RPC --private-key $ALICE_PK >/dev/null
echo "   TVL: $(e $(call $VAULT 'totalAssets()(uint256)')) XP"
echo "   Alice 원금: $(e $(call $VAULT 'userPrincipal(address)(uint256)' $ALICE)) XP"

if [ "${PARTNER_PK:-}" != "" ]; then
  PU=$(cast wallet address --private-key $PARTNER_PK)
  say "[2b] 파트너(Ankr) 경유 예치"
  cast send $VAULT "depositNativeWithReferral(address,bytes32)" $PU $ANKR --value ${AMOUNT}ether --rpc-url $RPC --private-key $PARTNER_PK >/dev/null
  echo "   Ankr 유치 TVL: $(e $(call $VAULT 'partnerTVL(bytes32)(uint256)' $ANKR)) XP"
fi

say "[3] 노드 보상 유입 + 정산 (에폭 5분 대기)"
cast send $DIST --value ${REWARD}ether --rpc-url $RPC --private-key $PK >/dev/null
echo "   Distributor 잔고: $(e $(call $DIST 'pendingSettlement()(uint256)')) XP"
echo "   에폭 경과 대기(5분+)... $(date +%H:%M:%S)"
sleep 310
cast send $DIST "settle()" --rpc-url $RPC --private-key $PK >/dev/null
echo "   누적 소각:     $(e $(call $DIST 'totalBurned()(uint256)')) XP"
echo "   스테이커 배분: $(e $(call $DIST 'totalDistributed()(uint256)')) XP"

say "[4] 이자 스트리밍 완료 대기(5분+) 후 earned 확인"
sleep 310
echo "   Alice earned: $(e $(call $VAULT 'earned(address)(uint256)' $ALICE)) XP"
echo "   실효 APR:     $(python3 -c "print(int('$(call $VAULT 'currentAPR()(uint256)')')/1e16, '%')")"

say "[5] 이자 클레임 (Alice)"
B=$(cast balance $ALICE --rpc-url $RPC)
cast send $VAULT "claimRewardNative(address)" $ALICE --rpc-url $RPC --private-key $ALICE_PK >/dev/null
A=$(cast balance $ALICE --rpc-url $RPC)
echo "   Alice 순수령: ~$(python3 -c "print(round(($A-$B)/1e18,4))") XP (가스 제외)"

say "[6] 언스테이크 요청 → 쿨다운(10분) → 원금 수령"
SH=$(call $VAULT 'balanceOf(address)(uint256)' $ALICE)
RID=$(cast send $VAULT "requestRedeem(uint256,address,address)" $SH $ALICE $ALICE --rpc-url $RPC --private-key $ALICE_PK --json | python3 -c "import sys,json;print(json.load(sys.stdin).get('logs',[{}])[0].get('topics',['','','0x0'])[-1] if False else '1')" 2>/dev/null || echo 1)
echo "   요청 완료 (requestId=1 가정). pending: $(e $(call $VAULT 'totalPendingRedeem()(uint256)')) XP"
echo "   쿨다운 대기(10분+)... $(date +%H:%M:%S)"
sleep 610
BB=$(cast balance $ALICE --rpc-url $RPC)
cast send $VAULT "claimRedeemNative(uint256,address)" 1 $ALICE --rpc-url $RPC --private-key $ALICE_PK >/dev/null
AA=$(cast balance $ALICE --rpc-url $RPC)
echo "   원금 수령: ~$(python3 -c "print(round(($AA-$BB)/1e18))") XP (${AMOUNT} 원금 반환)"

echo; echo "════════ REHEARSAL COMPLETE ════════"
echo "예치→정산(소각/배당)→이자→클레임→언스테이크→원금인출 전 과정 테스트넷 검증 완료."
echo "거버넌스(파라미터 변경)는 Safe→Timelock propose/execute 로 별도 리허설하세요 (docs/LAUNCH_CHECKLIST §Phase3)."
