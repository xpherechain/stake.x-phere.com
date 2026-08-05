// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WXP} from "../src/WXP.sol";

contract WXPTest is Test {
    WXP internal wxp;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        wxp = new WXP();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function test_DepositMintsAndBacksSupply() public {
        vm.prank(alice);
        wxp.deposit{value: 10 ether}();
        assertEq(wxp.balanceOf(alice), 10 ether);
        assertEq(wxp.totalSupply(), 10 ether);
        assertEq(address(wxp).balance, 10 ether);
    }

    function test_ReceiveWrapsNative() public {
        vm.prank(alice);
        (bool ok,) = address(wxp).call{value: 5 ether}("");
        assertTrue(ok);
        assertEq(wxp.balanceOf(alice), 5 ether);
    }

    function test_WithdrawUnwraps() public {
        vm.startPrank(alice);
        wxp.deposit{value: 10 ether}();
        uint256 balBefore = alice.balance;
        wxp.withdraw(4 ether);
        vm.stopPrank();
        assertEq(wxp.balanceOf(alice), 6 ether);
        assertEq(alice.balance, balBefore + 4 ether);
    }

    function test_RevertWithdrawInsufficient() public {
        vm.prank(alice);
        vm.expectRevert(WXP.InsufficientBalance.selector);
        wxp.withdraw(1 ether);
    }

    function test_TransferAndAllowance() public {
        vm.prank(alice);
        wxp.deposit{value: 10 ether}();

        vm.prank(alice);
        wxp.transfer(bob, 3 ether);
        assertEq(wxp.balanceOf(bob), 3 ether);

        vm.prank(bob);
        wxp.approve(alice, 2 ether);
        vm.prank(alice);
        wxp.transferFrom(bob, alice, 2 ether);
        assertEq(wxp.balanceOf(bob), 1 ether);
        assertEq(wxp.allowance(bob, alice), 0);
    }

    function test_InfiniteAllowanceNotDecremented() public {
        vm.prank(alice);
        wxp.deposit{value: 10 ether}();
        vm.prank(alice);
        wxp.approve(bob, type(uint256).max);

        vm.prank(bob);
        wxp.transferFrom(alice, bob, 4 ether);
        assertEq(wxp.allowance(alice, bob), type(uint256).max);
    }

    function test_RevertTransferFromInsufficientAllowance() public {
        vm.prank(alice);
        wxp.deposit{value: 10 ether}();
        vm.prank(alice);
        wxp.approve(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(WXP.InsufficientAllowance.selector);
        wxp.transferFrom(alice, bob, 2 ether);
    }
}
