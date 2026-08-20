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

  // Capacity display. The on-chain cap is the only thing that can reject a
  // deposit, so progress is measured against it rather than a marketing
  // target — at 100% the two must not disagree.
  //
  // The cap is deliberately held at 35M through the event; nothing here
  // should imply an imminent raise. What does free up is maturing unstake
  // requests, and that is a fact with a date, so it is worth saying.
  round: {
    enabled: true,
    label: "Round 4",
    nearFullPct: 99, // switch to the urgent state past this fill level
    fullNote: "Deposits already made keep earning — nothing changes for them.",
    reopenNote: "Capacity frees up as unstaking requests mature, the next batch on Aug 22.",
  },

  // Where someone with no XP goes to get some. Leave `url` empty to drop the
  // Buy XP links entirely rather than pointing them at a dead page.
  buyXp: {
    name: "MEXC",
    url: "https://www.mexc.com/exchange/XP_USDT",
  },

  // Partner slugs shown on the leaderboard. partnerId = keccak256(slug).
  partners: ["ankr", "nansen"],

  // Must track the on-chain stakeCap. It labels every static "of N cap"
  // mention on the page, so a stale value here contradicts the live figure
  // sitting next to it.
  stakeCapXP: 35_000_000,

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
