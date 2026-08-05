/* ============================================================
   XP Burn theatre — full-screen live burn counter, daily chart,
   and burn log. Counter reads the chain; history reads the daily
   stats feed (data/stats.json) written by the keeper.
   ============================================================ */
(() => {
  "use strict";
  const CFG = window.XP_CONFIG;
  const E = ethers;

  const DIST_ABI = [
    "function totalBurned() view returns (uint256)",
    "function pendingSettlement() view returns (uint256)",
    "function nextSettleTime() view returns (uint256)",
    "function burnAddress() view returns (address)",
    "function lastSettlement() view returns (uint64 settledAt, uint256 totalAmount, uint256 burned, uint256 distributed)",
  ];
  const VAULT_ABI = [
    "function totalAssets() view returns (uint256)",
    "function stakeCap() view returns (uint256)",
  ];

  const provider = new E.JsonRpcProvider(CFG.chain.rpcUrl, undefined, { batchMaxCount: 8 });
  const dist = new E.Contract(CFG.contracts.distributor, DIST_ABI, provider);
  const vault = new E.Contract(CFG.contracts.vault, VAULT_ABI, provider);

  const $ = (id) => document.getElementById(id);
  const fe = (w) => Number(E.formatEther(w ?? 0n));
  const fn = (n, dp = 2) => n.toLocaleString("en-US", { maximumFractionDigits: dp });

  // ── live reads: counter + countdown ──
  // The counter ticks in real time: confirmed on-chain burn + today's burn
  // accruing second-by-second (rate self-calibrated from the last
  // settlement's size, reconciled against the chain every refresh).
  let nextTs = 0;
  let base = 0; // confirmed totalBurned (XP)
  let rate = 0; // accruing burn (XP per second)
  let anchor = 0; // last settle timestamp
  async function load() {
    try {
      const [burned, pending, next, burnAddr, tvl, cap, lastS] = await Promise.all([
        dist.totalBurned(),
        dist.pendingSettlement().catch(() => 0n),
        dist.nextSettleTime().catch(() => 0n),
        dist.burnAddress().catch(() => null),
        vault.totalAssets().catch(() => 0n),
        vault.stakeCap().catch(() => 0n),
        dist.lastSettlement().catch(() => null),
      ]);
      base = fe(burned);
      nextTs = Number(next);
      const burnShare = fe(cap) > 0 ? 1 - 0.6 * Math.min(1, fe(tvl) / fe(cap)) : 1;
      $("counter").textContent = fn(base);
      if (lastS && Number(lastS.settledAt) > 0) {
        rate = (fe(lastS.totalAmount) * burnShare) / 86400;
        anchor = Number(lastS.settledAt);
        $("rateLine").innerHTML = `growing <b>≈${rate.toFixed(5)} XP</b> every second`;
      }
      if (burnAddr) $("burnAddrLink").href = `${CFG.chain.blockExplorerUrl}/address/${burnAddr}`;
    } catch (_) {
      /* keep last values; retry on next cycle */
    }
  }
  // 100ms tick — the last digits visibly roll, like a meter running
  setInterval(() => {
    if (rate <= 0 || !anchor) return;
    const elapsed = Date.now() / 1000 - anchor;
    const cap = rate * 86400;
    const accrued = Math.min(rate * elapsed, cap);
    $("rateLine").innerHTML =
      accrued >= cap
        ? "today's burn fully accrued — <b>waiting for the settlement</b> 🔥"
        : `growing <b>≈${rate.toFixed(5)} XP</b> every second`;
    $("accr").textContent =
      "+" +
      accrued.toLocaleString("en-US", {
        minimumFractionDigits: 4,
        maximumFractionDigits: 4,
      }) + " XP";
  }, 100);
  setInterval(() => {
    if (!nextTs) return;
    const s = nextTs - Math.floor(Date.now() / 1000);
    if (s <= 0) {
      $("cd").textContent = "settling…";
      return;
    }
    const h = String(Math.floor(s / 3600)).padStart(2, "0");
    const m = String(Math.floor((s % 3600) / 60)).padStart(2, "0");
    const sec = String(s % 60).padStart(2, "0");
    $("cd").textContent = `${h}:${m}:${sec}`;
  }, 1000);

  // ── history: daily chart + log from the keeper-written stats feed ──
  async function loadHistory() {
    let days = [];
    try {
      const res = await fetch("data/stats.json", { cache: "no-store" });
      days = (await res.json()).days || [];
    } catch (_) {}
    const chart = $("chart");
    const log = $("log");
    if (!days.length) {
      chart.innerHTML = '<span class="chart-empty">history will appear after the next settlement</span>';
      log.innerHTML = '<div class="row"><span class="d">—</span><span class="note">no settlements recorded yet</span></div>';
      return;
    }
    const recent = days.slice(-30);
    const max = Math.max(...recent.map((d) => d.burned), 1);
    chart.innerHTML = recent
      .map((d) => {
        const h = Math.max(2, (d.burned / max) * 100);
        return `<div class="col">
          <span class="val">${fn(d.burned)} XP</span>
          <div class="bar" style="height:${h}%"></div>
          <span class="lbl">${d.date.slice(5)}</span>
        </div>`;
      })
      .join("");
    log.innerHTML = [...recent]
      .reverse()
      .map(
        (d) => `<div class="row">
          <span class="d">${d.date}</span>
          <span class="amt">🔥 ${fn(d.burned)} XP burned</span>
          <span class="spacer"></span>
          <span class="note">${fn(d.distributed)} XP to stakers · settled ${fn(d.settled)} XP</span>
        </div>`
      )
      .join("");
  }

  // ── full-screen ember field ──
  function embers() {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const cv = $("embers");
    const ctx = cv.getContext("2d");
    let W, H;
    const resize = () => {
      W = cv.width = innerWidth;
      H = cv.height = innerHeight;
    };
    resize();
    addEventListener("resize", resize);
    const spawn = () => ({
      x: Math.random() * W,
      y: H + 6,
      r: 0.8 + Math.random() * 2.6,
      s: 0.3 + Math.random() * 1.1,
      a: 0.25 + Math.random() * 0.45,
      hue: 12 + Math.random() * 32,
    });
    const parts = Array.from({ length: 60 }, () => {
      const p = spawn();
      p.y = Math.random() * H;
      return p;
    });
    (function frame() {
      if (!document.hidden) {
        ctx.clearRect(0, 0, W, H);
        for (const p of parts) {
          p.y -= p.s;
          p.x += Math.sin(p.y / 22) * 0.4;
          p.a -= 0.001;
          if (p.y < -6 || p.a <= 0) Object.assign(p, spawn());
          ctx.beginPath();
          ctx.arc(p.x, p.y, p.r, 0, 7);
          ctx.fillStyle = `hsla(${p.hue}, 92%, 58%, ${p.a})`;
          ctx.fill();
        }
      }
      requestAnimationFrame(frame);
    })();
  }

  load();
  setInterval(load, 30_000);
  loadHistory();
  embers();
})();
