// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WXP} from "../src/WXP.sol";
import {XPStakingVault} from "../src/XPStakingVault.sol";
import {RewardDistributor} from "../src/RewardDistributor.sol";
import {IWXP} from "../src/interfaces/IWXP.sol";
import {IXPStakingVault} from "../src/interfaces/IXPStakingVault.sol";

/// @dev Shared deployment + helpers for the vault test suite.
contract BaseTest is Test {
    WXP internal wxp;
    XPStakingVault internal vault;
    RewardDistributor internal distributor;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal keeper = makeAddr("keeper");

    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;

    uint256 internal constant CAP = 35_000_000 ether;
    uint256 internal constant COOLDOWN = 7 days;
    uint256 internal constant MAX_COOLDOWN = 30 days;
    uint256 internal constant REWARDS_DURATION = 1 days;
    uint256 internal constant EPOCH = 1 days;
    uint256 internal constant SHARE_UNIT = 1000;

    bytes32 internal constant ANKR = keccak256("ankr");
    bytes32 internal constant NANSEN = keccak256("nansen");

    function setUp() public virtual {
        wxp = new WXP();

        vm.startPrank(admin);
        vault = new XPStakingVault(
            IWXP(address(wxp)), CAP, COOLDOWN, MAX_COOLDOWN, REWARDS_DURATION, 1 hours, MAX_COOLDOWN, admin
        );
        distributor = new RewardDistributor(
            IXPStakingVault(address(vault)), IWXP(address(wxp)), BURN, admin, 6000, EPOCH, 1 hours, 30 days, 1 ether
        );
        vault.grantRole(vault.DISTRIBUTOR_ROLE(), address(distributor));
        vault.setDistributor(address(distributor));
        vault.registerPartner(ANKR, 0);
        vault.registerPartner(NANSEN, 0);
        vm.stopPrank();

        vm.deal(alice, 100_000_000 ether);
        vm.deal(bob, 100_000_000 ether);
        vm.deal(carol, 100_000_000 ether);
    }

    // --- helpers ---

    /// @dev Deposit native XP as `user` (direct attribution).
    function _depositNative(address user, uint256 amount) internal returns (uint256 shares) {
        vm.prank(user);
        shares = vault.depositNative{value: amount}(user);
    }

    /// @dev Pins the cap to the current TVL so settlement runs at 100% utilization —
    ///      used by tests that assert the full-ratio (60/40) split.
    function _matchCapToStake() internal {
        uint256 tvl = vault.totalAssets(); // read first — vm.prank applies to the next call
        vm.prank(admin);
        vault.setStakeCap(tvl);
    }

    /// @dev Route validator rewards into the distributor and settle one epoch.
    function _fundAndSettle(uint256 rewardAmount) internal returns (uint256 burned, uint256 distributed) {
        vm.deal(address(this), address(this).balance + rewardAmount);
        (bool ok,) = address(distributor).call{value: rewardAmount}("");
        require(ok, "fund failed");
        vm.warp(block.timestamp + EPOCH);
        vm.prank(keeper);
        (burned, distributed) = distributor.settle();
    }

    receive() external payable {}
}
