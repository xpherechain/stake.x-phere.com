#!/usr/bin/env bash
# ============================================================
# Xphere testnet deploy via `forge create` + `cast` wiring.
#
# NOTE: `forge script --broadcast` fails on the Ankr Xphere testnet RPC
# (batched broadcast reverts the first deploy). Deploying each contract
# individually with `forge create` and wiring with `cast send` is reliable
# — recommended for mainnet on this chain too.
#
# Required env:
#   RPC   testnet RPC (https://rpc.ankr.com/xphere_testnet)
#   PK    deployer private key (also used as Safe on testnet)
# Optional:
#   SAFE            pauser/partner-manager holder (default: deployer)
#   TIMELOCK_DELAY  seconds (default 120 for testnet; 172800 = 48h mainnet)
#   CAP             stake cap in wei (default 100,000 XP for testnet)
# ============================================================
set -euo pipefail
: "${RPC:?set RPC}"; : "${PK:?set PK}"
DEPLOYER=$(cast wallet address --private-key $PK)
SAFE="${SAFE:-$DEPLOYER}"
DELAY="${TIMELOCK_DELAY:-120}"
CAP="${CAP:-100000000000000000000000}"   # 100,000 ether
BURN=0x000000000000000000000000000000000000dEaD

cr() { forge create "$1" --rpc-url $RPC --private-key $PK --broadcast ${2:+--constructor-args} ${2:-} 2>/dev/null | grep "Deployed to:" | awk '{print $3}'; }
s()  { cast send "$1" "$2" ${3:-} ${4:-} --rpc-url $RPC --private-key $PK >/dev/null; }

echo "deployer=$DEPLOYER  safe=$SAFE  timelock delay=${DELAY}s  cap(wei)=$CAP"

echo "1) WXP";       WXP=$(cr src/WXP.sol:WXP)
echo "2) Vault";     VAULT=$(forge create src/XPStakingVault.sol:XPStakingVault --rpc-url $RPC --private-key $PK --broadcast \
                        --constructor-args $WXP $CAP 600 86400 300 60 86400 $DEPLOYER 2>/dev/null | grep "Deployed to:" | awk '{print $3}')
echo "3) Distributor"; DIST=$(forge create src/RewardDistributor.sol:RewardDistributor --rpc-url $RPC --private-key $PK --broadcast \
                        --constructor-args $VAULT $WXP $BURN $DEPLOYER 6000 300 60 86400 1000000000000000000 2>/dev/null | grep "Deployed to:" | awk '{print $3}')
echo "4) Timelock";  TL=$(forge create lib/openzeppelin-contracts/contracts/governance/TimelockController.sol:TimelockController --rpc-url $RPC --private-key $PK --broadcast \
                        --constructor-args $DELAY "[$SAFE]" "[$SAFE]" 0x0000000000000000000000000000000000000000 2>/dev/null | grep "Deployed to:" | awk '{print $3}')

DISTR=$(cast keccak "DISTRIBUTOR_ROLE"); PARAM=$(cast keccak "PARAM_ADMIN_ROLE")
PAUSER=$(cast keccak "PAUSER_ROLE"); PM=$(cast keccak "PARTNER_MANAGER_ROLE")
DA=0x0000000000000000000000000000000000000000000000000000000000000000

echo "5) wire distributor + partners"
s $VAULT "grantRole(bytes32,address)" $DISTR $DIST
s $VAULT "setDistributor(address)" $DIST
s $VAULT "registerPartner(bytes32,uint256)" "$(cast keccak "ankr")" 0
s $VAULT "registerPartner(bytes32,uint256)" "$(cast keccak "nansen")" 0

echo "6) governance handoff (PARAM/ADMIN→Timelock, PAUSER/PM→Safe, deployer renounce)"
s $VAULT "grantRole(bytes32,address)" $PARAM $TL
s $VAULT "grantRole(bytes32,address)" $DA $TL
s $VAULT "grantRole(bytes32,address)" $PAUSER $SAFE
s $VAULT "grantRole(bytes32,address)" $PM $SAFE
s $DIST  "grantRole(bytes32,address)" $PARAM $TL
s $DIST  "grantRole(bytes32,address)" $DA $TL
s $VAULT "renounceRole(bytes32,address)" $PARAM $DEPLOYER
s $VAULT "renounceRole(bytes32,address)" $PM $DEPLOYER
s $VAULT "renounceRole(bytes32,address)" $PAUSER $DEPLOYER
s $DIST  "renounceRole(bytes32,address)" $PARAM $DEPLOYER
s $DIST  "renounceRole(bytes32,address)" $DA $DEPLOYER
s $VAULT "renounceRole(bytes32,address)" $DA $DEPLOYER

echo
echo "════════ deployed & wired ════════"
echo "WXP:        $WXP"
echo "Vault:      $VAULT"
echo "Distributor:$DIST"
echo "Timelock:   $TL"
echo "$WXP $VAULT $DIST $TL"
