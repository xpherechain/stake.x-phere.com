// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {RewardDistributor} from "../src/RewardDistributor.sol";
import {IWXP} from "../src/interfaces/IWXP.sol";
import {IXPStakingVault} from "../src/interfaces/IXPStakingVault.sol";

contract RewardDistributorTest is BaseTest {
    // --- inflow paths ---

    function test_ReceiveAndDepositPaths() public {
        (bool ok,) = address(distributor).call{value: 5 ether}("");
        assertTrue(ok);
        assertEq(distributor.pendingSettlement(), 5 ether);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        distributor.deposit{value: 3 ether}();
        assertEq(distributor.pendingSettlement(), 8 ether);
    }

    function test_ReceiveSweepOnlyVault() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(RewardDistributor.NotVault.selector);
        distributor.receiveSweep{value: 1 ether}();
    }

    // --- canSettle branches ---

    function test_CanSettleReasons() public {
        (bool ok, string memory reason) = distributor.canSettle();
        assertFalse(ok);
        assertEq(reason, "epoch not elapsed");

        vm.warp(block.timestamp + EPOCH);
        (ok, reason) = distributor.canSettle();
        assertFalse(ok);
        assertEq(reason, "below min settle");

        (bool sent,) = address(distributor).call{value: 10 ether}("");
        assertTrue(sent);
        // zero stakers no longer blocks settlement (the epoch burns 100%)
        (ok, reason) = distributor.canSettle();
        assertTrue(ok);
        assertEq(reason, "");
    }

    function test_NextSettleTime() public {
        assertEq(distributor.nextSettleTime(), distributor.lastSettledAt() + EPOCH);
    }

    // --- full-burn / full-distribute ratio edges ---

    function test_FullBurnRatioZero() public {
        _depositNative(alice, 100 ether);
        vm.prank(admin);
        distributor.setDistributionRatio(0);
        (uint256 burned, uint256 distributed) = _fundAndSettle(100 ether);
        assertEq(burned, 100 ether);
        assertEq(distributed, 0);
    }

    function test_FullDistributeRatioMax() public {
        _depositNative(alice, 100 ether);
        _matchCapToStake(); // full utilization so ratio=100% distributes everything
        vm.prank(admin);
        distributor.setDistributionRatio(10_000);
        (uint256 burned, uint256 distributed) = _fundAndSettle(100 ether);
        assertEq(burned, 0);
        assertEq(distributed, 100 ether);
        assertEq(BURN.balance, 0);
    }

    // --- setters + guards ---

    function test_Setters() public {
        vm.startPrank(admin);
        distributor.setDistributionRatio(5000);
        assertEq(distributor.distributionRatioBps(), 5000);
        distributor.setEpochDuration(2 days);
        assertEq(distributor.epochDuration(), 2 days);
        distributor.setMinSettleAmount(5 ether);
        assertEq(distributor.minSettleAmount(), 5 ether);
        vm.stopPrank();
    }

    function test_SetterGuards() public {
        vm.startPrank(admin);
        vm.expectRevert(RewardDistributor.InvalidRatio.selector);
        distributor.setDistributionRatio(10_001);
        vm.expectRevert(RewardDistributor.InvalidDuration.selector);
        distributor.setEpochDuration(1); // below min (1 hours)
        vm.expectRevert(RewardDistributor.InvalidDuration.selector);
        distributor.setEpochDuration(31 days); // above max (30 days)
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert();
        distributor.setDistributionRatio(5000);
    }

    // --- constructor validation ---

    function test_ConstructorReverts() public {
        vm.expectRevert(RewardDistributor.ZeroAddress.selector);
        new RewardDistributor(
            IXPStakingVault(address(0)), IWXP(address(wxp)), BURN, admin, 6000, EPOCH, 1 hours, 30 days, 1 ether
        );
        vm.expectRevert(RewardDistributor.ZeroAddress.selector);
        new RewardDistributor(
            IXPStakingVault(address(vault)),
            IWXP(address(wxp)),
            address(0),
            admin,
            6000,
            EPOCH,
            1 hours,
            30 days,
            1 ether
        );
        vm.expectRevert(RewardDistributor.InvalidRatio.selector);
        new RewardDistributor(
            IXPStakingVault(address(vault)), IWXP(address(wxp)), BURN, admin, 10_001, EPOCH, 1 hours, 30 days, 1 ether
        );
        vm.expectRevert(RewardDistributor.InvalidDuration.selector);
        new RewardDistributor(
            IXPStakingVault(address(vault)), IWXP(address(wxp)), BURN, admin, 6000, EPOCH, 0, 30 days, 1 ether
        );
        vm.expectRevert(RewardDistributor.InvalidDuration.selector);
        new RewardDistributor(
            IXPStakingVault(address(vault)), IWXP(address(wxp)), BURN, admin, 6000, 40 days, 1 hours, 30 days, 1 ether
        );
    }

    // --- lastSettlement snapshot ---

    function test_LastSettlementSnapshot() public {
        _depositNative(alice, 1_000 ether);
        _matchCapToStake();
        _fundAndSettle(1000 ether);
        (uint64 settledAt, uint256 totalAmount, uint256 burned, uint256 distributed) = distributor.lastSettlement();
        assertEq(totalAmount, 1000 ether);
        assertEq(burned, 400 ether);
        assertEq(distributed, 600 ether);
        assertEq(settledAt, block.timestamp);
    }
}
