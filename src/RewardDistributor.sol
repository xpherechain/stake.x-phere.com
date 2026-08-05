// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWXP} from "./interfaces/IWXP.sol";
import {IXPStakingVault} from "./interfaces/IXPStakingVault.sol";

/// @title RewardDistributor
/// @notice Receives validator rewards in native XP, then on each epoch splits the
///         accumulated balance by CAP UTILIZATION: the staker pool (ratio × amount) is
///         sized against the full stake cap, stakers receive only the filled-capacity
///         share of it, and everything else — the base burn share plus the unfilled
///         capacity's share — is sent permanently to the burn address.
/// @dev Settlement is permissionless and time-gated (once per `epochDuration`).
///      The split ratio, epoch length, and minimum settle amount are governance-tunable
///      within immutable bounds injected at construction. No function can move principal;
///      the distributor never holds user funds.
contract RewardDistributor is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Role allowed to tune the split ratio, epoch duration, and min settle amount.
    bytes32 public constant PARAM_ADMIN_ROLE = keccak256("PARAM_ADMIN_ROLE");

    /// @notice Basis-points denominator (100% == 10_000).
    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice The staking vault rewards are streamed to.
    IXPStakingVault public immutable vault;

    /// @notice Wrapped XP used as the vault asset.
    IWXP public immutable wxp;

    /// @notice Permanent burn sink for the burn share (e.g. 0x...dEaD).
    address public immutable burnAddress;

    /// @notice Lower bound for `epochDuration`.
    uint256 public immutable minEpochDuration;

    /// @notice Upper bound for `epochDuration`.
    uint256 public immutable maxEpochDuration;

    /// @notice Staker share in basis points (default 6_000 == 60%). Burn share == 10_000 - this.
    uint16 public distributionRatioBps;

    /// @notice Minimum interval between settlements.
    uint256 public epochDuration;

    /// @notice Timestamp of the last settlement (timestamp gating, not epoch index).
    uint256 public lastSettledAt;

    /// @notice Minimum balance required to settle (dust-settle griefing guard).
    uint256 public minSettleAmount;

    /// @notice Cumulative amount burned across all settlements.
    uint256 public totalBurned;

    /// @notice Cumulative amount streamed to the vault across all settlements.
    uint256 public totalDistributed;

    /// @notice Cumulative amount recycled from the vault via sweepUnallocatedRewards.
    /// @dev True fresh node inflow == (totalBurned + totalDistributed) - totalSweptIn.
    uint256 public totalSweptIn;

    struct Settlement {
        uint64 settledAt;
        uint256 totalAmount;
        uint256 burned;
        uint256 distributed;
    }

    /// @notice Snapshot of the most recent settlement (dashboard convenience).
    Settlement public lastSettlement;

    event RewardReceived(address indexed from, uint256 amount, bool viaDeposit);
    event SweepReceived(uint256 amount);
    event Settled(uint256 indexed settledAt, uint256 totalAmount, uint256 burned, uint256 distributed);
    event DistributionRatioUpdated(uint16 oldBps, uint16 newBps);
    event EpochDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event MinSettleAmountUpdated(uint256 oldMin, uint256 newMin);
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error InvalidRatio();
    error InvalidDuration();
    error EpochNotElapsed();
    error BelowMinSettle();
    error NativeTransferFailed();
    error NotVault();

    /// @param vault_ Staking vault to stream rewards to.
    /// @param wxp_ Wrapped XP contract.
    /// @param burnAddress_ Permanent burn sink (must be non-zero; should be code-less).
    /// @param admin_ Initial holder of DEFAULT_ADMIN_ROLE and PARAM_ADMIN_ROLE.
    /// @param distributionRatioBps_ Initial staker share in bps (<= 10_000).
    /// @param epochDuration_ Initial settle interval (within [min,max]EpochDuration).
    /// @param minEpochDuration_ Lower bound for epoch duration (> 0).
    /// @param maxEpochDuration_ Upper bound for epoch duration.
    /// @param minSettleAmount_ Initial minimum settle amount.
    constructor(
        IXPStakingVault vault_,
        IWXP wxp_,
        address burnAddress_,
        address admin_,
        uint16 distributionRatioBps_,
        uint256 epochDuration_,
        uint256 minEpochDuration_,
        uint256 maxEpochDuration_,
        uint256 minSettleAmount_
    ) {
        if (address(vault_) == address(0) || address(wxp_) == address(0)) {
            revert ZeroAddress();
        }
        if (burnAddress_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        if (distributionRatioBps_ > BPS_DENOMINATOR) revert InvalidRatio();
        if (minEpochDuration_ == 0 || minEpochDuration_ > maxEpochDuration_) revert InvalidDuration();
        if (epochDuration_ < minEpochDuration_ || epochDuration_ > maxEpochDuration_) revert InvalidDuration();

        vault = vault_;
        wxp = wxp_;
        burnAddress = burnAddress_;
        distributionRatioBps = distributionRatioBps_;
        epochDuration = epochDuration_;
        minEpochDuration = minEpochDuration_;
        maxEpochDuration = maxEpochDuration_;
        minSettleAmount = minSettleAmount_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PARAM_ADMIN_ROLE, admin_);
    }

    /// @notice Node reward auto-inflow path.
    receive() external payable {
        emit RewardReceived(msg.sender, msg.value, false);
    }

    /// @notice Foundation manual injection path (distinguished by event flag).
    function deposit() external payable {
        emit RewardReceived(msg.sender, msg.value, true);
    }

    /// @notice Receives recycled unallocated rewards (native XP) from the vault only.
    function receiveSweep() external payable {
        if (msg.sender != address(vault)) revert NotVault();
        totalSweptIn += msg.value;
        emit SweepReceived(msg.value);
    }

    /// @notice Permissionless epoch settlement with utilization-based distribution:
    ///         the staker pool is sized against the FULL stake cap, so the share belonging
    ///         to unfilled capacity is burned on top of the base burn share.
    /// @dev distributed = amount × ratio × min(staked, cap) ÷ cap. With the default 60% ratio:
    ///        staked == cap      → 60% distributed / 40% burned
    ///        staked == cap × ⅐ → 60%×⅐ distributed / remaining ~91.4% burned
    ///        staked == 0        → 0 distributed / 100% burned
    ///      Effective staker APR is therefore ~constant (inflow × ratio × 365 ÷ cap) regardless
    ///      of TVL, and under-utilization strictly increases the burn (burn floor = 1 − ratio).
    /// @return burned Amount burned this settlement.
    /// @return distributed Amount streamed to the vault this settlement.
    function settle() external nonReentrant returns (uint256 burned, uint256 distributed) {
        if (block.timestamp < lastSettledAt + epochDuration) revert EpochNotElapsed();

        uint256 amount = address(this).balance;
        if (amount < minSettleAmount || amount == 0) revert BelowMinSettle();

        uint256 staked = vault.totalAssets();
        uint256 cap = vault.stakeCap();
        if (cap != 0 && staked != 0) {
            uint256 effectiveStaked = staked >= cap ? cap : staked; // clamp if cap lowered below TVL
            distributed = (amount * distributionRatioBps * effectiveStaked) / (BPS_DENOMINATOR * cap);
        }
        burned = amount - distributed; // base burn + unfilled-capacity share + rounding dust

        lastSettledAt = block.timestamp;
        totalBurned += burned;
        totalDistributed += distributed;
        lastSettlement = Settlement({
            settledAt: uint64(block.timestamp), totalAmount: amount, burned: burned, distributed: distributed
        });

        // (1) burn share -> permanent sink
        if (burned > 0) {
            (bool ok,) = burnAddress.call{value: burned}("");
            if (!ok) revert NativeTransferFailed();
        }

        // (2) staker share -> wrap and transfer to vault, then (3) notify (atomic transfer->notify)
        if (distributed > 0) {
            wxp.deposit{value: distributed}();
            require(wxp.transfer(address(vault), distributed), "WXP transfer failed");
            vault.notifyRewardAmount(distributed);
        }

        emit Settled(block.timestamp, amount, burned, distributed);
    }

    /// @notice Whether settle() would currently succeed, with a human-readable reason if not.
    /// @dev Zero stakers no longer blocks settlement — the epoch simply burns 100%.
    function canSettle() external view returns (bool ok, string memory reason) {
        if (block.timestamp < lastSettledAt + epochDuration) return (false, "epoch not elapsed");
        uint256 amount = address(this).balance;
        if (amount < minSettleAmount || amount == 0) return (false, "below min settle");
        return (true, "");
    }

    /// @notice Current undistributed balance awaiting settlement.
    function pendingSettlement() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Timestamp at which the next settlement becomes eligible.
    function nextSettleTime() external view returns (uint256) {
        return lastSettledAt + epochDuration;
    }

    /// @notice Updates the staker share (applied from the next settlement).
    function setDistributionRatio(uint16 newRatioBps) external onlyRole(PARAM_ADMIN_ROLE) {
        if (newRatioBps > BPS_DENOMINATOR) revert InvalidRatio();
        emit DistributionRatioUpdated(distributionRatioBps, newRatioBps);
        distributionRatioBps = newRatioBps;
    }

    /// @notice Updates the settle interval within the immutable bounds.
    function setEpochDuration(uint256 newDuration) external onlyRole(PARAM_ADMIN_ROLE) {
        if (newDuration < minEpochDuration || newDuration > maxEpochDuration) revert InvalidDuration();
        emit EpochDurationUpdated(epochDuration, newDuration);
        epochDuration = newDuration;
    }

    /// @notice Updates the minimum settle amount.
    function setMinSettleAmount(uint256 newMin) external onlyRole(PARAM_ADMIN_ROLE) {
        emit MinSettleAmountUpdated(minSettleAmount, newMin);
        minSettleAmount = newMin;
    }

    /// @notice Recovers ERC-20 tokens mistakenly sent to the distributor.
    /// @dev The distributor's operating balance is native XP, so no ERC-20 is ever intentionally
    ///      held; WXP is only transiently wrapped-and-forwarded within settle(). Native XP is not
    ///      recoverable by design (it is pending settlement).
    function recoverERC20(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Recovered(token, to, amount);
    }
}
