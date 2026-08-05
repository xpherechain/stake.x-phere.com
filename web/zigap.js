/* ============================================================
   ZIGAP wallet bridge — QR login and QR transaction signing via the
   ZIGAP mobile app (zigap-utils React components). Libraries load on
   demand from esm.sh only when the user selects ZIGAP.

   Exposes window.ZigapBridge = { login(), sendTx(tx, label), close() }
   ============================================================ */
(() => {
  "use strict";
  const CFG = window.XP_CONFIG;
  // v2xphere = XP mainnet · v3xphere = XPT testnet (zigap network slugs)
  const NETWORK = CFG.chain.chainId === 20250217 ? "v2xphere" : "v3xphere";
  const DAPP = "XP Union Vault";
  const DAPP_URL = "https://stake.x-phere.com";
  const ICON = DAPP_URL + "/assets/brand/gnb_logo.png";

  let libs = null; // {React, createRoot, Z}
  let root = null;
  let overlay = null;

  async function loadLibs() {
    if (libs) return libs;
    const [R, RDC, Z] = await Promise.all([
      import("https://esm.sh/react@19.0.0"),
      import("https://esm.sh/react-dom@19.0.0/client"),
      import("https://esm.sh/zigap-utils@3.1.0?deps=react@19.0.0,react-dom@19.0.0"),
    ]);
    libs = { React: R.default ?? R, createRoot: RDC.createRoot, Z };
    return libs;
  }

  function ensureOverlay() {
    if (overlay) return overlay;
    const style = document.createElement("style");
    style.textContent = `
      .zg-overlay { position: fixed; inset: 0; z-index: 200; display: flex;
        align-items: center; justify-content: center;
        background: rgba(0,0,0,.78); backdrop-filter: blur(6px); }
      .zg-overlay[hidden] { display: none; }
      .zg-card { background: #101010; border: 1px solid #333; border-radius: 18px;
        padding: 1.6rem 1.7rem 1.4rem; width: min(92vw, 380px); text-align: center;
        box-shadow: 0 24px 80px rgba(0,0,0,.7); }
      .zg-head { display: flex; align-items: center; justify-content: space-between;
        margin-bottom: 1rem; }
      .zg-head b { font-size: .95rem; color: #efece8; display: flex;
        align-items: center; gap: .55rem;
        font-family: "IBM Plex Mono", monospace; letter-spacing: .04em; }
      .zg-logo { width: 20px; height: 20px; }
      .zg-close { background: none; border: 1px solid #333; border-radius: 8px;
        color: #8a8a8a; font-size: 1rem; width: 30px; height: 30px; cursor: pointer; }
      .zg-close:hover { color: #efece8; border-color: #ff9738; }
      .zg-mount { display: flex; justify-content: center; align-items: center;
        min-height: 264px; background: #ffffff; border-radius: 14px;
        padding: 16px; }
      .zg-note { margin-top: 1.05rem; font-size: .84rem; color: #d6d1cc;
        font-family: "IBM Plex Mono", monospace; line-height: 1.6; }
      .zg-note b { color: #ff9738; }
      .zg-loading { color: #666; font-family: "IBM Plex Mono", monospace;
        font-size: .8rem; animation: zgpulse 1.6s ease-in-out infinite; }
      @keyframes zgpulse { 50% { opacity: .45; } }
    `;
    document.head.appendChild(style);

    overlay = document.createElement("div");
    overlay.className = "zg-overlay";
    overlay.hidden = true;
    overlay.innerHTML = `
      <div class="zg-card">
        <div class="zg-head"><b id="zgTitle"><img class="zg-logo" src="assets/brand/zigap_symbol.svg" alt="" />ZIGAP</b>
          <button class="zg-close" id="zgClose" aria-label="close">✕</button></div>
        <div class="zg-mount" id="zgMount"><span class="zg-loading">loading…</span></div>
        <div class="zg-note" id="zgNote"></div>
      </div>`;
    document.body.appendChild(overlay);
    overlay.addEventListener("click", (e) => {
      if (e.target === overlay) close("dismissed");
    });
    overlay.querySelector("#zgClose").addEventListener("click", () => close("dismissed"));
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && !overlay.hidden) close("dismissed");
    });
    return overlay;
  }

  let rejectOpen = null; // pending promise rejector for the open modal

  function close(reason) {
    if (root) {
      try { root.unmount(); } catch (_) {}
      root = null;
    }
    if (overlay) overlay.hidden = true;
    if (rejectOpen) {
      const r = rejectOpen;
      rejectOpen = null;
      r(new Error(reason || "closed"));
    }
  }

  async function mount(title, note, makeElement) {
    ensureOverlay();
    overlay.hidden = false;
    overlay.querySelector("#zgTitle").innerHTML =
      '<img class="zg-logo" src="assets/brand/zigap_symbol.svg" alt="" />' + title;
    overlay.querySelector("#zgNote").innerHTML = note;
    const mountEl = overlay.querySelector("#zgMount");
    mountEl.innerHTML = '<span class="zg-loading">loading ZIGAP…</span>';
    const { createRoot } = await loadLibs();
    return new Promise((resolve, reject) => {
      rejectOpen = reject;
      mountEl.innerHTML = "";
      root = createRoot(mountEl);
      root.render(makeElement(resolve));
    });
  }

  const QR_STYLE = { size: 232, bgColor: "#ffffff", fgColor: "#000000", isShowLogo: true, logoSize: 40 };

  window.ZigapBridge = {
    /** QR login → resolves {address, network, nickName, ...} */
    async login() {
      const { React, Z } = await loadLibs();
      return mount(
        "CONNECT · ZIGAP",
        "Scan with the <b>ZIGAP</b> app to connect.<br/>Your keys never leave your phone.",
        (resolve) =>
          React.createElement(Z.LoginQR, {
            dapp: DAPP,
            url: DAPP_URL,
            icon: ICON,
            availableNetworks: [NETWORK],
            sigMessage: "Sign in to XP Union Vault",
            validSeconds: 600,
            expire: { type: "NONE" },
            ...QR_STYLE,
            onReceive: ({ status, result }) => {
              if (status === "SUCCESS") {
                rejectOpen = null;
                resolve(result);
                close();
              } else if (status === "ERROR") {
                close("ZIGAP login failed");
              }
            },
          })
      );
    },

    /** QR transaction → resolves {txHash, status} */
    async sendTx(tx, label) {
      const { React, Z } = await loadLibs();
      return mount(
        "SIGN · ZIGAP",
        (label || "Transaction") + "<br/>Scan and approve in the <b>ZIGAP</b> app.",
        (resolve) =>
          React.createElement(Z.SendTransactionQR, {
            dapp: DAPP,
            url: DAPP_URL,
            icon: ICON,
            availableNetworks: NETWORK, // single value for tx QR
            validSeconds: 600,
            transaction: tx,
            ...QR_STYLE,
            onReceive: ({ status, result }) => {
              if (status === "SUCCESS") {
                rejectOpen = null;
                resolve(result);
                close();
              } else if (status === "ERROR") {
                close("ZIGAP transaction failed");
              }
            },
          })
      );
    },

    close,
  };
})();
