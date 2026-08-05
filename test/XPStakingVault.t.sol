// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {XPStakingVault} from "../src/XPStakingVault.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract XPStakingVaultTest is BaseTest {
    // --- deposits & fixed rate ---

    function test_DepositNativeFixedRate() public {
        uint256 shares = _depositNative(alice, 10_000 ether);
        assertEq(shares, 10_000 ether * SHARE_UNIT);
        assertEq(vault.balanceOf(alice), 10_000 ether * SHARE_UNIT);
        assertEq(vault.totalStakedAssets(), 10_000 ether);
        assertEq(vault.totalAssets(), 10_000 ether);
        assertEq(vault.userPrincipal(alice), 10_000 ether);
        // fixed-rate equality invariant
        assertEq(vault.totalSupply(), vault.totalStakedAssets() * SHARE_UNIT);
    }

    function test_DirectAttribution() public {
        _depositNative(alice, 100 ether);
        assertEq(vault.userPartner(alice), vault.PARTNER_DIRECT());
        assertEq(vault.partnerTVL(vault.PARTNER_DIRECT()), 100 ether);
    }

    function test_StandardDepositWithWXP() public {
        vm.startPrank(alice);
        wxp.deposit{value: 500 ether}();
        wxp.approve(address(vault), 500 ether);
        uint256 shares = vault.deposit(500 ether, alice);
        vm.stopPrank();
        assertEq(shares, 500 ether * SHARE_UNIT);
        assertEq(vault.totalStakedAssets(), 500 ether);
    }

    function test_MintRequiresAlignedShares() public {
        vm.startPrank(alice);
        wxp.deposit{value: 1000 ether}();
        wxp.approve(address(vault), 1000 ether);
        vm.expectRevert(XPStakingVault.SharesNotAligned.selector);
        vault.mint(1500, alice); // not a multiple of SHARE_UNIT
        // aligned mint works
        uint256 assets = vault.mint(1000 * SHARE_UNIT, alice);
        vm.stopPrank();
        assertEq(assets, 1000);
    }

    function test_RevertZeroDeposit() public {
        vm.prank(alice);
        vm.expectRevert(XPStakingVault.ZeroAssets.selector);
        vault.depositNative{value: 0}(alice);
    }

    // --- cap ---

    function test_GlobalCapEnforced() public {
        _depositNative(alice, CAP);
        assertEq(vault.maxDeposit(bob), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, bob, 1 ether, 0));
        vault.depositNative{value: 1 ether}(bob);
    }

    function test_MaxDepositSaturatesAfterCapLowered() public {
        _depositNative(alice, 10_000 ether);
        vm.prank(admin);
        vault.setStakeCap(5_000 ether); // below current TVL
        assertEq(vault.maxDeposit(bob), 0); // saturating, no revert
        // existing principal untouched, still withdrawable
        assertEq(vault.userPrincipal(alice), 10_000 ether);
    }

    // --- referral ---

    function test_ReferralAttribution() public {
        vm.prank(alice);
        uint256 shares = vault.depositNativeWithReferral{value: 1_000 ether}(alice, ANKR);
        assertEq(shares, 1_000 ether * SHARE_UNIT);
        assertEq(vault.userPartner(alice), ANKR);
        assertEq(vault.partnerTVL(ANKR), 1_000 ether);
    }

    function test_ReferralSubCapEnforced() public {
        vm.prank(admin);
        vault.setPartnerCap(ANKR, 500 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, 600 ether, 500 ether));
        vault.depositNativeWithReferral{value: 600 ether}(alice, ANKR);
    }

    function test_MismatchPartnerReverts() public {
        vm.prank(alice);
        vault.depositNativeWithReferral{value: 100 ether}(alice, ANKR);
        vm.prank(alice);
        vm.expectRevert(XPStakingVault.PartnerMismatch.selector);
        vault.depositNativeWithReferral{value: 100 ether}(alice, NANSEN);
    }

    function test_DirectThenReferralReverts() public {
        _depositNative(alice, 100 ether); // direct
        vm.prank(alice);
        vm.expectRevert(XPStakingVault.PartnerMismatch.selector);
        vault.depositNativeWithReferral{value: 100 ether}(alice, ANKR);
    }

    function test_FrontRunAttributionBlocked() public {
        // bob (a partner router) tries to attribute alice to ANKR without authorization
        vm.startPrank(bob);
        wxp.deposit{value: 100 ether}();
        wxp.approve(address(vault), 100 ether);
        vm.expectRevert(XPStakingVault.UnauthorizedAttribution.selector);
        vault.depositWithReferral(100 ether, alice, ANKR); // caller != receiver
        vm.stopPrank();
    }

    function test_OperatorMayAttribute() public {
        vm.prank(alice);
        vault.setOperator(bob, true);
        vm.startPrank(bob);
        wxp.deposit{value: 100 ether}();
        wxp.approve(address(vault), 100 ether);
        vault.depositWithReferral(100 ether, alice, ANKR);
        vm.stopPrank();
        assertEq(vault.userPartner(alice), ANKR);
        assertEq(vault.partnerTVL(ANKR), 100 ether);
    }

    function test_ReassignMovesPrincipal() public {
        vm.prank(alice);
        vault.depositNativeWithReferral{value: 1_000 ether}(alice, ANKR);
        vm.prank(admin);
        vault.reassignUserPartner(alice, NANSEN);
        assertEq(vault.partnerTVL(ANKR), 0);
        assertEq(vault.partnerTVL(NANSEN), 1_000 ether);
        assertEq(vault.userPartner(alice), NANSEN);
    }

    function test_InactivePartnerBlocksNewButNotExisting() public {
        vm.prank(alice);
        vault.depositNativeWithReferral{value: 100 ether}(alice, ANKR);
        vm.prank(admin);
        vault.setPartnerActive(ANKR, false);
        // existing user can still top up
        vm.prank(alice);
        vault.depositNativeWithReferral{value: 50 ether}(alice, ANKR);
        assertEq(vault.partnerTVL(ANKR), 150 ether);
        // new user cannot attribute to inactive partner
        vm.prank(bob);
        vm.expectRevert(XPStakingVault.PartnerNotActive.selector);
        vault.depositNativeWithReferral{value: 50 ether}(bob, ANKR);
    }

    // --- async redeem ---

    function test_RequestRedeemBurnsSharesAndFreesCap() public {
        _depositNative(alice, 10_000 ether);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(4_000 ether * SHARE_UNIT, alice, alice);

        assertEq(vault.balanceOf(alice), 6_000 ether * SHARE_UNIT);
        assertEq(vault.totalStakedAssets(), 6_000 ether);
        assertEq(vault.totalPendingRedeem(), 4_000 ether);
        assertEq(vault.userPrincipal(alice), 6_000 ether);
        // fixed rate still holds after partial redeem
        assertEq(vault.totalSupply(), vault.totalStakedAssets() * SHARE_UNIT);
        // before cooldown: pending shown, not yet claimable
        assertEq(vault.pendingRedeemRequest(id, alice), 4_000 ether * SHARE_UNIT);
        assertEq(vault.claimableRedeemRequest(id, alice), 0);
        // after cooldown: claimable shown, no longer pending
        vm.warp(block.timestamp + COOLDOWN);
        assertEq(vault.pendingRedeemRequest(id, alice), 0);
        assertEq(vault.claimableRedeemRequest(id, alice), 4_000 ether * SHARE_UNIT);
    }

    function test_CooldownEnforced() public {
        _depositNative(alice, 1_000 ether);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(1_000 ether * SHARE_UNIT, alice, alice);

        vm.prank(alice);
        vm.expectRevert(XPStakingVault.CooldownNotElapsed.selector);
        vault.claimRedeem(id, alice);

        vm.warp(block.timestamp + COOLDOWN);
        uint256 balBefore = wxp.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.claimRedeem(id, alice);
        assertEq(assets, 1_000 ether);
        assertEq(wxp.balanceOf(alice) - balBefore, 1_000 ether);
        assertEq(vault.totalPendingRedeem(), 0);
    }

    function test_ClaimRedeemNativeReturnsXP() public {
        _depositNative(alice, 1_000 ether);
        vm.prank(alice);
        uint256 id = vault.requestRedeem(1_000 ether * SHARE_UNIT, alice, alice);
        vm.warp(block.timestamp + COOLDOWN);
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        uint256 assets = vault.claimRedeemNative(id, alice);
        assertEq(assets, 1_000 ether);
        assertEq(alice.balance - balBefore, 1_000 ether);
        // cannot double claim
        vm.prank(alice);
        vm.expectRevert(XPStakingVault.AlreadyClaimed.selector);
        vault.claimRedeemNative(id, alice);
    }

    function test_RedeemRoundsDownDustStaysWithOwner() public {
        // deposit 2 wei of principal -> 2000 shares
        _depositNative(alice, 2);
        assertEq(vault.balanceOf(alice), 2000);
        // request an unaligned amount (1500 shares): floors to 1 asset, burns exactly 1000 shares
        vm.prank(alice);
        uint256 id = vault.requestRedeem(1500, alice, alice);
        assertEq(redeemAssets(id), 1); // 1 wei principal redeemed
        assertEq(vault.balanceOf(alice), 1000); // remaining shares stay with owner
        assertEq(vault.userPrincipal(alice), 1);
        // fixed-rate equality preserved
        assertEq(vault.totalSupply(), vault.totalStakedAssets() * SHARE_UNIT);
    }

    function redeemAssets(uint256 id) internal view returns (uint256) {
        (,, uint256 assets,) = vault.redeemRequests(id);
        return assets;
    }

    function test_OnlyOwnerOrOperatorCanRequest() public {
        _depositNative(alice, 1_000 ether);
        vm.prank(bob);
        vm.expectRevert(XPStakingVault.Unauthorized.selector);
        vault.requestRedeem(100 ether * SHARE_UNIT, bob, alice);
    }

    // --- pause ---

    function test_PauseBlocksDepositsOnly() public {
        _depositNative(alice, 1_000 ether);
        vm.prank(admin);
        vault.pause();

        assertEq(vault.maxDeposit(bob), 0);
        vm.prank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.depositNative{value: 1 ether}(bob);

        // redeem still works while paused
        vm.prank(alice);
        uint256 id = vault.requestRedeem(1_000 ether * SHARE_UNIT, alice, alice);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(alice);
        vault.claimRedeem(id, alice);
        assertEq(wxp.balanceOf(alice), 1_000 ether);
    }

    // --- non-transferable shares ---

    function test_SharesNonTransferable() public {
        _depositNative(alice, 1_000 ether);
        vm.prank(alice);
        vm.expectRevert(XPStakingVault.TransfersDisabled.selector);
        vault.transfer(bob, 1);
    }

    // --- disabled sync exit ---

    function test_SyncWithdrawRedeemDisabled() public {
        _depositNative(alice, 1_000 ether);
        vm.startPrank(alice);
        vm.expectRevert(XPStakingVault.AsyncRedeemOnly.selector);
        vault.withdraw(1, alice, alice);
        vm.expectRevert(XPStakingVault.AsyncRedeemOnly.selector);
        vault.redeem(1, alice, alice);
        vm.stopPrank();
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
    }

    // --- governance guards ---

    function test_CooldownCannotExceedMax() public {
        vm.prank(admin);
        vm.expectRevert(XPStakingVault.InvalidConfig.selector);
        vault.setCooldownPeriod(MAX_COOLDOWN + 1);
    }

    function test_OnlyRoleGuards() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setStakeCap(1);
        vm.prank(alice);
        vm.expectRevert();
        vault.registerPartner(keccak256("x"), 0);
    }
}
