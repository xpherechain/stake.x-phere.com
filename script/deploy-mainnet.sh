#!/usr/bin/env bash
# ============================================================
# Xphere MAINNET deploy — forge create + cast wiring.
# (`forge script --broadcast` fails on Ankr Xphere RPCs; per-contract
#  deploy + cast wiring is the method proven on testnet.)
#
# Guarded-launch defaults (policy C): CAP starts at 2M XP and is raised
# to 35M later via Timelock (setStakeCap — path rehearsed on testnet).
#
# Required env:
#   PK      NEW deployer key (never the testnet key), funded with gas XP
#   SAFE    interim governance EOA/multisig — holds PAUSER + PARTNER_MANAGER,
#           and is sole proposer/executor on the Timelock. REQUIRED on mainnet
#           (no deployer fallback: the deployer key is treated as disposable).
# Optional env (defaults = confirmed mainnet policy):
#   RPC             default https://rpc.ankr.com/xphere_mainnet
#   CAP             default 2,000,000 ether (guarded launch; full = 35M)
#   TIMELOCK_DELAY  default 172800 (48h)
#   MIN_SETTLE      default 100 ether
# ============================================================
set -euo pipefail
: "${PK:?set PK (new mainnet deployer key)}"
: "${SAFE:?set SAFE (interim governance address — do NOT default to deployer on mainnet)}"
RPC="${RPC:-https://rpc.ankr.com/xphere_mainnet}"
CAP="${CAP:-2000000000000000000000000}"          # 2M ether (guarded)
DELAY="${TIMELOCK_DELAY:-172800}"                 # 48h
MIN_SETTLE="${MIN_SETTLE:-100000000000000000000}" # 100 ether
BURN=0x000000000000000000000000000000000000dEaD

# ── mainnet parameters (LAUNCH_CHECKLIST Phase 0) ──
COOLDOWN=604800        # 7d
MAX_COOLDOWN=2592000   # 30d  (immutable upper bound — cannot be raised later)
RD=86400               # rewards stream 1d
MIN_RD=3600            # 1h
MAX_RD=2592000         # 30d  (immutable)
RATIO=6000             # 60% stakers at full cap
EPOCH=86400            # settle 1d
MIN_EPOCH=3600         # 1h   (immutable)
MAX_EPOCH=2592000      # 30d  (immutable)

# ── pre-flight ──
CHAIN=$(cast chain-id --rpc-url $RPC)
[ "$CHAIN" = "20250217" ] || { echo "ABORT: chainId $CHAIN != 20250217 (Xphere mainnet)"; exit 1; }
DEPLOYER=$(cast wallet address --private-key $PK)
BAL=$(cast balance $DEPLOYER --rpc-url $RPC)
echo "deployer=$DEPLOYER  balance=$(cast to-unit $BAL ether) XP"
python3 -c "exit(0 if $BAL > 10*10**18 else 1)" || { echo "ABORT: deployer needs >10 XP gas"; exit 1; }
[ "$(cast code $BURN --rpc-url $RPC)" = "0x" ] || { echo "ABORT: burn address has code"; exit 1; }
echo "safe=$SAFE  timelock=${DELAY}s  cap(wei)=$CAP  minSettle(wei)=$MIN_SETTLE"
read -p "Deploy to MAINNET with the above? (yes/no) " ok; [ "$ok" = "yes" ] || exit 1

s() { cast send "$1" "$2" ${3:-} ${4:-} --rpc-url $RPC --private-key $PK >/dev/null; }
cr() { grep "Deployed to:" | awk '{print $3}'; }

echo "1) WXP"
WXP=$(forge create src/WXP.sol:WXP --rpc-url $RPC --private-key $PK --broadcast 2>/dev/null | cr)
echo "   $WXP"
echo "2) Vault"
VAULT=$(forge create src/XPStakingVault.sol:XPStakingVault --rpc-url $RPC --private-key $PK --broadcast \
  --constructor-args $WXP $CAP $COOLDOWN $MAX_COOLDOWN $RD $MIN_RD $MAX_RD $DEPLOYER 2>/dev/null | cr)
echo "   $VAULT"
echo "3) Distributor"
DIST=$(forge create src/RewardDistributor.sol:RewardDistributor --rpc-url $RPC --private-key $PK --broadcast \
  --constructor-args $VAULT $WXP $BURN $DEPLOYER $RATIO $EPOCH $MIN_EPOCH $MAX_EPOCH $MIN_SETTLE 2>/dev/null | cr)
echo "   $DIST"
echo "4) Timelock (${DELAY}s)"
TL=$(forge create lib/openzeppelin-contracts/contracts/governance/TimelockController.sol:TimelockController \
  --rpc-url $RPC --private-key $PK --broadcast \
  --constructor-args $DELAY "[$SAFE]" "[$SAFE]" 0x0000000000000000000000000000000000000000 2>/dev/null | cr)
echo "   $TL"

DISTR=$(cast keccak "DISTRIBUTOR_ROLE"); PARAM=$(cast keccak "PARAM_ADMIN_ROLE")
PAUSER=$(cast keccak "PAUSER_ROLE"); PM=$(cast keccak "PARTNER_MANAGER_ROLE")
DA=0x0000000000000000000000000000000000000000000000000000000000000000

echo "5) wire distributor + partners"
s $VAULT "grantRole(bytes32,address)" $DISTR $DIST
s $VAULT "setDistributor(address)" $DIST
s $VAULT "registerPartner(bytes32,uint256)" "$(cast keccak "ankr")" 0
s $VAULT "registerPartner(bytes32,uint256)" "$(cast keccak "nansen")" 0

echo "6) governance handoff + deployer renounce"
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

echo "7) on-chain verification"
v() { cast call "$1" "hasRole(bytes32,address)(bool)" "$2" "$3" --rpc-url $RPC | awk '{print $1}'; }
echo "   vault PARAM→TL:    $(v $VAULT $PARAM $TL)   (want true)"
echo "   vault ADMIN→TL:    $(v $VAULT $DA $TL)   (want true)"
echo "   vault PAUSER→SAFE: $(v $VAULT $PAUSER $SAFE)   (want true)"
echo "   vault PM→SAFE:     $(v $VAULT $PM $SAFE)   (want true)"
echo "   vault ADMIN→deployer: $(v $VAULT $DA $DEPLOYER)   (want false)"
echo "   dist  ADMIN→deployer: $(v $DIST $DA $DEPLOYER)   (want false)"
echo "   dist wired in vault:  $(cast call $VAULT 'distributor()(address)' --rpc-url $RPC)"

echo
echo "════════ MAINNET DEPLOYED ════════"
echo "WXP:         $WXP"
echo "Vault:       $VAULT"
echo "Distributor: $DIST"
echo "Timelock:    $TL"
echo
echo "──── paste into web/config.js ────"
cat <<EOF
  chain: {
    chainId: 20250217,
    chainName: "Xphere",
    rpcUrl: "$RPC",
    nativeCurrency: { name: "XP", symbol: "XP", decimals: 18 },
    blockExplorerUrl: "https://xpscan.io",
  },
  contracts: {
    wxp: "$WXP",
    vault: "$VAULT",
    distributor: "$DIST",
    commission: "0x0000000000000000000000000000000000000000",
  },
  launch: { live: true },
EOF
echo "──── next: docs/MAINNET_DEPLOY.md 체크리스트 계속 ────"
