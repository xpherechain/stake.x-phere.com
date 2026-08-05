// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {XPStakingVault} from "../src/XPStakingVault.sol";
import {RewardDistributor} from "../src/RewardDistributor.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

/// @dev Regression tests for findings confirmed in the 2026-07-08 security audit.
contract AuditFixesTest is BaseTest {
    // --- Finding 1 (MEDIUM): third-party attribution griefing DoS ---

    function test_Audit_ThirdPartyCannotPinDirectAttribution() public {
        // attacker deposits 1 wei to victim (bob) trying to lock him to PARTNER_DIRECT
        vm.startPrank(alice);
        wxp.deposit{value: 1}();
        wxp.approve(address(vault), 1);
        vm.expectRevert(XPStakingVault.UnauthorizedAttribution.selector);
        vault.deposit(1, bob); // caller != receiver, bob unattributed -> blocked
        vm.stopPrank();

        // bob can still freely choose his partner afterwards
        vm.prank(bob);
        vault.depositNativeWithReferral{value: 100 ether}(bob, ANKR);
        assertEq(vault.userPartner(bob), ANKR);
    }

    function test_Audit_ThirdPartyDepositNativeToFreshReceiverBlocked() public {
        vm.prank(alice);
        vm.expectRevert(XPStakingVault.UnauthorizedAttribution.selector);
        vault.depositNative{value: 1 ether}(bob); // alice funding a fresh bob -> blocked
    }

    function test_Audit_OperatorCanDepositForReceiver() public {
        // legitimate delegated deposit: bob approves alice as operator first
        vm.prank(bob);
        vault.setOperator(alice, true);
        vm.startPrank(alice);
        wxp.deposit{value: 100 ether}();
        wxp.approve(address(vault), 100 ether);
        vault.deposit(100 ether, bob); // now allowed
        vm.stopPrank();
        assertEq(vault.userPartner(bob), vault.PARTNER_DIRECT());
        assertEq(vault.userPrincipal(bob), 100 ether);
    }

    function test_Audit_ThirdPartyCanTopUpAlreadyAttributedReceiver() public {
        // once bob is attributed, anyone may add to his (single) bucket
        vm.prank(bob);
        vault.depositNative{value: 100 ether}(bob); // bob -> DIRECT
        vm.startPrank(alice);
        wxp.deposit{value: 50 ether}();
        wxp.approve(address(vault), 50 ether);
        vault.deposit(50 ether, bob); // allowed: attribution already fixed
        vm.stopPrank();
        assertEq(vault.userPrincipal(bob), 150 ether);
        assertEq(vault.partnerTVL(vault.PARTNER_DIRECT()), 150 ether);
    }

    // --- Finding 2 (MEDIUM): requestRedeem controller == 0 destroys principal ---

    function test_Audit_RequestRedeemRejectsZeroController() public {
        _depositNative(alice, 1_000 ether);
        vm.prank(alice);
        vm.expectRevert(XPStakingVault.ZeroAddress.selector);
        vault.requestRedeem(1_000 ether * SHARE_UNIT, address(0), alice);
    }

    // --- Finding 3 (MEDIUM): recoverERC20 for mistakenly-sent tokens ---

    function test_Audit_RecoverERC20Vault() public {
        MockERC20 token = new MockERC20();
        token.transfer(address(vault), 1_000 ether); // fat-finger into the vault
        vm.prank(admin);
        vault.recoverERC20(address(token), admin, 1_000 ether);
        assertEq(token.balanceOf(admin), 1_000 ether);
    }

    function test_Audit_RecoverERC20CannotTouchWXP() public {
        _depositNative(alice, 1_000 ether); // vault now holds WXP principal
        vm.prank(admin);
        vm.expectRevert(XPStakingVault.CannotRecoverAsset.selector);
        vault.recoverERC20(address(wxp), admin, 1 ether);
    }

    function test_Audit_RecoverERC20Distributor() public {
        MockERC20 token = new MockERC20();
        token.transfer(address(distributor), 500 ether);
        vm.prank(admin);
        distributor.recoverERC20(address(token), admin, 500 ether);
        assertEq(token.balanceOf(admin), 500 ether);
    }

    function test_Audit_RecoverERC20OnlyAdmin() public {
        MockERC20 token = new MockERC20();
        token.transfer(address(vault), 100 ether);
        vm.prank(alice);
        vm.expectRevert();
        vault.recoverERC20(address(token), alice, 100 ether);
    }

    // --- Finding 4 (INFO): maxMint saturates instead of reverting ---

    function test_Audit_MaxMintSaturatesOnExtremeCap() public {
        vm.prank(admin);
        vault.setStakeCap(type(uint256).max); // extreme cap
        // maxMint must not revert; saturates to max
        assertEq(vault.maxMint(alice), type(uint256).max);
    }
}
