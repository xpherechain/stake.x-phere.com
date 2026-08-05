// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IWXP
/// @notice Interface for Wrapped XP (WETH9-style wrapper for the native XP coin).
interface IWXP is IERC20 {
    /// @notice Wraps the native XP sent with the call into WXP credited to the caller.
    function deposit() external payable;

    /// @notice Unwraps `wad` WXP back into native XP sent to the caller.
    /// @param wad Amount of WXP to unwrap.
    function withdraw(uint256 wad) external;
}
