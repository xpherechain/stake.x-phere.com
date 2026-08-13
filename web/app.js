/* ============================================================
   XP Union Vault — dashboard logic
   Reads on-chain state via RPC, executes writes via wallet.
   Falls back to demo data when contracts are not yet deployed.
   ============================================================ */
(() => {
  "use strict";
  const CFG = window.XP_CONFIG;
  const E = ethers;
  const ZERO = "0x0000000000000000000000000000000000000000";

  // ---- minimal human-readable ABIs ----
  const VAULT_ABI = [
    "function totalAssets() view returns (uint256)",
    "function currentAPR() view returns (uint256)",
    "function stakeCap() view returns (uint256)",
    "function partnerTVL(bytes32) view returns (uint256)",
    "function userPrincipal(address) view returns (uint256)",
    "function balanceOf(address) view returns (uint256)",
    "function earned(address) view returns (uint256)",
    "function userPartner(address) view returns (bytes32)",
    "function getUserRequestIds(address) view returns (uint256[])",
    "function redeemRequests(uint256) view returns (address controller, uint96 claimableAt, uint256 assets, bool claimed)",
    "function depositNative(address) payable returns (uint256)",
    "function depositNativeWithReferral(address,bytes32) payable returns (uint256)",
    "function requestRedeem(uint256,address,address) returns (uint256)",
    "function claimRedeemNative(uint256,address) returns (uint256)",
    "function claimRewardNative(address) returns (uint256)",
    "function cooldownPeriod() view returns (uint256)",
    "function rewardRate() view returns (uint256)",
    "function periodFinish() view returns (uint256)",
  ];
  const DIST_ABI = [
    "function totalBurned() view returns (uint256)",
    "function pendingSettlement() view returns (uint256)",
    "function nextSettleTime() view returns (uint256)",
    "function lastSettlement() view returns (uint64 settledAt, uint256 totalAmount, uint256 burned, uint256 distributed)",
    "function distributionRatioBps() view returns (uint16)",
    "function epochDuration() view returns (uint256)",
  ];

  const WXP_ABI = ["function balanceOf(address) view returns (uint256)"];

  const SHARE_UNIT = 1000n;
  const PARTNER_DIRECT = E.id("DIRECT");

  // ---- state ----
  const isConfigured = CFG.contracts.vault && CFG.contracts.vault !== ZERO && CFG.chain.rpcUrl;
  let readProvider = null;
  let signer = null;
  let account = null;
  let walletMode = null; // 'injected' | 'zigap'

  if (isConfigured) {
    try {
      // The Ankr Xphere RPC accepts JSON-RPC batches of ≤10 (HTTP 413 above
      // that) but rate-limits (429) a flood of single calls. batchMaxCount:8
      // stays under both limits.
      readProvider = new E.JsonRpcProvider(CFG.chain.rpcUrl, undefined, { batchMaxCount: 8 });
    } catch (_) {
      /* fall through to demo */
    }
  }
  const DEMO = !readProvider;

  // ---- helpers ----
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const pidOf = (slug) => E.id(slug);

  // ---- referral capture (redirect model) ----
  // Captures ?ref=<slug>, validates it against the registered-partner
  // allowlist, stores it for 30 days, and applies it on deposit. No manual
  // input; attribution comes only from the referring URL. On-chain, the
  // user's first deposit fixes their bucket permanently.
  const REF_KEY = "xp.ref";
  const REF_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30-day attribution window
  function captureReferral() {
    try {
      const url = new URL(window.location.href);
      const slug = (url.searchParams.get("ref") || "").trim().toLowerCase();
      if (slug && CFG.partners.includes(slug)) {
        localStorage.setItem(REF_KEY, JSON.stringify({ slug, ts: Date.now() }));
        // strip the param so it isn't bookmarked/edited around
        url.searchParams.delete("ref");
        history.replaceState(null, "", url.pathname + url.search + url.hash);
      }
    } catch (_) {
      /* storage unavailable → user simply deposits as direct */
    }
  }
  function activeReferral() {
    try {
      const raw = localStorage.getItem(REF_KEY);
      if (!raw) return null;
      const { slug, ts } = JSON.parse(raw);
      if (!CFG.partners.includes(slug) || Date.now() - ts > REF_TTL_MS) {
        localStorage.removeItem(REF_KEY);
        return null;
      }
      return slug;
    } catch (_) {
      return null;
    }
  }
  // Cap label ("2M", "35M", …) derived from config so guarded-launch cap
  // changes propagate to every static mention via <span data-cap>.
  function capLabel() {
    const n = CFG.stakeCapXP;
    return n >= 1_000_000 ? String(n / 1_000_000).replace(/\.0$/, "") + "M" : n.toLocaleString("en-US");
  }
  function wireCapLabels() {
    $$("[data-cap]").forEach((el) => (el.textContent = capLabel()));
  }

  function wireReferral() {
    captureReferral();
    const slug = activeReferral();
    const note = $("#refNote");
    if (note && slug) {
      $("#refPartner").textContent = slug;
      note.hidden = false;
    }
  }

  function fmtXP(wei, opts = {}) {
    const n = typeof wei === "bigint" ? Number(E.formatEther(wei)) : Number(wei);
    return fmtNum(n, opts);
  }
  function fmtNum(n, { compact = true, dp } = {}) {
    if (!isFinite(n)) return "—";
    if (compact && Math.abs(n) >= 1_000_000) return (n / 1_000_000).toFixed(2) + "M";
    if (compact && Math.abs(n) >= 1_000) return (n / 1_000).toFixed(1) + "K";
    return n.toLocaleString("en-US", { maximumFractionDigits: dp ?? (n < 1 ? 4 : 2) });
  }
  function shorten(a) {
    return a ? a.slice(0, 6) + "…" + a.slice(-4) : "—";
  }

  // animated number rollup
  function animateTo(el, target, render) {
    const start = performance.now();
    const from = 0;
    const dur = 1100;
    function tick(t) {
      const p = Math.min(1, (t - start) / dur);
      const eased = 1 - Math.pow(1 - p, 3);
      el.textContent = render(from + (target - from) * eased);
      if (p < 1) requestAnimationFrame(tick);
    }
    requestAnimationFrame(tick);
  }

  // ---- demo dataset (plausible mainnet-at-cap snapshot) ----
  const demo = {
    tvl: 21_400_000,
    apr: 0.169,
    burned: 3_960_000,
    cap: CFG.stakeCapXP,
  };

  // Last APR seen on-chain (fraction, e.g. 0.159) — used by the stake estimate.
  let lastApr = 0;

  // Next-burn state (set by loadDashboard, rendered by the countdown timer).
  let burnNextTs = 0;
  let burnQueued = 0;

  // Burn accrual estimate: confirmed on-chain total plus today's accrual
  // at the last-settlement run-rate; reconciled against the chain on refresh.
  let burnConfirmed = 0; // totalBurned on-chain (XP)
  let burnRatePerSec = 0; // today's burn accruing per second (XP/s)
  let burnAnchorTs = 0; // last settle timestamp
  function wireBurnLiveCounter() {
    const el = $('[data-metric="burnAccr"]');
    if (!el) return;
    setInterval(() => {
      if (burnRatePerSec <= 0 || burnAnchorTs <= 0) return;
      const elapsed = Date.now() / 1000 - burnAnchorTs;
      // cap at exactly one epoch: the sweep budget refills once per epoch
      const cap = burnRatePerSec * 86400;
      const accrued = Math.min(burnRatePerSec * elapsed, cap);
      const rl = $('[data-metric="burnRate"]');
      if (rl)
        rl.innerHTML =
          accrued >= cap
            ? `today's burn fully accrued — <b>waiting for the settlement</b> 🔥`
            : `burning <b>\u2248${burnRatePerSec.toFixed(5)} XP</b> every second, right now`;
      el.textContent =
        "+" +
        accrued.toLocaleString("en-US", {
          minimumFractionDigits: 3,
          maximumFractionDigits: 3,
        }) + " XP";
    }, 500);
  }

  // Earnings ticker state: on-chain accrual interpolated between RPC reads.
  let lastTvl = 0; // total staked (XP)
  let rrXPs = 0; // global rewardRate in XP/second
  let rrFinish = 0; // periodFinish timestamp
  let cooldownS = 604800; // unstake cooldown (refreshed from chain)
  let posEarned = 0; // earned (XP) at last position read
  let posPrincipal = 0; // my stake (XP)
  let posReadAt = 0; // when the position was read (s)

  function wireEarningsTicker() {
    setInterval(() => {
      if (!account || posReadAt === 0 || posPrincipal <= 0 || rrXPs <= 0 || lastTvl <= 0) return;
      const now = Date.now() / 1000;
      const until = Math.min(now, rrFinish || now);
      const elapsed = Math.max(0, until - posReadAt);
      const mine = posEarned + rrXPs * elapsed * (posPrincipal / lastTvl);
      const txt = mine.toLocaleString("en-US", { minimumFractionDigits: 6, maximumFractionDigits: 6 }) + " XP";
      setMe("rewards", txt);
      setMe("rewards2", txt);
    }, 1000);
  }

  // ---- next-burn countdown ----
  function wireBurnCountdown() {
    const el = $('[data-metric="burnNext"]');
    if (!el) return;
    setInterval(() => {
      if (!burnNextTs || burnQueued <= 0) {
        el.textContent = "";
        return;
      }
      const s = burnNextTs - Math.floor(Date.now() / 1000);
      if (s <= 0) {
        el.innerHTML = `🔥 settling now…`;
        return;
      }
      const h = String(Math.floor(s / 3600)).padStart(2, "0");
      const m = String(Math.floor((s % 3600) / 60)).padStart(2, "0");
      const sec = String(s % 60).padStart(2, "0");
      el.innerHTML = `burns in <b>${h}:${m}:${sec}</b> 🔥`;
    }, 1000);
  }

  // ---- ember particle canvas (burn band) ----
  function wireBurnEmbers() {
    const card = $(".burnband");
    if (!card || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const cv = document.createElement("canvas");
    cv.className = "burn-embers";
    card.prepend(cv);
    const ctx = cv.getContext("2d");
    let W = 0, H = 0, running = false;
    const resize = () => {
      W = cv.width = card.clientWidth;
      H = cv.height = card.clientHeight;
    };
    resize();
    window.addEventListener("resize", resize);
    const spawn = () => ({
      x: Math.random() * W,
      y: H + 4,
      r: 0.8 + Math.random() * 2.1,
      s: 0.25 + Math.random() * 0.8,
      a: 0.35 + Math.random() * 0.45,
      hue: 12 + Math.random() * 32,
    });
    const parts = Array.from({ length: 26 }, () => {
      const p = spawn();
      p.y = Math.random() * H; // scatter initial positions
      return p;
    });
    function frame() {
      if (!running) return;
      ctx.clearRect(0, 0, W, H);
      for (const p of parts) {
        p.y -= p.s;
        p.x += Math.sin(p.y / 16) * 0.35;
        p.a -= 0.0016;
        if (p.y < -4 || p.a <= 0) Object.assign(p, spawn());
        ctx.beginPath();
        ctx.arc(p.x, p.y, p.r, 0, 7);
        ctx.fillStyle = `hsla(${p.hue}, 92%, 58%, ${p.a})`;
        ctx.fill();
      }
      requestAnimationFrame(frame);
    }
    // animate only while on screen and the tab is visible
    const setRun = (v) => {
      if (v && !running) {
        running = true;
        frame();
      } else if (!v) {
        running = false;
      }
    };
    new IntersectionObserver((e) => setRun(e[0].isIntersecting && !document.hidden), {
      threshold: 0.1,
    }).observe(card);
    document.addEventListener("visibilitychange", () => setRun(!document.hidden));
  }

  // ============================================================
  //  DASHBOARD READS
  // ============================================================
  async function loadDashboard() {
    if (DEMO) {
      $("#demoBadge").hidden = false;
      renderMetrics({ tvl: demo.tvl, apr: demo.apr, burned: demo.burned, cap: demo.cap });
      return;
    }
    try {
      const vault = new E.Contract(CFG.contracts.vault, VAULT_ABI, readProvider);
      const dist = new E.Contract(CFG.contracts.distributor, DIST_ABI, readProvider);
      const [tvl, apr, cap, burned, pending, nextTs, rr, pf, cd, lastS, ratioBps, epochS] =
        await Promise.all([
          vault.totalAssets(),
          vault.currentAPR(),
          vault.stakeCap(),
          dist.totalBurned().catch(() => 0n),
          dist.pendingSettlement().catch(() => 0n),
          dist.nextSettleTime().catch(() => 0n),
          vault.rewardRate().catch(() => 0n),
          vault.periodFinish().catch(() => 0n),
          vault.cooldownPeriod().catch(() => 604800n),
          dist.lastSettlement().catch(() => null),
          dist.distributionRatioBps().catch(() => 0),
          dist.epochDuration().catch(() => 86400n),
        ]);
      lastTvl = Number(E.formatEther(tvl));
      rrXPs = Number(E.formatEther(rr));
      rrFinish = Number(pf);
      cooldownS = Number(cd);
      // live-burn calibration: daily run-rate ≈ last settlement size,
      // burn share from current utilization
      burnConfirmed = Number(E.formatEther(burned));
      if (lastS && Number(lastS.settledAt) > 0) {
        const capN = Number(E.formatEther(cap));
        const share = capN > 0 ? 1 - 0.6 * Math.min(1, lastTvl / capN) : 1;
        burnRatePerSec = (Number(E.formatEther(lastS.totalAmount)) * share) / 86400;
        burnAnchorTs = Number(lastS.settledAt);
        const rl = $('[data-metric="burnRate"]');
        if (rl) rl.innerHTML = `burning <b>\u2248${burnRatePerSec.toFixed(5)} XP</b> every second, right now`;
      }
      renderMetrics({
        tvl: Number(E.formatEther(tvl)),
        apr: displayApr({ apr, lastS, ratioBps, epochS, tvl, cap, E }),
        burned: Number(E.formatEther(burned)),
        cap: Number(E.formatEther(cap)),
      });
      // Next-burn countdown: distributor queue and its burn share at the
      // current utilization.
      const tvlN = Number(E.formatEther(tvl));
      const capN = Number(E.formatEther(cap));
      const pendN = Number(E.formatEther(pending));
      const burnShare = capN > 0 ? 1 - 0.6 * (Math.min(tvlN, capN) / capN) : 1;
      burnQueued = pendN * burnShare;
      burnNextTs = Number(nextTs);
    } catch (err) {
      console.warn("read failed, showing demo:", err);
      $("#demoBadge").hidden = false;
      $("#demoBadge").textContent = "rpc unreachable · showing demo data";
      renderMetrics({ tvl: demo.tvl, apr: demo.apr, burned: demo.burned, cap: demo.cap });
    }
  }

  // The rate a staker actually earns, rebuilt from the same inputs the
  // contract settles on.
  //
  // `currentAPR()` divides a number fixed at settlement — the reward, sized
  // against the vault as it stood then — by totalAssets *right now*. The two
  // sides describe different moments, so every mid-epoch deposit drags the
  // figure down even though nobody's earnings changed. It recovers at the next
  // settlement. During a campaign that reads as "I deposited and my rate fell",
  // which is not what happened.
  //
  //   settled amount × split × (year / epoch) ÷ max(TVL, cap)
  //
  // Below the cap the denominator is the cap, so the rate holds steady no
  // matter how much is staked — the reward scales with the vault. Above it the
  // reward stops growing and TVL takes over as the denominator, so the rate
  // genuinely falls. `max()` covers both without a special case.
  //
  // The contract is immutable, so this lives here. status.html still shows the
  // raw on-chain figure beside it.
  function displayApr({ apr, lastS, ratioBps, epochS, tvl, cap, E }) {
    const onchain = Number(apr) / 1e18;
    try {
      if (!lastS || Number(lastS.settledAt) === 0) return onchain;
      const amount = Number(E.formatEther(lastS.totalAmount));
      const split = Number(ratioBps) / 10000;
      const epoch = Number(epochS) || 86400;
      const denom = Math.max(Number(E.formatEther(tvl)), Number(E.formatEther(cap)));
      if (!(amount > 0 && split > 0 && denom > 0)) return onchain;
      return (amount * split * (31536000 / epoch)) / denom;
    } catch {
      return onchain; // never let a display refinement break the number
    }
  }

  // Round-one capacity. Two states: still room but nearly gone, and gone.
  // Both read from the chain, so this clears itself the moment the cap is
  // raised — no deploy needed to take it down.
  function renderCapNotice(tvl, cap) {
    const el = $("#capNotice");
    const c = CFG.capRaise;
    if (!el || !c || !c.enabled || !(cap > 0)) return;

    const pct = (tvl / cap) * 100;
    // A cap is "gone" before it is mathematically zero — a fraction of an XP
    // left will fail every realistic deposit, so treat that as closed rather
    // than advertising room nobody can use.
    const left = Math.max(0, cap - tvl);
    const full = left < 1;

    // Round status inside the event band, visible without scrolling.
    const rb = $("#ebRound");
    if (rb) {
      if (full) {
        rb.querySelector("strong").textContent = c.closedTitle || "Round 1 pool closed";
        rb.querySelector("em").textContent = `ROUND 2 OPENS — ${c.atLabel}`;
        rb.hidden = false;
      } else {
        rb.hidden = true;
      }
    }

    if (pct < (c.warnBelowPct ?? 85)) {
      el.hidden = true;
      return;
    }

    el.classList.toggle("is-full", full);
    el.querySelector(".cn-tag").textContent = full ? "Round 1 pool closed" : "Round 1 cap almost gone";
    el.querySelector(".cn-left").textContent = full
      ? "Round 2 — " + c.atLabel
      : `${Math.floor(left).toLocaleString("en-US")} XP left`;
    el.querySelector(".cn-bar i").style.width = Math.min(100, pct) + "%";
    el.querySelector(".cn-sub").textContent = full
      ? `All ${Math.round(cap).toLocaleString("en-US")} XP was taken. New deposits reopen with a larger cap at the time above — deposits already made keep earning, nothing changes for them.`
      : `${pct.toFixed(1)}% of the ${Math.round(cap).toLocaleString("en-US")} XP cap is taken · more opens ${c.atLabel}`;
    el.hidden = false;
  }

  function renderMetrics({ tvl, apr, burned, cap }) {
    lastApr = apr;
    renderCapNotice(tvl, cap);
    updateEstimate();
    animateTo($('[data-metric="tvl"]'), tvl, (n) => fmtNum(n) + " XP");
    animateTo($('[data-metric="apr"]'), apr * 100, (n) => n.toFixed(2) + "%");
    // full (non-compact) number; shown next to the accrual figure
    animateTo($('[data-metric="burned"]'), burned, (n) => Math.round(n).toLocaleString("en-US") + " XP");
    $$('[data-tk="tvl"]').forEach((e) => (e.textContent = fmtNum(tvl) + " XP"));
    $$('[data-tk="apr"]').forEach((e) => (e.textContent = (apr * 100).toFixed(2) + "%"));
    $$('[data-tk="burned"]').forEach((e) => (e.textContent = fmtNum(burned) + " XP"));
    const pct = cap > 0 ? (tvl / cap) * 100 : 0;
    $('[data-metric="tvlPct"]').textContent = pct.toFixed(1) + "%";
    requestAnimationFrame(() => ($('[data-metric="capFill"]').style.width = Math.min(100, pct) + "%"));
  }

  // ============================================================
  //  WALLET + POSITION
  // ============================================================
  // Make sure the wallet is on Xphere — add the network if it's missing.
  // Most users won't have this chain configured; without this they hit a wall.
  async function ensureChain() {
    const hexId = "0x" + Number(CFG.chain.chainId).toString(16);
    try {
      await window.ethereum.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId: hexId }],
      });
    } catch (err) {
      if (err && (err.code === 4902 || err.code === -32603)) {
        await window.ethereum.request({
          method: "wallet_addEthereumChain",
          params: [
            {
              chainId: hexId,
              chainName: CFG.chain.chainName,
              nativeCurrency: CFG.chain.nativeCurrency,
              rpcUrls: [CFG.chain.rpcUrl],
              blockExplorerUrls: [CFG.chain.blockExplorerUrl],
            },
          ],
        });
      } else if (err && err.code === 4001) {
        throw err; // user rejected the switch
      }
    }
  }

  async function connect() {
    if (!window.ethereum) {
      // On mobile without an injected wallet, deep-link into MetaMask's dapp browser.
      if (/iPhone|iPad|Android/i.test(navigator.userAgent)) {
        window.location.href = "https://metamask.app.link/dapp/stake.x-phere.com";
        return false;
      }
      setTx("No EVM wallet found. Install MetaMask or a compatible wallet.", "err");
      return false;
    }
    try {
      await ensureChain();
      const bp = new E.BrowserProvider(window.ethereum);
      await bp.send("eth_requestAccounts", []);
      signer = await bp.getSigner();
      account = await signer.getAddress();
      walletMode = "injected";
      localStorage.removeItem(DISC_KEY); // an explicit connect overrides disconnect
      const btn = $("#connectBtn");
      btn.dataset.state = "connected";
      $("#connectLabel").textContent = shorten(account);
      refreshCtas();
      loadPosition();
      return true;
    } catch (err) {
      setTx(err.shortMessage || err.message || "Connection rejected", "err");
      return false;
    }
  }

  // ── ZIGAP (QR) wallet path — see zigap.js bridge ──
  const ZIGAP_KEY = "xp.zigap";
  async function connectZigap() {
    closeChooser();
    try {
      const res = await window.ZigapBridge.login();
      account = res.address;
      signer = null;
      walletMode = "zigap";
      localStorage.setItem(ZIGAP_KEY, JSON.stringify({ address: res.address, network: res.network, ts: Date.now() }));
      localStorage.removeItem(DISC_KEY);
      const btn = $("#connectBtn");
      btn.dataset.state = "connected";
      $("#connectLabel").textContent = shorten(account);
      refreshCtas();
      loadPosition();
      document.getElementById("stake")?.scrollIntoView({ behavior: "smooth" });
      return true;
    } catch (e) {
      if (!/dismissed|closed/i.test(String(e && e.message))) setTx(String((e && e.message) || e), "err");
      return false;
    }
  }
  function restoreZigap() {
    try {
      const raw = localStorage.getItem(ZIGAP_KEY);
      if (!raw) return false;
      const { address, ts } = JSON.parse(raw);
      if (!address || Date.now() - ts > 7 * 24 * 3600 * 1000) {
        localStorage.removeItem(ZIGAP_KEY);
        return false;
      }
      account = address;
      walletMode = "zigap";
      const btn = $("#connectBtn");
      btn.dataset.state = "connected";
      $("#connectLabel").textContent = shorten(account);
      refreshCtas();
      loadPosition();
      return true;
    } catch (_) {
      return false;
    }
  }

  // connect chooser: browser wallet vs ZIGAP QR
  function openChooser() {
    // ZIGAP disabled → only one option exists; skip the chooser entirely
    if (!(CFG.features && CFG.features.zigap)) {
      connect();
      return;
    }
    const c = $("#connectChooser");
    if (c) c.hidden = false;
  }
  function closeChooser() {
    const c = $("#connectChooser");
    if (c) c.hidden = true;
  }
  function wireChooser() {
    const c = $("#connectChooser");
    if (!c) return;
    // hide the ZIGAP option while the platform side is unfinished
    if (!(CFG.features && CFG.features.zigap)) $("#ccZigap")?.setAttribute("hidden", "");
    c.addEventListener("click", (e) => {
      if (e.target === c) closeChooser();
    });
    $("#ccCancel")?.addEventListener("click", closeChooser);
    $("#ccInjected")?.addEventListener("click", async () => {
      closeChooser();
      const ok = await connect();
      if (ok) document.getElementById("stake")?.scrollIntoView({ behavior: "smooth" });
    });
    $("#ccZigap")?.addEventListener("click", connectZigap);
  }

  // Build + send a vault call through the ZIGAP QR flow.
  const VAULT_IFACE = new E.Interface(VAULT_ABI);
  async function zigapVaultTx(fn, args, valueWei, label, gasLimit) {
    const data = VAULT_IFACE.encodeFunctionData(fn, args);
    let gasPrice = "30000000000";
    try {
      gasPrice = BigInt(await readProvider.send("eth_gasPrice", [])).toString();
    } catch (_) {}
    const res = await window.ZigapBridge.sendTx(
      {
        type: 0,
        to: CFG.contracts.vault,
        data,
        value: (valueWei ?? 0n).toString(),
        gasLimit: String(gasLimit || 600000),
        gasPrice,
        chainId: CFG.chain.chainId,
      },
      label
    );
    if (res && res.status === 1) return res;
    throw new Error((res && res.error) || "Transaction failed in ZIGAP");
  }

  // Wallet menu (connected state): copy / switch / disconnect.
  function wireWalletMenu() {
    const menu = $("#walletMenu");
    if (!menu) return;
    const close = () => (menu.hidden = true);
    document.addEventListener("click", (e) => {
      if (!e.target.closest(".wallet-wrap")) close();
    });
    document.addEventListener("keydown", (e) => e.key === "Escape" && close());

    $("#wmCopy")?.addEventListener("click", () => {
      if (account) navigator.clipboard?.writeText(account);
      $("#wmCopy").textContent = "Copied ✓";
      setTimeout(() => ($("#wmCopy").textContent = "Copy address"), 1200);
    });
    $("#wmSwitch")?.addEventListener("click", async () => {
      close();
      if (walletMode === "zigap") {
        localStorage.removeItem(ZIGAP_KEY);
        connectZigap(); // fresh QR login
        return;
      }
      try {
        // Forces the wallet's account picker even when already authorized.
        await window.ethereum.request({
          method: "wallet_requestPermissions",
          params: [{ eth_accounts: {} }],
        });
        location.reload(); // silentConnect picks up the newly selected account
      } catch (_) {
        /* user dismissed the picker */
      }
    });
    $("#wmDisconnect")?.addEventListener("click", () => {
      localStorage.removeItem(ZIGAP_KEY);
      localStorage.setItem(DISC_KEY, "1"); // suppress silent reconnect
      location.reload(); // loads fully disconnected
    });
  }

  // Returning visitors: reconnect silently (no popup) if the wallet has
  // already authorized this site — the page loads in a connected state.
  // Skipped when the user explicitly disconnected (flag below).
  const DISC_KEY = "xp.disconnected";
  async function silentConnect() {
    if (localStorage.getItem(DISC_KEY)) return; // user chose to disconnect
    if (restoreZigap()) return; // ZIGAP session survives refreshes
    if (!window.ethereum) return;
    try {
      const accts = await window.ethereum.request({ method: "eth_accounts" });
      if (accts && accts.length) {
        const bp = new E.BrowserProvider(window.ethereum);
        signer = await bp.getSigner();
        account = await signer.getAddress();
        const btn = $("#connectBtn");
        btn.dataset.state = "connected";
        $("#connectLabel").textContent = shorten(account);
        refreshCtas();
        loadPosition();
      }
    } catch (_) {
      /* stay disconnected */
    }
  }

  // Primary CTAs reflect wallet connection state.
  function refreshCtas() {
    const on = !!signer || walletMode === "zigap";
    const hero = $("#heroCta");
    if (hero) hero.textContent = on ? "Stake now →" : "Connect & stake →";
    const labels = [
      ["#depositBtn", "Stake XP"],
      ["#requestBtn", "Request unstake"],
      ["#claimBtn", "Claim rewards"],
    ];
    labels.forEach(([sel, label]) => {
      const b = $(sel);
      if (b) b.textContent = on ? label : "Connect wallet";
    });
  }

  function wireHeroCta() {
    const hero = $("#heroCta");
    if (!hero) return;
    hero.addEventListener("click", (e) => {
      if (signer || walletMode === "zigap") return; // connected → anchor scroll
      e.preventDefault();
      openChooser();
    });
  }

  async function loadPosition() {
    if (!account) return;
    $("#pcHint").textContent = "Live position for " + shorten(account);
    if (DEMO) {
      // show illustrative values in demo
      setMe("principal", "1,250 XP");
      setMe("rewards", "18.4 XP");
      setMe("rewards2", "18.4 XP");
      setMe("walletBal", "5,000 XP");
      return;
    }
    try {
      const vault = new E.Contract(CFG.contracts.vault, VAULT_ABI, readProvider);
      const wxpc = new E.Contract(CFG.contracts.wxp, WXP_ABI, readProvider);
      const [principal, rewards, ids, nativeBal, wxpBal] = await Promise.all([
        vault.userPrincipal(account),
        vault.earned(account),
        vault.getUserRequestIds(account).catch(() => []),
        readProvider.getBalance(account).catch(() => 0n),
        wxpc.balanceOf(account).catch(() => 0n),
      ]);
      posEarned = Number(E.formatEther(rewards));
      posPrincipal = Number(E.formatEther(principal));
      posReadAt = Date.now() / 1000;
      setMe("principal", fmtXP(principal) + " XP");
      setMe("rewards", fmtXP(rewards, { compact: false }) + " XP");
      setMe("rewards2", fmtXP(rewards, { compact: false }) + " XP");
      // wallet balances — position card, stake/unstake helper lines, menu
      const balTxt = fmtXP(nativeBal, { compact: false }) + " XP";
      setMe("walletBal", balTxt);
      const sb = $("#stakeBal");
      if (sb) sb.textContent = balTxt;
      // Someone staring at a balance too small to stake needs somewhere to go.
      // Gas has to survive the transaction, so "enough" is a little above zero.
      markBuyXp(nativeBal <= 1_000_000_000_000_000_000n); // ≤ 1 XP
      const rb = $("#redBal");
      if (rb) rb.textContent = fmtXP(principal, { compact: false }) + " XP";
      const wmA = $("#wmAddr"), wmB = $("#wmBal");
      if (wmA) wmA.textContent = shorten(account) + (walletMode === "zigap" ? " · ZIGAP" : "");
      if (wmB) wmB.textContent = balTxt;
      const wxpRow = $("#wxpRow");
      if (wxpRow) {
        const has = wxpBal > 0n;
        wxpRow.hidden = !has;
        if (has) setMe("wxpBal", fmtXP(wxpBal, { compact: false }) + " WXP");
      }
      renderRequests(vault, ids);
    } catch (err) {
      console.warn(err);
    }
  }

  async function renderRequests(vault, ids) {
    const box = $("#requestList");
    box.innerHTML = "";
    for (const id of ids) {
      try {
        const r = await vault.redeemRequests(id);
        if (r.claimed) continue;
        const nowS = Math.floor(Date.now() / 1000);
        const ready = Number(r.claimableAt) <= nowS;
        // cooldown progress: request time = claimableAt - cooldownPeriod
        const start = Number(r.claimableAt) - cooldownS;
        const pct = ready ? 100 : Math.max(0, Math.min(100, ((nowS - start) / cooldownS) * 100));
        const daysLeft = Math.max(0, Math.ceil((Number(r.claimableAt) - nowS) / 86400));
        const el = document.createElement("div");
        el.className = "req";
        const when = new Date(Number(r.claimableAt) * 1000);
        el.innerHTML = `<div class="req-top"><span>#${id} · ${fmtXP(r.assets)} XP</span>
          <span class="${ready ? "ready" : "wait"}">${
            ready ? "ready to claim ✓" : `D-${daysLeft} · matures ${when.toLocaleDateString()}`
          }</span></div>
          <div class="req-track"><i style="width:${pct}%"></i></div>`;
        box.appendChild(el);
      } catch (_) {}
    }
  }

  const setMe = (k, v) => $$(`[data-me="${k}"]`).forEach((e) => (e.textContent = v));

  // ============================================================
  //  WRITES
  // ============================================================
  function needWallet() {
    if (!signer && walletMode !== "zigap") {
      // not connected — open the connect chooser
      openChooser();
      return true;
    }
    if (DEMO) {
      setTx("Contracts are not live yet — this is a demo. Writes are disabled.", "err");
      return true;
    }
    return false;
  }

  async function doDeposit() {
    if (needWallet()) return;
    const amt = $("#depAmount").value;
    if (!amt || Number(amt) <= 0) return setTx("Enter an amount.", "err");
    const value = E.parseEther(amt);
    // attribution comes only from the captured redirect param — never typed in
    const partner = activeReferral();
    if (walletMode === "zigap") {
      try {
        setTx("Scan the QR with your ZIGAP app…", "pending");
        await zigapVaultTx(
          partner ? "depositNativeWithReferral" : "depositNative",
          partner ? [account, pidOf(partner)] : [account],
          value,
          `Stake ${amt} XP`,
          700000
        );
        setTx("Deposited " + amt + " XP ✓", "ok");
        showShare(amt);
        loadPosition();
        loadDashboard();
      } catch (err) {
        setTx(err.message, "err");
      }
      return;
    }
    const vault = new E.Contract(CFG.contracts.vault, VAULT_ABI, signer);
    try {
      setTx("Confirm in your wallet…", "pending");
      const tx = partner
        ? await vault.depositNativeWithReferral(account, pidOf(partner), { value })
        : await vault.depositNative(account, { value });
      setTx("Depositing… " + shorten(tx.hash), "pending");
      await tx.wait();
      setTx("Deposited " + amt + " XP ✓", "ok");
      showShare(amt);
      loadPosition();
      loadDashboard();
    } catch (err) {
      setTx(err.shortMessage || err.message, "err");
    }
  }

  async function doRequest() {
    if (needWallet()) return;
    const amt = $("#redAmount").value;
    if (!amt || Number(amt) <= 0) return setTx("Enter an amount.", "err");
    const shares = E.parseEther(amt) * SHARE_UNIT;
    if (walletMode === "zigap") {
      try {
        setTx("Scan the QR with your ZIGAP app…", "pending");
        await zigapVaultTx("requestRedeem", [shares, account, account], 0n, `Unstake ${amt} XP`, 600000);
        setTx("Unstake requested — claim in 7 days ✓", "ok");
        loadPosition();
      } catch (err) {
        setTx(err.message, "err");
      }
      return;
    }
    const vault = new E.Contract(CFG.contracts.vault, VAULT_ABI, signer);
    try {
      setTx("Confirm in your wallet…", "pending");
      const tx = await vault.requestRedeem(shares, account, account);
      setTx("Requesting… " + shorten(tx.hash), "pending");
      await tx.wait();
      setTx("Unstake requested — claim in 7 days ✓", "ok");
      loadPosition();
    } catch (err) {
      setTx(err.shortMessage || err.message, "err");
    }
  }

  async function doClaimRedeem() {
    if (needWallet()) return;
    const reader = new E.Contract(CFG.contracts.vault, VAULT_ABI, readProvider);
    try {
      const ids = await reader.getUserRequestIds(account);
      const now = BigInt(Math.floor(Date.now() / 1000));
      for (const id of ids) {
        const r = await reader.redeemRequests(id);
        if (!r.claimed && BigInt(r.claimableAt) <= now) {
          if (walletMode === "zigap") {
            setTx("Scan the QR with your ZIGAP app…", "pending");
            await zigapVaultTx("claimRedeemNative", [id, account], 0n, "Claim matured principal", 500000);
          } else {
            setTx("Claiming matured request #" + id + "…", "pending");
            const vault = new E.Contract(CFG.contracts.vault, VAULT_ABI, signer);
            const tx = await vault.claimRedeemNative(id, account);
            await tx.wait();
          }
          setTx("Principal returned ✓", "ok");
          loadPosition();
          return;
        }
      }
      setTx("No matured requests to claim.", "err");
    } catch (err) {
      setTx(err.shortMessage || err.message, "err");
    }
  }

  async function doClaimReward() {
    if (needWallet()) return;
    if (walletMode === "zigap") {
      try {
        setTx("Scan the QR with your ZIGAP app…", "pending");
        await zigapVaultTx("claimRewardNative", [account], 0n, "Claim rewards", 500000);
        setTx("Rewards claimed ✓", "ok");
        loadPosition();
      } catch (err) {
        setTx(err.message, "err");
      }
      return;
    }
    const vault = new E.Contract(CFG.contracts.vault, VAULT_ABI, signer);
    try {
      setTx("Confirm in your wallet…", "pending");
      const tx = await vault.claimRewardNative(account);
      await tx.wait();
      setTx("Rewards claimed ✓", "ok");
      loadPosition();
    } catch (err) {
      setTx(err.shortMessage || err.message, "err");
    }
  }

  function setTx(msg, kind) {
    const el = $("#txStatus");
    el.hidden = false;
    el.textContent = msg;
    el.className = "tx-status " + kind;
    if (kind !== "ok") {
      const s = $("#shareRow");
      if (s) s.hidden = true;
    }
  }

  // Show a prefilled share link after a successful stake.
  function showShare(amt) {
    const row = $("#shareRow");
    if (!row) return;
    const aprTxt = lastApr > 0 ? (lastApr * 100).toFixed(1) + "%" : "real";
    const text =
      `Just staked ${amt} XP on the Xphere Union Vault — earning ${aprTxt} real validator yield ` +
      `while 40%+ of every day's rewards burn forever 🔥`;
    $("#shareX").href =
      "https://twitter.com/intent/tweet?text=" +
      encodeURIComponent(text) +
      "&url=" +
      encodeURIComponent("https://stake.x-phere.com");
    row.hidden = false;
  }

  // ============================================================
  //  FOOTER ADDRESSES (transparency) + TABS + STAKE UX
  // ============================================================
  function renderAddresses() {
    const box = $("#footAddrs");
    if (!box) return;
    const ex = CFG.chain.blockExplorerUrl;
    const items = [
      ["Vault", CFG.contracts.vault],
      ["Distributor", CFG.contracts.distributor],
      ["WXP", CFG.contracts.wxp],
    ].filter(([, a]) => a && a !== ZERO);
    box.innerHTML =
      items
        .map(
          ([name, addr]) =>
            `<a href="${ex}/address/${addr}" target="_blank" rel="noopener">${name} <code>${shorten(addr)}</code></a>`
        )
        .join("") + `<a href="status.html">Live status →</a>`;
  }

  function wireTabs() {
    $$(".actions .tab").forEach((t) =>
      t.addEventListener("click", () => {
        $$(".actions .tab").forEach((x) => x.classList.remove("active"));
        $$(".panel").forEach((p) => p.classList.remove("active"));
        t.classList.add("active");
        $(`[data-panel="${t.dataset.tab}"]`).classList.add("active");
      })
    );
  }

  // Stake panel: MAX button (balance minus gas buffer) and a live
  // per-year earnings estimate.
  function updateEstimate() {
    const input = $("#depAmount");
    const note = $("#estNote");
    if (!input || !note) return;
    const amt = Number(input.value);
    if (!amt || amt <= 0 || !lastApr) {
      note.hidden = true;
      return;
    }
    $("#estYear").textContent = fmtNum(amt * lastApr, { compact: false }) + " XP";
    note.hidden = false;
  }
  function wireStakeUX() {
    const input = $("#depAmount");
    if (input) input.addEventListener("input", updateEstimate);
    // balance lines: click to fill
    $("#stakeBal")?.addEventListener("click", () => $("#maxBtn")?.click());
    $("#redBal")?.addEventListener("click", () => {
      const r = $("#redAmount");
      if (r && posPrincipal > 0) r.value = String(posPrincipal);
    });
    const max = $("#maxBtn");
    if (max)
      max.addEventListener("click", async () => {
        if (!account || !readProvider) return setTx("Connect a wallet first.", "err");
        try {
          const bal = await readProvider.getBalance(account);
          const buffer = E.parseEther("0.05"); // keep a little for gas
          const usable = bal > buffer ? bal - buffer : 0n;
          input.value = E.formatEther(usable);
          updateEstimate();
        } catch (_) {}
      });
  }

  // ============================================================
  //  INIT
  // ============================================================
  // Pre-launch notice: ribbon + first-visit modal + ticker PREVIEW chip.
  // Fully driven by CFG.launch.live — flip it to true at launch and all of
  // this disappears without further code changes.
  function wireLaunchNotice() {
    const launch = CFG.launch || {};
    const modal = $("#launchModal");

    // At launch: flip CFG.launch.live = true → hide the modal/ribbon and restore LIVE.
    if (launch.live === true) {
      if (modal) {
        modal.hidden = true;
        modal.style.display = "none";
      }
      return;
    }

    // Preview mode: the modal shows on every visit (inline bootstrap already showed
    // it; no dismissal memory). Fill copy + wire Esc close.
    const banner = $("#previewBanner");
    if (banner) {
      banner.hidden = false;
      $("#previewBannerText").textContent = launch.headline
        ? launch.headline + " — numbers are illustrative"
        : "Staking is not open yet — numbers are illustrative";
      if (launch.eta) $("#previewBannerEta").textContent = launch.eta;
    }

    // ticker: LIVE -> PREVIEW while not launched
    $$(".tk").forEach((chip) => {
      if (chip.textContent.trim() === "LIVE") chip.lastChild.textContent = " PREVIEW";
    });

    if (modal) {
      if (launch.headline) $("#lmTitle").textContent = launch.headline;
      if (launch.note) $("#lmNote").textContent = launch.note;
      if (launch.eta) $("#lmEta").textContent = launch.eta;
      const closeModal = () => {
        modal.hidden = true;
        modal.style.display = "none";
      };
      document.addEventListener("keydown", function esc(e) {
        if (e.key === "Escape") {
          closeModal();
          document.removeEventListener("keydown", esc);
        }
      });
    }
  }

  function wireTicker() {
    const track = $("#tickerTrack");
    if (!track) return;
    track.appendChild(track.querySelector(".ticker-set").cloneNode(true));
  }

  function wireReveal() {
    const els = document.querySelectorAll(".reveal");
    if (!("IntersectionObserver" in window)) {
      els.forEach((el) => el.classList.add("in"));
      return;
    }
    const io = new IntersectionObserver(
      (entries) =>
        entries.forEach((e) => {
          if (e.isIntersecting) {
            e.target.classList.add("in");
            io.unobserve(e.target);
          }
        }),
      { threshold: 0.12 }
    );
    els.forEach((el) => io.observe(el));
  }

  // Buy XP. Both links come from one config entry; an empty url leaves them
  // hidden rather than sending anyone to a dead exchange page.
  function wireBuyXp() {
    const b = CFG.buyXp;
    if (!b || !b.url) return;
    for (const id of ["#navBuyXp", "#buyXpInline", "#heroBuyXp"]) {
      const el = $(id);
      if (!el) continue;
      el.href = b.url;
      el.title = `Buy XP on ${b.name}`;
      el.hidden = false;
    }
  }

  // Emphasise the inline link only once we know the wallet is short of XP.
  function markBuyXp(needed) {
    $("#buyXpInline")?.classList.toggle("needed", !!needed);
  }

  // Campaign band under the nav. Gated on a UTC window from config so the
  // start and the end both happen on their own — a missed deploy would
  // otherwise leave a dead form link on the page.
  function renderBanner() {
    const el = $("#eventBar");
    const b = CFG.banner;
    if (!el || !b || !b.enabled || !b.href) return;

    // ?preview=banner shows it outside the booked window, so the copy can be
    // signed off before go-live without editing config or the console.
    const preview = new URLSearchParams(location.search).get("preview") === "banner";
    if (!preview) {
      const now = Date.now();
      const from = b.startsAt ? Date.parse(b.startsAt) : -Infinity;
      const to = b.endsAt ? Date.parse(b.endsAt) : Infinity;
      if (Number.isNaN(from) || Number.isNaN(to)) return; // bad config: stay hidden
      if (now < from || now >= to) return;
    }

    el.href = b.href;
    el.querySelector(".eb-badge").textContent = b.badge || "EVENT";
    el.querySelector(".eb-title").textContent = b.title || "";
    el.querySelector(".eb-body").textContent = b.body || "";
    el.querySelector(".eb-cta").textContent = b.cta || "Enter now";
    el.hidden = false;
  }

  function init() {
    renderBanner();
    wireBuyXp();
    wireReveal();
    wireTicker();
    wireCapLabels(); // after wireTicker so cloned ticker sets are patched too
    wireLaunchNotice();
    wireTabs();
    wireStakeUX();
    wireReferral();
    wireHeroCta();
    wireChooser();
    refreshCtas(); // initial labels: "Connect & stake" / "Connect wallet"
    wireBurnCountdown();
    wireBurnEmbers();
    wireBurnLiveCounter();
    renderAddresses();
    loadDashboard();
    setInterval(loadDashboard, 60_000); // keep burn queue/metrics fresh
    setInterval(() => account && loadPosition(), 60_000); // resync earnings ticker
    wireEarningsTicker();
    silentConnect(); // returning visitors load already-connected

    $("#connectBtn").addEventListener("click", () => {
      if (!signer && walletMode !== "zigap") return openChooser();
      const menu = $("#walletMenu");
      if (menu) menu.hidden = !menu.hidden; // connected → toggle wallet menu
    });
    wireWalletMenu();
    $("#depositBtn").addEventListener("click", doDeposit);
    $("#requestBtn").addEventListener("click", doRequest);
    $("#claimRedeemBtn").addEventListener("click", doClaimRedeem);
    $("#claimBtn").addEventListener("click", doClaimReward);

    if (window.ethereum) {
      window.ethereum.on?.("accountsChanged", () => location.reload());
      window.ethereum.on?.("chainChanged", () => location.reload());
    }
  }

  document.addEventListener("DOMContentLoaded", init);
})();
