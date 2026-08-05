// SPDX-License-Identifier: MIT
//
// DefiLlama Yield-Server adapter skeleton for the Xphere Union Staking Vault.
//
// Drop this into DefiLlama/yield-server `src/adaptors/xphere-union-staking/index.js`
// and adjust the CONFIG block. The vault exposes every field this adapter needs
// through read-only calls, so no subgraph or off-chain indexer is required.
//
// Pool shape returned matches the DefiLlama yield adapter spec:
//   https://github.com/DefiLlama/yield-server#adding-a-new-project

const { request, gql } = require('graphql-request'); // unused placeholder; kept for parity
const sdk = require('@defillama/sdk');

// ---------------------------------------------------------------------------
// CONFIG — fill in on mainnet deployment
// ---------------------------------------------------------------------------
const CONFIG = {
  chain: 'xphere', // DefiLlama chain slug (coordinate with DefiLlama if not yet listed)
  vault: '0x0000000000000000000000000000000000000000', // XPStakingVault address
  // XP price feed. If XP is not yet on DefiLlama price API, supply a manual/oracle price.
  xpCoinId: 'coingecko:xphere', // adjust to the correct price key
  xpDecimals: 18,
  project: 'xphere-union-staking',
  symbol: 'XP',
  poolId: 'xphere-union-staking-xp', // stable unique id
};

const PRECISION = 1e18;

// Minimal ABI — only the views the adapter consumes.
const ABI = {
  totalAssets: 'function totalAssets() view returns (uint256)',
  currentAPR: 'function currentAPR() view returns (uint256)',
  stakeCap: 'function stakeCap() view returns (uint256)',
  cooldownPeriod: 'function cooldownPeriod() view returns (uint256)',
};

async function readVault(fn) {
  const { output } = await sdk.api.abi.call({
    target: CONFIG.vault,
    abi: ABI[fn],
    chain: CONFIG.chain,
  });
  return output;
}

// Convert the vault's 1e18-scaled APR (1e18 == 100%) into a percentage number.
function aprToPct(rawApr) {
  return (Number(rawApr) / PRECISION) * 100;
}

async function getXpPriceUsd() {
  // Prefer DefiLlama's price API; fall back to a manual price if XP is unlisted.
  try {
    const res = await sdk.api2 /* or fetch from https://coins.llama.fi/prices/current/${CONFIG.xpCoinId} */;
    if (res && res.price) return res.price;
  } catch (_) {
    /* fall through */
  }
  return Number(process.env.XP_PRICE_USD || '0'); // set XP_PRICE_USD until XP is on the price API
}

async function apy() {
  const [totalAssets, rawApr, price] = await Promise.all([
    readVault('totalAssets'),
    readVault('currentAPR'),
    getXpPriceUsd(),
  ]);

  const tvlXp = Number(totalAssets) / 10 ** CONFIG.xpDecimals;
  const tvlUsd = tvlXp * price;
  const apyBase = aprToPct(rawApr); // reward APR is the base yield (no incentive token)

  return [
    {
      pool: CONFIG.poolId,
      chain: CONFIG.chain,
      project: CONFIG.project,
      symbol: CONFIG.symbol,
      tvlUsd,
      apyBase, // effective APR = inflow * 60% * 365 / TVL, self-adjusting
      underlyingTokens: [CONFIG.vault],
      // The 40% burn is protocol-level deflation, not a staker yield component,
      // so it is intentionally NOT added to apyBase. Surface it in the project page
      // via totalBurned() if desired.
      poolMeta: '7-day unstaking cooldown',
    },
  ];
}

module.exports = {
  timetravel: false,
  apy,
  url: 'https://stake.x-phere.com',
};
