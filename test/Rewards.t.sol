// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {XPStakingVault} from "../src/XPStakingVault.sol";
import {RewardDistributor} from "../src/RewardDistributor.sol";

contract RewardsTest is BaseTest {
    // --- distributor settlement ---

    function test_SettleSplits40_60AndBurns() public {
        _depositNative(alice, 10_000 ether);
        _matchCapToStake(); // full utilization -> exact 60/40
        (uint256 burned, uint256 distributed) = _fundAndSettle(1000 ether);
        assertEq(distributed, 600 ether);
        assertEq(burned, 400 ether);
        assertEq(distributor.totalBurned(), 400 ether);
        assertEq(distributor.totalDistributed(), 600 ether);
        assertEq(BURN.balance, 400 ether);
        // vault received 600 WXP as reward reserves
        assertEq(vault.rewardReserves(), 600 ether);
        assertEq(wxp.balanceOf(address(vault)), 10_000 ether + 600 ether);
    }

    function test_RewardAccrualAndClaim() public {
        _depositNative(alice, 10_000 ether);
        _matchCapToStake();
        _fundAndSettle(1000 ether); // 600 streamed over 1 day
        vm.warp(block.timestamp + REWARDS_DURATION); // full stream elapses

        uint256 earned = vault.earned(alice);
        assertApproxEqAbs(earned, 600 ether, 1e12); // ~600, minus rate rounding dust
        uint256 balBefore = wxp.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = vault.claimReward(alice);
        assertEq(claimed, earned);
        assertEq(wxp.balanceOf(alice) - balBefore, earned);
        assertEq(vault.earned(alice), 0);
    }

    function test_RewardProRataSplit() public {
        _depositNative(alice, 6_000 ether);
        _depositNative(bob, 4_000 ether);
        _matchCapToStake();
        _fundAndSettle(1000 ether);
        vm.warp(block.timestamp + REWARDS_DURATION);

        uint256 ea = vault.earned(alice);
        uint256 eb = vault.earned(bob);
        // 60:40 split of the 600 distributed
        assertApproxEqRel(ea, 360 ether, 1e12);
        assertApproxEqRel(eb, 240 ether, 1e12);
    }

    function test_RewardsExcludeInCooldownStake() public {
        _depositNative(alice, 5_000 ether);
        _depositNative(bob, 5_000 ether);
        // bob requests full redeem -> shares burned, excluded from future rewards
        vm.prank(bob);
        vault.requestRedeem(5_000 ether * SHARE_UNIT, bob, bob);

        _matchCapToStake(); // cap = remaining 5_000 -> full utilization
        _fundAndSettle(1000 ether);
        vm.warp(block.timestamp + REWARDS_DURATION);

        // alice is the only active staker -> gets ~all 600
        assertApproxEqAbs(vault.earned(alice), 600 ether, 1e9);
        assertEq(vault.earned(bob), 0);
    }

    // --- real-funding check ---

    function test_NotifyRevertsWithoutRealFunding() public {
        _depositNative(alice, 1_000 ether);
        // grant DISTRIBUTOR_ROLE to attacker and try a fake notify with no WXP transfer
        bytes32 role = vault.DISTRIBUTOR_ROLE();
        vm.prank(admin);
        vault.grantRole(role, address(this));
        vm.expectRevert(XPStakingVault.RewardNotFunded.selector);
        vault.notifyRewardAmount(1_000_000 ether);
    }

    function test_ClaimRewardNative() public {
        _depositNative(alice, 10_000 ether);
        _fundAndSettle(1000 ether);
        vm.warp(block.timestamp + REWARDS_DURATION);
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        uint256 amount = vault.claimRewardNative(alice);
        assertEq(alice.balance - balBefore, amount);
        assertGt(amount, 0);
    }

    // --- currentAPR ---

    function test_CurrentAPR() public {
        _depositNative(alice, 10_000 ether);
        _fundAndSettle(1000 ether); // 600 to stakers, interval defaults to rewardsDuration on first notify
        // APR = 600 * 365d * 1e18 / (interval * 10_000e18); interval == 1 day on first notify
        // = 600 * 365 / 10_000 = 21.9 -> 21.9e18? no: fraction 600*365/10000 = 21.9 -> 2190% (small TVL)
        uint256 apr = vault.currentAPR();
        assertGt(apr, 0);
        // with second settle the measured interval becomes 1 day, APR stabilizes
    }

    function test_CurrentAPRZeroWhenNoStake() public {
        assertEq(vault.currentAPR(), 0);
    }

    // --- zero-staker settle gating ---

    function test_SettleWithZeroStakersBurnsEverything() public {
        vm.deal(address(this), 1000 ether);
        (bool ok,) = address(distributor).call{value: 1000 ether}("");
        assertTrue(ok);
        vm.warp(block.timestamp + EPOCH);
        vm.prank(keeper);
        (uint256 burned, uint256 distributed) = distributor.settle();
        // no stakers -> utilization 0 -> the entire inflow is burned
        assertEq(distributed, 0);
        assertEq(burned, 1000 ether);
        assertEq(BURN.balance, 1000 ether);
        assertEq(vault.rewardReserves(), 0);
    }

    function test_UnderUtilizationBurnsUnfilledShare() public {
        // 5M staked of the 35M cap -> stakers get 60% x 5/35, the rest burns
        _depositNative(alice, 5_000_000 ether);
        (uint256 burned, uint256 distributed) = _fundAndSettle(1000 ether);
        uint256 amount = 1000 ether;
        uint256 expected = (amount * 6000 * 5_000_000 ether) / (10_000 * CAP); // CAP = 35M
        assertEq(distributed, expected); // ~85.71 XP
        assertEq(burned, 1000 ether - expected); // ~914.29 XP (>= base 40%)
        assertGt(burned, 400 ether);
    }

    function test_CapLoweredBelowTVLClampsToFullRatio() public {
        _depositNative(alice, 10_000 ether);
        vm.prank(admin);
        vault.setStakeCap(5_000 ether); // cap below current TVL -> utilization clamps to 1
        (uint256 burned, uint256 distributed) = _fundAndSettle(1000 ether);
        assertEq(distributed, 600 ether); // never exceeds the ratio share
        assertEq(burned, 400 ether);
    }

    function test_SettleEpochGating() public {
        _depositNative(alice, 1_000 ether);
        vm.deal(address(this), 2000 ether);
        (bool ok,) = address(distributor).call{value: 1000 ether}("");
        assertTrue(ok);
        vm.warp(block.timestamp + EPOCH);
        vm.prank(keeper);
        distributor.settle();
        // immediate second settle blocked
        (ok,) = address(distributor).call{value: 1000 ether}("");
        assertTrue(ok);
        vm.prank(keeper);
        vm.expectRevert(RewardDistributor.EpochNotElapsed.selector);
        distributor.settle();
    }

    function test_SettleBelowMinReverts() public {
        _depositNative(alice, 1_000 ether);
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(distributor).call{value: 0.5 ether}(""); // below 1 ether min
        assertTrue(ok);
        vm.warp(block.timestamp + EPOCH);
        vm.prank(keeper);
        vm.expectRevert(RewardDistributor.BelowMinSettle.selector);
        distributor.settle();
    }

    // --- unallocated rewards sweep ---

    function test_UnallocatedSweptWhenAllExit() public {
        _depositNative(alice, 1_000 ether);
        _matchCapToStake();
        _fundAndSettle(1000 ether); // stream 600 over a day
        // half the stream elapses, then alice exits fully
        vm.warp(block.timestamp + REWARDS_DURATION / 2);
        vm.prank(alice);
        vault.claimReward(alice); // realize her share so far
        vm.prank(alice);
        vault.requestRedeem(1_000 ether * SHARE_UNIT, alice, alice);
        // remainder of stream now strands (totalSupply == 0)
        vm.warp(block.timestamp + REWARDS_DURATION);

        vm.prank(admin);
        vault.sweepUnallocatedRewards();
        // swept amount recycled into distributor
        assertGt(distributor.totalSweptIn(), 0);
        assertEq(vault.unallocatedRewards(), 0);
    }
}
