// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {XPStakingVault} from "../src/XPStakingVault.sol";
import {IWXP} from "../src/interfaces/IWXP.sol";

/// @dev Edge-case coverage for governance guards, reward leftover streaming, and views.
contract VaultEdgeTest is BaseTest {
    // --- reassign guards ---

    function test_ReassignRevertsNotAttributed() public {
        vm.prank(admin);
        vm.expectRevert(XPStakingVault.NotAttributed.selector);
        vault.reassignUserPartner(alice, ANKR);
    }

    function test_ReassignRevertsSameBucket() public {
        vm.prank(alice);
        vault.depositNativeWithReferral{value: 100 ether}(alice, ANKR);
        vm.prank(admin);
        vm.expectRevert(XPStakingVault.PartnerMismatch.selector);
        vault.reassignUserPartner(alice, ANKR);
    }

    function test_ReassignRevertsInactiveTarget() public {
        _depositNative(alice, 100 ether); // direct
        vm.prank(admin);
        vm.expectRevert(XPStakingVault.PartnerNotActive.selector);
        vault.reassignUserPartner(alice, keccak256("unregistered"));
    }

    function test_ReassignRespectsSubCap() public {
        vm.prank(alice);
        vault.depositNativeWithReferral{value: 1_000 ether}(alice, ANKR);
        vm.prank(admin);
        vault.setPartnerCap(NANSEN, 500 ether);
        vm.prank(admin);
        vm.expectRevert(XPStakingVault.PartnerCapExceeded.selector);
        vault.reassignUserPartner(alice, NANSEN);
    }

    function test_ReassignToDirect() public {
        bytes32 direct = vault.PARTNER_DIRECT();
        vm.prank(alice);
        vault.depositNativeWithReferral{value: 1_000 ether}(alice, ANKR);
        vm.prank(admin);
        vault.reassignUserPartner(alice, direct);
        assertEq(vault.userPartner(alice), direct);
        assertEq(vault.partnerTVL(ANKR), 0);
        assertEq(vault.partnerTVL(direct), 1_000 ether);
    }

    // --- partner mgmt guards ---

    function test_RegisterPartnerRejectsSentinels() public {
        bytes32 direct = vault.PARTNER_DIRECT();
        vm.startPrank(admin);
        vm.expectRevert(XPStakingVault.InvalidPartner.selector);
        vault.registerPartner(bytes32(0), 0);
        vm.expectRevert(XPStakingVault.InvalidPartner.selector);
        vault.registerPartner(direct, 0);
        vm.stopPrank();
    }

    function test_SetPartnerCapRequiresActive() public {
        vm.prank(admin);
        vm.expectRevert(XPStakingVault.PartnerNotActive.selector);
        vault.setPartnerCap(keccak256("ghost"), 1 ether);
    }

    function test_PartnerInfoView() public {
        vm.prank(admin);
        vault.setPartnerCap(ANKR, 777 ether);
        (bool active, uint256 subCap, uint256 tvl) = vault.partnerInfo(ANKR);
        assertTrue(active);
        assertEq(subCap, 777 ether);
        assertEq(tvl, 0);
    }

    // --- reward leftover across two settles ---

    function test_LeftoverFoldsIntoNextStream() public {
        _depositNative(alice, 10_000 ether);
        _matchCapToStake();
        _fundAndSettle(1000 ether); // stream 600 over a day
        // half the stream elapses, then a second settle folds leftover in
        vm.warp(block.timestamp + REWARDS_DURATION / 2);
        _fundAndSettle(1000 ether); // note: _fundAndSettle warps a full EPOCH internally

        // after another full duration, alice should have earned ~all of both distributions
        vm.warp(block.timestamp + REWARDS_DURATION);
        vm.prank(alice);
        uint256 claimed = vault.claimReward(alice);
        assertApproxEqRel(claimed, 1200 ether, 1e15); // ~600 + 600
    }

    function test_CurrentAPRStabilizesSecondSettle() public {
        _depositNative(alice, 10_000 ether);
        _matchCapToStake();
        _fundAndSettle(1000 ether);
        _fundAndSettle(1000 ether); // second notify -> measured interval == 1 day
        // APR = 600e18 * 365d * 1e18 / (1 day * 10_000e18) = 21.9e18 (2190%, tiny TVL)
        uint256 apr = vault.currentAPR();
        assertApproxEqRel(apr, 219e17, 1e15); // 21.9 * 1e18
    }

    // --- sweep guard ---

    function test_SweepRevertsWhenDistributorUnset() public {
        // fresh vault without setDistributor
        vm.prank(admin);
        XPStakingVault v2 = _freshVaultNoDistributor();
        vm.prank(admin);
        vm.expectRevert(XPStakingVault.DistributorNotSet.selector);
        v2.sweepUnallocatedRewards();
    }

    function test_SweepNoopWhenNothingUnallocated() public {
        _depositNative(alice, 1_000 ether);
        vm.prank(admin);
        vault.sweepUnallocatedRewards(); // unallocated == 0, returns without transfer
        assertEq(vault.unallocatedRewards(), 0);
    }

    // --- receive guard ---

    function test_ReceiveRejectsNonWXP() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok); // OnlyWXP
    }

    // --- rewards duration setter ---

    function test_SetRewardsDuration() public {
        vm.prank(admin);
        vault.setRewardsDuration(12 hours);
        assertEq(vault.rewardsDuration(), 12 hours);
        vm.prank(admin);
        vm.expectRevert(XPStakingVault.InvalidConfig.selector);
        vault.setRewardsDuration(0);
    }

    // --- views ---

    function test_RewardBalanceOfAndRequestIds() public {
        _depositNative(alice, 1_000 ether);
        _fundAndSettle(1000 ether);
        vm.warp(block.timestamp + REWARDS_DURATION);
        assertEq(vault.rewardBalanceOf(alice), vault.earned(alice));

        vm.prank(alice);
        vault.requestRedeem(500 ether * SHARE_UNIT, alice, alice);
        uint256[] memory ids = vault.getUserRequestIds(alice);
        assertEq(ids.length, 1);
    }

    function test_MaxMintReflectsCap() public {
        _depositNative(alice, 34_999_000 ether);
        assertEq(vault.maxMint(bob), 1_000 ether * SHARE_UNIT);
    }

    function _freshVaultNoDistributor() internal returns (XPStakingVault) {
        return new XPStakingVault(
            IWXP(address(wxp)), CAP, COOLDOWN, MAX_COOLDOWN, REWARDS_DURATION, 1 hours, MAX_COOLDOWN, admin
        );
    }
}
