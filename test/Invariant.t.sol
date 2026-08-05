// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {WXP} from "../src/WXP.sol";
import {XPStakingVault} from "../src/XPStakingVault.sol";
import {RewardDistributor} from "../src/RewardDistributor.sol";
import {IWXP} from "../src/interfaces/IWXP.sol";
import {IXPStakingVault} from "../src/interfaces/IXPStakingVault.sol";

/// @dev Bounded actor that drives the vault through deposits, redeems, and settlements.
contract VaultHandler is Test {
    WXP public wxp;
    XPStakingVault public vault;
    RewardDistributor public distributor;
    address public keeper;

    address[] public actors;
    uint256 public constant SHARE_UNIT = 1000;

    constructor(WXP _wxp, XPStakingVault _vault, RewardDistributor _dist, address _keeper) {
        wxp = _wxp;
        vault = _vault;
        distributor = _dist;
        keeper = _keeper;
        for (uint256 i = 0; i < 4; i++) {
            address a = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            actors.push(a);
            vm.deal(a, 1_000_000_000 ether);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function depositNative(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 1, 1_000_000 ether);
        if (amount > vault.maxDeposit(a)) return;
        vm.prank(a);
        try vault.depositNative{value: amount}(a) {} catch {}
    }

    function requestRedeem(uint256 seed, uint256 shares) external {
        address a = _actor(seed);
        uint256 bal = vault.balanceOf(a);
        if (bal < SHARE_UNIT) return;
        shares = bound(shares, SHARE_UNIT, bal);
        vm.prank(a);
        try vault.requestRedeem(shares, a, a) {} catch {}
    }

    function settle(uint256 amount) external {
        amount = bound(amount, 1 ether, 100_000 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(distributor).call{value: amount}("");
        if (!ok) return;
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(keeper);
        try distributor.settle() {} catch {}
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 1 hours, 10 days);
        vm.warp(block.timestamp + dt);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    receive() external payable {}
}

contract InvariantTest is StdInvariant, Test {
    WXP internal wxp;
    XPStakingVault internal vault;
    RewardDistributor internal distributor;
    VaultHandler internal handler;

    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant SHARE_UNIT = 1000;

    function setUp() public {
        wxp = new WXP();
        vm.startPrank(admin);
        vault =
            new XPStakingVault(IWXP(address(wxp)), 35_000_000 ether, 7 days, 30 days, 1 days, 1 hours, 30 days, admin);
        distributor = new RewardDistributor(
            IXPStakingVault(address(vault)), IWXP(address(wxp)), BURN, admin, 6000, 1 days, 1 hours, 30 days, 1 ether
        );
        vault.grantRole(vault.DISTRIBUTOR_ROLE(), address(distributor));
        vault.setDistributor(address(distributor));
        vm.stopPrank();

        handler = new VaultHandler(wxp, vault, distributor, keeper);
        targetContract(address(handler));
    }

    /// @notice I-1: vault WXP balance always covers principal + pending + reserves.
    function invariant_PrincipalSegregation() public view {
        uint256 backed = vault.totalStakedAssets() + vault.totalPendingRedeem() + vault.rewardReserves();
        assertGe(wxp.balanceOf(address(vault)), backed);
    }

    /// @notice I-2: fixed-rate equality totalSupply == totalStakedAssets * SHARE_UNIT.
    function invariant_FixedRate() public view {
        assertEq(vault.totalSupply(), vault.totalStakedAssets() * SHARE_UNIT);
    }

    /// @notice I-5: sum of per-user principal equals total staked principal.
    function invariant_PrincipalSumsToTotal() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            sum += vault.userPrincipal(handler.actorAt(i));
        }
        assertEq(sum, vault.totalStakedAssets());
    }

    /// @notice I-9: unallocated rewards never exceed total reward reserves.
    function invariant_UnallocatedBounded() public view {
        assertLe(vault.unallocatedRewards(), vault.rewardReserves());
    }
}
