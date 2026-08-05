# Security Policy

## Reporting a vulnerability

If you discover a security issue in the contracts, the site, or the keeper
scripts, please report it privately — do **not** open a public issue.

- Email: **partners@x-phere.com** (subject: `SECURITY`)
- Include: affected contract/address, reproduction steps, and impact estimate.

We will acknowledge reports within 72 hours. Please allow time for a fix and
coordinated disclosure before sharing details publicly.

## Scope

| Component | Address / location |
|---|---|
| XPStakingVault | `0xaE4435bB474716E130be2aC8e6C244f171451064` (Xphere mainnet) |
| RewardDistributor | `0x24C5912B63a8B41DA80EBDC2115949fcbb41Fddf` |
| WXP | `0x780E8c0443F6d702De0c72650648C7CAA591e8f0` |
| Web dashboard | `web/` → stake.x-phere.com |
| Keeper scripts | `ops/` |

## Design notes for researchers

- Vault logic is immutable (no proxies). Parameter changes go through a
  48-hour on-chain timelock within immutable bounds.
- Principal and reward accounting are separate ledgers; the core solvency
  invariant is `WXP.balanceOf(vault) ≥ staked + pendingRedeem + rewardReserves`
  (checked live at [stake.x-phere.com/status.html](https://stake.x-phere.com/status.html)).
- The share rate is fixed at 10³:1 — `totalAssets()` reads internal
  accounting only, so donation/inflation vectors do not move the rate.
- `settle()` is permissionless and snapshot-based.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full threat analysis.
