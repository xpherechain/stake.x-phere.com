// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";

contract ScenarioTest is BaseTest {
    // --- inflation / donation attack immunity ---

    function test_InflationAttackImmune() public {
        // Attacker is the first depositor with 1 wei, then donates a large amount of WXP
        // directly to the vault trying to inflate the share price and steal from a victim.
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1_000_000 ether);

        vm.prank(attacker);
        vault.depositNative{value: 1}(attacker); // 1 wei -> SHARE_UNIT shares

        // Donate 10_000 WXP straight into the vault (not through deposit).
        vm.startPrank(attacker);
        wxp.deposit{value: 10_000 ether}();
        wxp.transfer(address(vault), 10_000 ether); // donation
        vm.stopPrank();

        // Victim deposits 1_000 XP. Exchange rate must be unaffected by the donation.
        uint256 victimShares = _depositNative(bob, 1_000 ether);
        assertEq(victimShares, 1_000 ether * SHARE_UNIT); // full value, not diluted

        // Victim redeems and recovers full principal.
        vm.prank(bob);
        uint256 id = vault.requestRedeem(victimShares, bob, bob);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(bob);
        uint256 got = vault.claimRedeem(id, bob);
        assertEq(got, 1_000 ether);

        // Internal accounting ignores the donation entirely.
        assertEq(vault.totalStakedAssets(), 1); // only attacker's 1 wei of principal remains
    }

    function test_FixedRateInvariantAfterManyOps() public {
        _depositNative(alice, 12_345 ether);
        _depositNative(bob, 6_789 ether);
        vm.prank(alice);
        vault.requestRedeem(5_000 ether * SHARE_UNIT + 777, alice, alice); // unaligned remainder
        vm.prank(bob);
        vault.requestRedeem(1_111 ether * SHARE_UNIT, bob, bob);
        _depositNative(carol, 3_333 ether);

        // strict equality S == A * SHARE_UNIT preserved through all operations
        assertEq(vault.totalSupply(), vault.totalStakedAssets() * SHARE_UNIT);
    }

    // --- 5-year decay simulation ---

    /// @notice Runs 5 years of daily settlement with a yearly x0.7273 emission decay and
    ///         asserts accounting integrity: no over-promise, burn always >= 40%, and the
    ///         principal-segregation invariant holds throughout.
    function test_FiveYearDecaySimulation() public {
        _depositNative(alice, 20_000_000 ether);
        _depositNative(bob, 10_000_000 ether);

        uint256 dailyInflow = 27_027 ether; // starting daily reward inflow
        uint256 totalBurnedExpectedMin;
        uint256 totalInflow;

        for (uint256 year = 0; year < 5; year++) {
            for (uint256 day = 0; day < 365; day++) {
                vm.deal(address(this), dailyInflow);
                (bool ok,) = address(distributor).call{value: dailyInflow}("");
                require(ok, "fund");
                vm.warp(block.timestamp + EPOCH);
                vm.prank(keeper);
                (uint256 burned, uint256 distributed) = distributor.settle();

                totalInflow += dailyInflow;
                totalBurnedExpectedMin += (dailyInflow * 4000) / 10_000;
                assertGe(burned, (dailyInflow * 4000) / 10_000); // dust accrues to burn
                assertEq(burned + distributed, dailyInflow);

                // principal segregation invariant holds every settle
                _assertPrincipalSegregation();
            }
            // yearly decay: x0.7273
            dailyInflow = (dailyInflow * 7273) / 10_000;
        }

        assertGe(distributor.totalBurned(), totalBurnedExpectedMin);
        assertEq(distributor.totalBurned() + distributor.totalDistributed(), totalInflow);

        // both stakers can still exit with full principal
        _assertFullExit(alice);
        _assertFullExit(bob);
    }

    function _assertPrincipalSegregation() internal view {
        uint256 backed = vault.totalStakedAssets() + vault.totalPendingRedeem() + vault.rewardReserves();
        assertGe(wxp.balanceOf(address(vault)), backed);
    }

    function _assertFullExit(address user) internal {
        uint256 principal = vault.userPrincipal(user);
        vm.prank(user);
        uint256 id = vault.requestRedeem(principal * SHARE_UNIT, user, user);
        vm.warp(block.timestamp + COOLDOWN);
        uint256 before = wxp.balanceOf(user);
        vm.prank(user);
        uint256 got = vault.claimRedeem(id, user);
        assertEq(got, principal);
        assertEq(wxp.balanceOf(user) - before, principal);
    }

    // --- slashing / reward halt: principal still fully withdrawable ---

    function test_PrincipalWithdrawableAfterRewardHalt() public {
        _depositNative(alice, 5_000 ether);
        _fundAndSettle(1000 ether);
        // rewards stop forever; a long time passes
        vm.warp(block.timestamp + 365 days);
        // principal fully recoverable
        vm.prank(alice);
        uint256 id = vault.requestRedeem(5_000 ether * SHARE_UNIT, alice, alice);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(alice);
        assertEq(vault.claimRedeem(id, alice), 5_000 ether);
    }
}
