/* ============================================================
   XP Union Vault — public live status & transparency page.
   Every number is read straight from the chain over RPC; the page
   holds no keys and can execute nothing. Auto-refreshes.
   ============================================================ */
(() => {
  "use strict";
  const CFG = window.XP_CONFIG;
  const E = ethers;
  const ZERO = "0x0000000000000000000000000000000000000000";
  const REFRESH_MS = 20_000;
  const SETTLE_GRACE_S = 6 * 3600; // overdue tolerance before we call it delayed

  const VAULT_ABI = [
    "function totalAssets() view returns (uint256)",
    "function totalPendingRedeem() view returns (uint256)",
    "function rewardReserves() view returns (uint256)",
    "function stakeCap() view returns (uint256)",
    "function cooldownPeriod() view returns (uint256)",
    "function rewardsDuration() view returns (uint256)",
    "function currentAPR() view returns (uint256)",
    "function periodFinish() view returns (uint256)",
    "function distributor() view returns (address)",
    "function paused() view returns (bool)",
    "function hasRole(bytes32,address) view returns (bool)",
    "function DEFAULT_ADMIN_ROLE() view returns (bytes32)",
    "function PARAM_ADMIN_ROLE() view returns (bytes32)",
    "function DISTRIBUTOR_ROLE() view returns (bytes32)",
  ];
  const DIST_ABI = [
    "function totalBurned() view returns (uint256)",
    "function totalDistributed() view returns (uint256)",
    "function pendingSettlement() view returns (uint256)",
    "function nextSettleTime() view returns (uint256)",
    "function epochDuration() view returns (uint256)",
    "function distributionRatioBps() view returns (uint16)",
    "function minSettleAmount() view returns (uint256)",
    "function lastSettlement() view returns (uint64 settledAt, uint256 totalAmount, uint256 burned, uint256 distributed)",
    "function burnAddress() view returns (address)",
  ];
  const ERC20_ABI = ["function balanceOf(address) view returns (uint256)"];

  // batchMaxCount:8 — the Ankr Xphere RPC rejects >10-call batches (413)
  // and rate-limits single-call floods (429).
  const provider = new E.JsonRpcProvider(CFG.chain.rpcUrl, undefined, { batchMaxCount: 8 });
  const vault = new E.Contract(CFG.contracts.vault, VAULT_ABI, provider);
  const dist = new E.Contract(CFG.contracts.distributor, DIST_ABI, provider);
  const wxp = new E.Contract(CFG.contracts.wxp, ERC20_ABI, provider);

  const $ = (id) => document.getElementById(id);
  const fe = (wei) => Number(E.formatEther(wei ?? 0n));
  const fn = (n, dp = 2) => n.toLocaleString("en-US", { maximumFractionDigits: dp });
  const short = (a) => (a && a !== ZERO ? a.slice(0, 8) + "…" + a.slice(-6) : "—");
  const exp = (a) => `${CFG.chain.blockExplorerUrl}/address/${a}`;
  const dur = (s) => {
    s = Number(s);
    if (s % 86400 === 0 && s >= 86400) return s / 86400 + (s === 86400 ? " day" : " days");
    if (s % 3600 === 0 && s >= 3600) return s / 3600 + "h";
    if (s % 60 === 0 && s >= 60) return s / 60 + "m";
    return s + "s";
  };
  const card = (k, v, cls = "", note = "") =>
    `<div class="card"><div class="k">${k}</div><div class="v ${cls}">${v}</div>${
      note ? `<div class="n">${note}</div>` : ""
    }</div>`;
  const kv = (k, v) => `<tr><td>${k}</td><td>${v}</td></tr>`;
  const P = (p) => p.catch(() => null);

  // next-settle countdown (rendered every second between refreshes)
  let nextTs = 0;
  let queuedTxt = "";
  setInterval(() => {
    const el = $("compSettleDesc");
    if (!el || !nextTs) return;
    const s = nextTs - Math.floor(Date.now() / 1000);
    if (s > 0) {
      const h = String(Math.floor(s / 3600)).padStart(2, "0");
      const m = String(Math.floor((s % 3600) / 60)).padStart(2, "0");
      const sec = String(s % 60).padStart(2, "0");
      el.textContent = `next settlement in ${h}:${m}:${sec}${queuedTxt}`;
    } else {
      el.textContent = `settlement due — runs automatically${queuedTxt}`;
    }
  }, 1000);

  async function load() {
    let block;
    try {
      block = await provider.getBlockNumber();
    } catch (_) {
      const b = $("errBanner");
      b.style.display = "block";
      b.textContent = "⚠ RPC unreachable (" + CFG.chain.rpcUrl + ") — retrying…";
      return;
    }
    $("errBanner").style.display = "none";

    const [
      tvl, pendingRedeem, reserves, cap, cooldown, rewardsDur, apr, periodFinish, distAddr, paused,
      burned, distributed, pending, nextSettle, epoch, ratioBps, minSettle, lastS, burnAddr,
      held,
    ] = await Promise.all([
      P(vault.totalAssets()), P(vault.totalPendingRedeem()), P(vault.rewardReserves()),
      P(vault.stakeCap()), P(vault.cooldownPeriod()), P(vault.rewardsDuration()),
      P(vault.currentAPR()), P(vault.periodFinish()), P(vault.distributor()), P(vault.paused()),
      P(dist.totalBurned()), P(dist.totalDistributed()), P(dist.pendingSettlement()),
      P(dist.nextSettleTime()), P(dist.epochDuration()), P(dist.distributionRatioBps()),
      P(dist.minSettleAmount()), P(dist.lastSettlement()), P(dist.burnAddress()),
      P(wxp.balanceOf(CFG.contracts.vault)),
    ]);

    const now = Math.floor(Date.now() / 1000);

    // ── health checks ──
    const oblig = (tvl ?? 0n) + (pendingRedeem ?? 0n) + (reserves ?? 0n);
    const solvent = held !== null && held >= oblig;
    const settleOver = nextSettle ? now - Number(nextSettle) : 0;
    const settleDelayed = settleOver > SETTLE_GRACE_S && pending !== null && fe(pending) > 0;
    const streaming = periodFinish && Number(periodFinish) > now;
    const issues = [];
    if (!solvent) issues.push("solvency check failed");
    if (paused) issues.push("deposits paused");
    if (settleDelayed) issues.push("settlement delayed");

    $("verdict").className = "verdict" + (issues.length ? " bad" : "");
    $("verdictText").textContent = issues.length
      ? "Attention needed — " + issues.join(" · ")
      : "All systems operational";

    // ── component rows ──
    nextTs = Number(nextSettle || 0);
    const utilization = cap && fe(cap) > 0 ? (fe(tvl) / fe(cap)) * 100 : 0;
    const burnShare =
      cap && fe(cap) > 0 ? 1 - (Number(ratioBps ?? 6000) / 10000) * Math.min(1, fe(tvl) / fe(cap)) : 1;
    queuedTxt =
      pending !== null && fe(pending) > 0
        ? ` · ≈${fn(fe(pending))} XP queued (≈${fn(fe(pending) * burnShare)} to burn)`
        : "";
    const settlePill = settleDelayed
      ? '<span class="pill bad">DELAYED</span>'
      : settleOver > 0
        ? '<span class="pill warn">DUE</span>'
        : '<span class="pill ok">ON SCHEDULE</span>';
    $("components").innerHTML = `
      <div class="comp"><span class="name">Vault solvency</span><span class="spacer"></span>
        <span class="desc">surplus ${solvent ? fn(fe(held - oblig)) : "—"} XP</span>
        ${solvent ? '<span class="pill ok">SOLVENT</span>' : '<span class="pill bad">CHECK FAILED</span>'}</div>
      <div class="comp"><span class="name">Daily settlement</span><span class="spacer"></span>
        <span class="desc" id="compSettleDesc">—</span>${settlePill}</div>
      <div class="comp"><span class="name">Reward stream</span><span class="spacer"></span>
        <span class="desc">${streaming ? "streaming to stakers, second by second" : "idle — starts at the next settlement with stakers"}</span>
        ${streaming ? '<span class="pill ok">STREAMING</span>' : '<span class="pill idle">IDLE</span>'}</div>
      <div class="comp"><span class="name">Deposits</span><span class="spacer"></span>
        <span class="desc">cap utilization ${fn(utilization, 2)}%</span>
        ${paused ? '<span class="pill bad">PAUSED</span>' : '<span class="pill ok">OPEN</span>'}</div>`;

    // ── metrics ──
    $("metrics").innerHTML =
      card("Total value locked", `${fn(fe(tvl))} <small>XP</small>`, "", `${fn(utilization, 2)}% of ${fn(fe(cap), 0)} XP cap`) +
      card("Staking APR", apr !== null ? (Number(apr) / 1e16).toFixed(2) + " <small>%</small>" : "—", "", "from real validator revenue") +
      card("Burned forever", `${fn(fe(burned))} <small>XP</small>`, "burn", "removed from supply") +
      card("Paid to stakers", `${fn(fe(distributed))} <small>XP</small>`, "ok", "lifetime distributed") +
      card("Queued for next burn", `${fn(fe(pending))} <small>XP</small>`, fe(pending) > 0 ? "warn" : "", "sitting in the distributor");

    // ── solvency proof ──
    const holdN = fe(held);
    const obligN = fe(oblig);
    const maxN = Math.max(holdN, obligN, 1e-9);
    $("pHold").textContent = fn(holdN) + " XP";
    $("pOwe").textContent = fn(obligN) + " XP";
    $("pBarHold").style.width = (holdN / maxN) * 100 + "%";
    $("pBarOwe").style.width = (obligN / maxN) * 100 + "%";
    $("proof").className = "proof" + (solvent ? "" : " bad");
    $("pVerdict").innerHTML = solvent
      ? `<b class="ok">✓ SOLVENT</b> — holdings cover obligations with ${fn(holdN - obligN)} XP to spare`
      : `<b class="bad">✗ CHECK FAILED</b> — holdings below obligations`;

    // ── last settlement ──
    if (lastS && Number(lastS.settledAt) > 0) {
      const when = new Date(Number(lastS.settledAt) * 1000);
      $("lastSettle").innerHTML =
        card("Settled at", when.toISOString().slice(0, 16).replace("T", " ") + " <small>UTC</small>") +
        card("Amount settled", `${fn(fe(lastS.totalAmount))} <small>XP</small>`) +
        card("Burned 🔥", `${fn(fe(lastS.burned))} <small>XP</small>`, "burn") +
        card("To stakers", `${fn(fe(lastS.distributed))} <small>XP</small>`, "ok");
    } else {
      $("lastSettle").innerHTML = card("Settled at", "—", "", "no settlement yet");
    }

    // ── parameters ──
    $("params").innerHTML =
      kv("Stake cap", fn(fe(cap), 0) + " XP") +
      kv("Unstake cooldown", dur(cooldown)) +
      kv("Reward stream window", dur(rewardsDur)) +
      kv("Settlement epoch", dur(epoch)) +
      kv("Staker share at full cap", Number(ratioBps ?? 0) / 100 + " %") +
      kv("Minimum settlement", fn(fe(minSettle), 0) + " XP");

    // ── governance ──
    const gov = CFG.governance || {};
    const rows = [];
    const link = (label, addr) =>
      kv(label, `<a href="${exp(addr)}" target="_blank" rel="noopener"><code>${short(addr)}</code></a>`);
    rows.push(link("Vault contract", CFG.contracts.vault));
    rows.push(link("Reward distributor", CFG.contracts.distributor));
    rows.push(link("WXP token", CFG.contracts.wxp));
    if (gov.timelock) rows.push(link("Timelock (48h, parameter changes)", gov.timelock));
    if (burnAddr) rows.push(link("Burn address", burnAddr));
    try {
      const [DA, PARAM, DISTR] = await Promise.all([
        vault.DEFAULT_ADMIN_ROLE(),
        vault.PARAM_ADMIN_ROLE(),
        vault.DISTRIBUTOR_ROLE(),
      ]);
      const check = async (label, role, addr) => {
        if (!addr) return;
        const has = await P(vault.hasRole(role, addr));
        rows.push(kv(label, has ? '<span class="pill ok">VERIFIED</span>' : '<span class="pill bad">NOT SET</span>'));
      };
      await check("Admin held by the timelock, not a person", DA, gov.timelock);
      await check("Parameter changes gated by the timelock", PARAM, gov.timelock);
      await check("Distributor wired to the vault", DISTR, distAddr);
    } catch (_) {
      /* role reads unavailable — links above still render */
    }
    $("gov").innerHTML = rows.join("");

    $("footLeft").textContent =
      `${CFG.chain.chainName} · chainId ${CFG.chain.chainId} · block #${block} · ` +
      `last read ${new Date().toISOString().slice(11, 19)} UTC`;
  }

  load();
  setInterval(load, REFRESH_MS);
})();
