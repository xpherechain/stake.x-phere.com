/* ============================================================
   Deployment config — Xphere MAINNET (guarded launch).
   Cap starts at 2M XP during the external audit window and is
   raised to 35M via Timelock (setStakeCap) at full open.
   ============================================================ */
window.XP_CONFIG = {
  chain: {
    chainId: 20250217,
    chainName: "Xphere",
    rpcUrl: "https://rpc.ankr.com/xphere_mainnet",
    nativeCurrency: { name: "XP", symbol: "XP", decimals: 18 },
    blockExplorerUrl: "https://xpscan.io",
  },

  // Deployed 2026-08 (see docs/MAINNET.md).
  contracts: {
    wxp: "0x780E8c0443F6d702De0c72650648C7CAA591e8f0",
    vault: "0xaE4435bB474716E130be2aC8e6C244f171451064",
    distributor: "0x24C5912B63a8B41DA80EBDC2115949fcbb41Fddf",
    commission: "0x0000000000000000000000000000000000000000", // off-chain settlement
  },

  // Governance holders (admin console role checks).
  governance: {
    timelock: "0x0737B4EEB4dA0920cE7CeE2D1eF64E0f57211F4E",
    safe: "0x134f29183fD9399060A3B3AE108f65D4ba23aa42", // interim governance EOA
  },

  // live:true → no preview modal/ribbon, real on-chain data.
  launch: { live: true },

  // Feature flags. zigap: QR-wallet connect via the ZIGAP app.
  features: { zigap: true },

  // Partner slugs shown on the leaderboard. partnerId = keccak256(slug).
  partners: ["ankr", "nansen"],

  // Current stake cap (guarded launch), in whole XP. Raise to 35_000_000
  // together with the on-chain setStakeCap at full open.
  stakeCapXP: 2_000_000,
};
