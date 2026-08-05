/* ============================================================
   Xphere TESTNET config (live-deployed rehearsal contracts).
   Loaded by index.html?config=testnet and by status.html.
   ============================================================ */
window.XP_CONFIG = {
  chain: {
    chainId: 1998991,
    chainName: "Xphere Testnet",
    rpcUrl: "https://rpc.ankr.com/xphere_testnet",
    nativeCurrency: { name: "XP", symbol: "XP", decimals: 18 },
    blockExplorerUrl: "https://xpscan.io",
  },
  contracts: {
    wxp: "0x916cb72A2895FEB3f5873426666481eC01203d29",
    vault: "0x6913aF1b384B3DdC6B5f1D2831fD9780D363AE7b",
    distributor: "0x2867124C2DF80E3e559a0CfFd4Aaf998aeD19372",
    commission: "0x0000000000000000000000000000000000000000", // off-chain, not deployed
  },
  // testnet governance holders (deployer doubles as Safe on testnet)
  governance: {
    timelock: "0xa72C9b9a76b97E3835fe97e11670255a30c1Fb06",
    safe: "0xfcbCc0A3a5ba5b343dA3d621636Ee3BCB2a57e36",
  },
  launch: { live: true }, // real testnet data, no preview modal
  partners: ["ankr", "nansen"],
  stakeCapXP: 100_000, // testnet cap
};
