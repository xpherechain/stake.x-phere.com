// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IXPStakingVault
/// @notice Minimal interface the RewardDistributor depends on. The vault itself
///         exposes the full ERC-4626 surface plus the async-redeem and reward APIs;
///         this interface only declares the members the distributor calls.
interface IXPStakingVault {
    /// @notice Streams `reward` WXP (already transferred to the vault) to stakers over `rewardsDuration`.
    /// @dev Reverts unless the vault's unbacked WXP balance covers `reward` (real-funding check).
    /// @param reward Amount of WXP to stream. Caller must hold DISTRIBUTOR_ROLE.
    function notifyRewardAmount(uint256 reward) external;

    /// @notice Total active staking shares. Used to gate settlement when there are no stakers.
    function totalSupply() external view returns (uint256);

    /// @notice Total principal tracked by the vault (== totalAssets()).
    function totalAssets() external view returns (uint256);

    /// @notice Global stake cap. The distributor sizes the staker pool against this value,
    ///         burning the share of unfilled capacity (utilization-based distribution).
    function stakeCap() external view returns (uint256);
}
