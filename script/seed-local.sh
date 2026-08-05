#!/usr/bin/env bash
# ============================================================
# Local live-demo seeder — proves the dashboard reads REAL
# on-chain data (no mock). Reproduces the verified flow:
#   anvil → deploy → register partners → stake → fund → settle
#
# Usage:
#   1) anvil --port 8545          (in another terminal)
#   2) ./script/seed-local.sh
#   3) update web/config.js with the printed addresses (or keep
#      the ones already there if unchanged), then:
#      cd web && python3 -m http.server 8799
#   4) open http://localhost:8799 — the "demo data" badge must
#      be gone and all numbers must match the chain.
# ============================================================
set -euo pipefail

RPC=http://localhost:8545
# anvil's well-known default accounts
PK0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
PK1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
PK2=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
PK3=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6

echo "── deploying core system ──"
OUT=$(forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --private-key $PK0 2>/dev/null)
VAULT=$(echo "$OUT" | grep -oE "XPStakingVault: 0x[0-9a-fA-F]{40}" | awk '{print $2}')
DIST=$(echo "$OUT" | grep -oE "RewardDistributor: 0x[0-9a-fA-F]{40}" | awk '{print $2}')
WXP=$(echo "$OUT" | grep -oE "WXP: 0x[0-9a-fA-F]{40}" | awk '{print $2}')
echo "WXP:   $WXP"
echo "VAULT: $VAULT"
echo "DIST:  $DIST"

ACC1=$(cast wallet address --private-key $PK1)
ACC2=$(cast wallet address --private-key $PK2)
ACC3=$(cast wallet address --private-key $PK3)
ANKR=$(cast keccak "ankr")
NANSEN=$(cast keccak "nansen")

echo "── registering partners (ankr, nansen) ──"
cast send $VAULT "registerPartner(bytes32,uint256)" $ANKR 0 --rpc-url $RPC --private-key $PK0 >/dev/null
cast send $VAULT "registerPartner(bytes32,uint256)" $NANSEN 0 --rpc-url $RPC --private-key $PK0 >/dev/null

echo "── staking: 6000 via ankr, 3500 via nansen, 2500 direct ──"
cast send $VAULT "depositNativeWithReferral(address,bytes32)" $ACC1 $ANKR --value 6000ether --rpc-url $RPC --private-key $PK1 >/dev/null
cast send $VAULT "depositNativeWithReferral(address,bytes32)" $ACC2 $NANSEN --value 3500ether --rpc-url $RPC --private-key $PK2 >/dev/null
cast send $VAULT "depositNative(address)" $ACC3 --value 2500ether --rpc-url $RPC --private-key $PK3 >/dev/null

echo "── pinning cap to TVL (full utilization demo) ──"
cast send $VAULT "setStakeCap(uint256)" 12000ether --rpc-url $RPC --private-key $PK0 >/dev/null

echo "── funding 200 XP validator rewards, advancing 1 day, settling ──"
cast send $DIST --value 200ether --rpc-url $RPC --private-key $PK0 >/dev/null
cast rpc evm_increaseTime 86401 --rpc-url $RPC >/dev/null
cast rpc evm_mine --rpc-url $RPC >/dev/null
cast send $DIST "settle()" --rpc-url $RPC --private-key $PK0 >/dev/null

echo ""
echo "═══ ON-CHAIN STATE (compare with the dashboard) ═══"
echo "TVL:        $(cast call $VAULT 'totalAssets()(uint256)' --rpc-url $RPC)"
echo "burned:     $(cast call $DIST 'totalBurned()(uint256)' --rpc-url $RPC)"
echo "currentAPR: $(cast call $VAULT 'currentAPR()(uint256)' --rpc-url $RPC)"
echo "ankr TVL:   $(cast call $VAULT 'partnerTVL(bytes32)(uint256)' $ANKR --rpc-url $RPC)"
echo "nansen TVL: $(cast call $VAULT 'partnerTVL(bytes32)(uint256)' $NANSEN --rpc-url $RPC)"
echo ""
echo "Expected on the dashboard: TVL 12.0K XP · burned 80 XP · APR 365% · ankr 6.0K · nansen 3.5K"
echo "(utilization model: with the real 35M cap, distribution scales by staked/cap and the rest burns)"
