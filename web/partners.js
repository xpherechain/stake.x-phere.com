/* ============================================================
   Partners page — live partner-attributed TVL leaderboard, read
   straight from the vault contract. Public data, no keys.
   ============================================================ */
(() => {
  "use strict";
  const CFG = window.XP_CONFIG;
  const E = ethers;

  const VAULT_ABI = [
    "function totalAssets() view returns (uint256)",
    "function partnerTVL(bytes32) view returns (uint256)",
  ];
  const provider = new E.JsonRpcProvider(CFG.chain.rpcUrl, undefined, { batchMaxCount: 8 });
  const vault = new E.Contract(CFG.contracts.vault, VAULT_ABI, provider);

  const fe = (w) => Number(E.formatEther(w ?? 0n));
  const fn = (n, dp = 2) => n.toLocaleString("en-US", { maximumFractionDigits: dp });

  // fill the verify snippet with real values
  document.getElementById("vaultAddr").textContent = CFG.contracts.vault;
  document.getElementById("rpcUrl").textContent = CFG.chain.rpcUrl;

  async function load() {
    try {
      const slugs = CFG.partners || [];
      const [total, direct, ...tvls] = await Promise.all([
        vault.totalAssets(),
        vault.partnerTVL(E.id("DIRECT")),
        ...slugs.map((s) => vault.partnerTVL(E.id(s)).catch(() => 0n)),
      ]);
      const totalN = Math.max(fe(total), 1e-9);
      const rows = slugs
        .map((s, i) => ({ name: s, sub: "partner", tvl: fe(tvls[i]) }))
        .concat([{ name: "direct", sub: "no referral", tvl: fe(direct) }])
        .sort((a, b) => b.tvl - a.tvl);
      const maxT = Math.max(...rows.map((r) => r.tvl), 1e-9);
      document.getElementById("rows").innerHTML = rows
        .map(
          (r) => `<div class="b-row">
            <span class="name">${r.name}<small>${r.sub}</small></span>
            <span class="tvl">${fn(r.tvl)} XP</span>
            <span class="share">${fn((r.tvl / totalN) * 100, 1)}%</span>
            <span class="bar"><i style="width:${(r.tvl / maxT) * 100}%"></i></span>
          </div>`
        )
        .join("");
      document.getElementById("boardFoot").textContent =
        `total staked ${fn(totalN)} XP · reads directly from partnerTVL() · refreshes every 30s`;
    } catch (_) {
      document.getElementById("boardFoot").textContent = "RPC unreachable — retrying…";
    }
  }
  load();
  setInterval(load, 30_000);
})();
