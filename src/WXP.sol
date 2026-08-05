// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title WXP - Wrapped XP
/// @notice Canonical WETH9-pattern wrapper for the native XP coin, used as the
///         ERC-4626 asset of the XPStakingVault. Immutable and permissionless:
///         there are no owner or admin functions, and `totalSupply()` is always
///         backed 1:1 by the contract's native XP balance.
/// @dev Faithful re-implementation of the WETH9 semantics with a modern Solidity
///      compiler. `transfer`/`transferFrom` follow the ERC-20 convention.
contract WXP {
    string public constant name = "Wrapped XP";
    string public constant symbol = "WXP";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    error InsufficientBalance();
    error InsufficientAllowance();
    error NativeTransferFailed();

    /// @notice Wraps native XP sent with the call.
    receive() external payable {
        deposit();
    }

    /// @notice Wraps native XP sent with the call into WXP credited to the caller.
    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Unwraps `wad` WXP back into native XP sent to the caller.
    /// @param wad Amount of WXP to unwrap.
    function withdraw(uint256 wad) external {
        if (balanceOf[msg.sender] < wad) revert InsufficientBalance();
        balanceOf[msg.sender] -= wad;
        (bool ok,) = msg.sender.call{value: wad}("");
        if (!ok) revert NativeTransferFailed();
        emit Withdrawal(msg.sender, wad);
    }

    /// @notice Total supply equals the contract's native XP balance (WETH9 invariant).
    function totalSupply() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Sets `guy`'s allowance over the caller's WXP to `wad`.
    function approve(address guy, uint256 wad) external returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    /// @notice Transfers `wad` WXP from the caller to `dst`.
    function transfer(address dst, uint256 wad) external returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    /// @notice Transfers `wad` WXP from `src` to `dst`, spending the caller's allowance if needed.
    /// @dev An allowance of type(uint256).max is treated as infinite (not decremented).
    function transferFrom(address src, address dst, uint256 wad) public returns (bool) {
        if (balanceOf[src] < wad) revert InsufficientBalance();

        if (src != msg.sender) {
            uint256 allowed = allowance[src][msg.sender];
            if (allowed != type(uint256).max) {
                if (allowed < wad) revert InsufficientAllowance();
                allowance[src][msg.sender] = allowed - wad;
            }
        }

        balanceOf[src] -= wad;
        balanceOf[dst] += wad;

        emit Transfer(src, dst, wad);
        return true;
    }
}
