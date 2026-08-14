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

  // Round-one cap is filling. Warn while there is still room, and say when
  // the next tranche lands once there is none — a deposit that reverts with
  // no explanation is the worst version of this moment.
  // `at` is the timelock's executable time; clear the block once it is raised.
  // Timelock puts the raise at 2026-08-14 09:19:32 UTC; 09:20 is the first
  // clean minute after it. Both zones are spelled out — the audience is split
  // between them and "18:20" alone has been misread before.
  // Rollout is communicated in rounds. The on-chain cap is raised in one step
  // and stays the real limit — this is only the target the current round is
  // working towards, so progress reads against something reachable instead of
  // a number the vault will not approach for months.
  // Deposits are never blocked by this; only the on-chain cap can do that.
  // Bump `label`/`target` when a round is met.
  round: {
    enabled: true,
    label: "Round 2",
    target: 5_000_000,
    openedLabel: "Round 1 closed at 2M — Round 2 is live",
  },

  // Where someone with no XP goes to get some. Leave `url` empty to drop the
  // Buy XP links entirely rather than pointing them at a dead page.
  buyXp: {
    name: "MEXC",
    url: "https://www.mexc.com/exchange/XP_USDT",
  },

  // Partner slugs shown on the leaderboard. partnerId = keccak256(slug).
  partners: ["ankr", "nansen"],

  // Current stake cap (guarded launch), in whole XP. Raise to 35_000_000
  // together with the on-chain setStakeCap at full open.
  stakeCapXP: 2_000_000,

  // Temporary top band. Shown only between startsAt and endsAt, so it appears
  // and disappears on its own — no deploy needed at either end. Times are UTC;
  // the comments give the KST the campaign was booked in.
  // Set enabled:false to pull it early.
  banner: {
    enabled: true,
    badge: "EVENT",
    title: "Bonus XP for early stakers + big stakers",
    body: "Stake in the first wave to lock in an early bonus, or stake a large amount for a size bonus — qualify for both and they stack.",
    cta: "Enter now",
    href: "https://forms.gle/6UhKFCCwewsWDAgW8",
    startsAt: "2026-08-12T07:00:00Z", // Wed 12 Aug, 16:00 KST
    endsAt: "2026-08-25T15:00:00Z", // Tue 25 Aug, 24:00 KST
  },
};
