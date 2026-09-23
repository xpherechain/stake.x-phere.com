/* ============================================================
   Deployment config — Xphere MAINNET.
   Cap history, all via Timelock (setStakeCap), 48h delay honoured
   each time: 2M at the guarded launch (2026-08-03) → 35M
   (2026-08-14) → 70M (2026-09-16). stakeCapXP below must track
   whatever stakeCap() currently returns.
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
    // A single EOA, not a multisig — there is no contract code at this address
    // on-chain. It holds PAUSER and PARTNER_MANAGER on the vault, and it is the
    // sole proposer, executor AND canceller on the timelock, so one key both
    // schedules and executes every parameter change; the 48h delay is the only
    // thing standing between it and the vault. Previously named `safe`, which
    // read as a Gnosis Safe and is not one. Nothing in the site reads this key.
    admin: "0x134f29183fD9399060A3B3AE108f65D4ba23aa42",
  },

  // live:true → no preview modal/ribbon, real on-chain data.
  launch: { live: true },

  // Feature flags. zigap: QR-wallet connect via the ZIGAP app.
  features: { zigap: true },

  // Capacity display. The on-chain cap is the only thing that can reject a
  // deposit, so progress is measured against it rather than a marketing
  // target — at 100% the two must not disagree.
  //
  // The cap sits at 70M and nothing here should imply an imminent raise —
  // a raise costs APR permanently, because APR is a function of the cap and
  // the daily inflow only (see ops/raise-cap.sh plan).
  round: {
    enabled: true,
    label: "Round 4",
    nearFullPct: 99, // switch to the urgent state past this fill level
    fullNote: "Deposits already made keep earning — nothing changes for them.",
    // No date here on purpose. Requests are made continuously, so naming "the
    // next batch" pins the copy to a day that passes — this line sat three
    // weeks stale on the live site saying Aug 22.
    //
    // The old wording said capacity frees up as requests *mature*, which is
    // backwards: requestRedeem() does `totalStakedAssets -= assets` up front,
    // and maxDeposit is `stakeCap - totalStakedAssets`, so the seat opens when
    // the request is made and the 7-day cooldown frees nothing further. Anyone
    // who read it as "wait for the pending 202k to land" was waiting for a
    // seat that had already been taken.
    reopenNote: "Capacity opens the moment someone requests an unstake, not when their cooldown ends.",
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
  stakeCapXP: 70_000_000,

  // Temporary top band. Shown only between startsAt and endsAt, so it appears
  // and disappears on its own — no deploy needed at either end. Times are UTC;
  // the comments give the KST the campaign was booked in.
  // Set enabled:false to pull it early.
  banner: {
    enabled: true,
    badge: "CAMPAIGN",
    title: "Nansen × XPHERE Staking Campaign is LIVE",
    // The vault has been at its cap since the 70M raise, so the original copy
    // ("Stake 3,000 XP or more … to qualify") asked for something nobody could
    // do: maxDeposit() is effectively zero. The constraint goes first, before
    // the ask, and says where a seat actually comes from — capacity opens when
    // someone REQUESTS an unstake, not when a cooldown ends (see reopenNote).
    //
    // Deliberately no cap figure here: check-web-consistency.py only scans
    // index.html, so a number in this string would go stale on the next raise
    // with nothing to catch it. The round band below already shows the live one.
    body: "The vault is currently at its cap — a seat opens the moment another staker requests an unstake. Stake 3,000 XP or more through the Nansen Staking Hub to qualify for a share of the 247,000 XP reward pool.",
    cta: "Learn more about how to participate", // the arrow is added by CSS
    href: "https://x.com/Xphere_official/status/2100117486834270366?s=20",
    startsAt: "2026-09-16T00:00:00Z",
    // No end date was given. Unset means it runs until someone sets one or
    // flips enabled — the previous banner hid itself on its end date and this
    // one cannot. Put the real date here as soon as it is known, or this ends
    // up advertising a finished campaign the way the "next batch on Aug 22"
    // line did for three weeks.
    endsAt: null,
  },
};
