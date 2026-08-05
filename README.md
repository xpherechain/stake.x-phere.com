# XP Union Vault — Stake XP. Burn the rest.

[![ci](https://github.com/xpherechain/stake.x-phere.com/actions/workflows/ci.yml/badge.svg)](https://github.com/xpherechain/stake.x-phere.com/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![chain](https://img.shields.io/badge/chain-Xphere%20mainnet-orange)](https://stake.x-phere.com/status.html)
[![site](https://img.shields.io/badge/live-stake.x--phere.com-e7453a)](https://stake.x-phere.com)

Non-custodial staking vault for the Xphere network. Real rewards earned by the
foundation's Union validator node flow into the vault every day — **60% streams
to stakers, 40%+ is burned forever**. Staker principal is never deployed,
re-delegated, or touched.

**Live:** [stake.x-phere.com](https://stake.x-phere.com) ·
[status & proof of solvency](https://stake.x-phere.com/status.html) ·
[burn tracker](https://stake.x-phere.com/burn.html) ·
[partners](https://stake.x-phere.com/partners.html)

## How it works

```
Union validator revenue (native XP)
        │  daily, permissionless settle()
        ▼
  RewardDistributor ──► stakers : inflow × 60% × (staked ÷ cap), streamed per second
        │                        (Synthetix-style accrual — no snipe window)
        └────────────► burned  : everything else, sent to 0x…dEaD forever
```

- **Seat model** — the staker pool is priced against the *full cap*, so each
  staker earns exactly their own share regardless of how full the vault is
  (~constant APR, no dilution). The yield belonging to unfilled capacity has no
  owner and is burned: the emptier the vault, the bigger the burn.
- **Real yield** — rewards are actual validator earnings, not token emissions.
- **Non-custodial** — principal and rewards are separate ledgers; even if
  rewards stopped entirely, 100% of principal remains withdrawable
  (7-day cooldown, two-step async redeem).
- **Immutable logic** — no proxies. Operational parameters (cap, cooldown,
  split, epoch) are tunable only through a 48-hour on-chain timelock, within
  immutable bounds fixed at deployment.

## Deployed contracts (Xphere mainnet, chainId 20250217)

| Contract | Address |
|---|---|
| XPStakingVault (ERC-4626) | `0xaE4435bB474716E130be2aC8e6C244f171451064` |
| RewardDistributor | `0x24C5912B63a8B41DA80EBDC2115949fcbb41Fddf` |
| WXP (vault asset) | `0x780E8c0443F6d702De0c72650648C7CAA591e8f0` |
| TimelockController (48h) | `0x0737B4EEB4dA0920cE7CeE2D1eF64E0f57211F4E` |
| Burn address | `0x000000000000000000000000000000000000dEaD` |

The vault opened in a guarded launch (cap 2,000,000 XP) and is raised in steps
via the timelock — every parameter change is visible on-chain 48 hours before
it takes effect.

## Repository layout

```
src/          Solidity contracts (WXP, XPStakingVault, RewardDistributor,
              optional PartnerCommissionDistributor — not deployed)
test/         Foundry test suites (113 tests incl. invariant & scenario tests)
script/       Deployment & rehearsal scripts (forge create + cast wiring)
web/          The live site — static HTML/JS, reads the chain directly over RPC
ops/          Keeper scripts: daily sweep + settle, monitoring, stats feed
docs/         Protocol architecture spec & static-analysis notes
integration/  DefiLlama adapter
```

## Build & test

```bash
forge build
forge test        # 113 tests, 97%+ line coverage on core contracts
slither src/      # static analysis — see docs/SECURITY_SLITHER.md
```

## Security model

- Fixed 10³:1 share rate — immune to ERC-4626 inflation/donation attacks
  (`totalAssets()` reads internal accounting only).
- Solvency invariant, checked live on the [status page](https://stake.x-phere.com/status.html):
  `WXP.balanceOf(vault) ≥ staked + pendingRedeem + rewardReserves`.
- `settle()` is permissionless and snapshot-based — rewards cannot be promised
  beyond the balance actually held.
- Admin & parameter changes sit behind the timelock; the deployer renounced
  all roles at deployment (verifiable on-chain).

Design details and threat analysis: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Partner attribution

External platforms route users with a single link
(`https://stake.x-phere.com/?ref=<slug>`). Attribution is recorded on-chain
(`partnerTVL`, indexed `Deposited.partnerId`) and independently verifiable —
no SDK, no API keys. Referred users earn exactly the same yield as direct
stakers. Partnership onboarding: **partners@x-phere.com**.

## Disclaimer

Staking rewards vary with actual validator revenue and are not guaranteed.
Smart contracts carry risk. Nothing here is financial advice.

## License

[MIT](LICENSE) © Xphere Foundation
