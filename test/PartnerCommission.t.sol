// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./Base.t.sol";
import {PartnerCommissionDistributor, IPartnerTVL} from "../src/PartnerCommissionDistributor.sol";

contract PartnerCommissionTest is BaseTest {
    PartnerCommissionDistributor internal commission;

    address internal ankrAdmin = makeAddr("ankrAdmin");
    address internal nansenAdmin = makeAddr("nansenAdmin");
    address internal ankrPayout = makeAddr("ankrPayout");
    address internal nansenPayout = makeAddr("nansenPayout");
    address internal treasury = makeAddr("treasury");

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        commission = new PartnerCommissionDistributor(IPartnerTVL(address(vault)), admin);
        vm.prank(admin);
        commission.registerPartner(ANKR, ankrAdmin, ankrPayout);
        vm.prank(admin);
        commission.registerPartner(NANSEN, nansenAdmin, nansenPayout);
        vm.deal(treasury, 1_000_000 ether);
    }

    function _referralDeposit(address user, uint256 amount, bytes32 pid) internal {
        vm.prank(user);
        vault.depositNativeWithReferral{value: amount}(user, pid);
    }

    function test_ProRataSplitByPartnerTVL() public {
        // Ankr routes 3M, Nansen routes 1M -> 75/25 split
        _referralDeposit(alice, 3_000_000 ether, ANKR);
        _referralDeposit(bob, 1_000_000 ether, NANSEN);

        vm.prank(treasury);
        commission.fund{value: 1_000 ether}();

        vm.prank(admin);
        uint256 allocated = commission.distribute(1_000 ether);
        assertEq(allocated, 1_000 ether);
        assertEq(commission.pendingCommission(ANKR), 750 ether);
        assertEq(commission.pendingCommission(NANSEN), 250 ether);
    }

    function test_ClaimSendsToPayout() public {
        _referralDeposit(alice, 1_000_000 ether, ANKR);
        vm.prank(treasury);
        commission.fund{value: 500 ether}();
        vm.prank(admin);
        commission.distribute(500 ether);

        uint256 before = ankrPayout.balance;
        commission.claim(ANKR); // permissionless; goes to payout
        assertEq(ankrPayout.balance - before, 500 ether);
        assertEq(commission.pendingCommission(ANKR), 0);
        assertEq(commission.totalAccrued(), 0);
    }

    function test_SolvencyInvariantBalanceCoversAccrued() public {
        _referralDeposit(alice, 2_000_000 ether, ANKR);
        _referralDeposit(bob, 2_000_000 ether, NANSEN);
        vm.prank(treasury);
        commission.fund{value: 10_000 ether}();
        vm.prank(admin);
        commission.distribute(4_000 ether);
        assertGe(address(commission).balance, commission.totalAccrued());
        // remaining budget still distributable
        assertEq(commission.availableBudget(), 6_000 ether);
    }

    function test_DistributeRevertsWithoutBudget() public {
        _referralDeposit(alice, 1_000_000 ether, ANKR);
        vm.prank(admin);
        vm.expectRevert(PartnerCommissionDistributor.InsufficientBudget.selector);
        commission.distribute(1 ether); // nothing funded
    }

    function test_DistributeRevertsWithoutTVL() public {
        // partners registered but no TVL routed
        vm.prank(treasury);
        commission.fund{value: 100 ether}();
        vm.prank(admin);
        vm.expectRevert(PartnerCommissionDistributor.NoPartnerTVL.selector);
        commission.distribute(100 ether);
    }

    function test_PreviewMatchesDistribute() public {
        _referralDeposit(alice, 6_000_000 ether, ANKR);
        _referralDeposit(bob, 2_000_000 ether, NANSEN);
        (bytes32[] memory ids, uint256[] memory shares) = commission.previewDistribution(800 ether);
        assertEq(ids.length, 2);
        // 6M:2M = 3:1 -> 600 / 200
        uint256 ankrShare = ids[0] == ANKR ? shares[0] : shares[1];
        uint256 nansenShare = ids[0] == NANSEN ? shares[0] : shares[1];
        assertEq(ankrShare, 600 ether);
        assertEq(nansenShare, 200 ether);
    }

    function test_RemovePartnerKeepsAccruedClaimable() public {
        _referralDeposit(alice, 1_000_000 ether, ANKR);
        vm.prank(treasury);
        commission.fund{value: 300 ether}();
        vm.prank(admin);
        commission.distribute(300 ether);

        vm.prank(admin);
        commission.removePartner(ANKR);
        assertEq(commission.partnerCount(), 1);
        // accrued survives removal
        commission.claim(ANKR);
        assertEq(ankrPayout.balance, 300 ether);
    }

    function test_SetPayoutRedirects() public {
        _referralDeposit(alice, 1_000_000 ether, ANKR);
        vm.prank(treasury);
        commission.fund{value: 100 ether}();
        vm.prank(admin);
        commission.distribute(100 ether);

        address newPayout = makeAddr("ankrNew");
        vm.prank(admin);
        commission.setPayout(ANKR, newPayout);
        commission.claim(ANKR);
        assertEq(newPayout.balance, 100 ether);
        assertEq(ankrPayout.balance, 0);
    }

    function test_OnlyAdminDistributes() public {
        _referralDeposit(alice, 1_000_000 ether, ANKR);
        vm.prank(treasury);
        commission.fund{value: 100 ether}();
        vm.prank(alice);
        vm.expectRevert();
        commission.distribute(100 ether);
    }

    // --- guard / edge coverage ---

    function test_RegisterGuards() public {
        vm.startPrank(admin);
        vm.expectRevert(PartnerCommissionDistributor.ZeroAddress.selector);
        commission.registerPartner(keccak256("x"), address(0), ankrPayout);
        vm.expectRevert(PartnerCommissionDistributor.ZeroAddress.selector);
        commission.registerPartner(keccak256("x"), ankrAdmin, address(0));
        vm.expectRevert(PartnerCommissionDistributor.PartnerExists.selector);
        commission.registerPartner(ANKR, ankrAdmin, ankrPayout); // already registered in setUp
        vm.stopPrank();
    }

    // --- partner wallet self-service ---

    function test_PartnerAdminCanChangeOwnPayout() public {
        address newPayout = makeAddr("ankrTreasury");
        vm.prank(ankrAdmin); // partner's own wallet, no foundation involvement
        commission.setPayout(ANKR, newPayout);

        _referralDeposit(alice, 1_000_000 ether, ANKR);
        vm.prank(treasury);
        commission.fund{value: 100 ether}();
        vm.prank(admin);
        commission.distribute(100 ether);
        commission.claim(ANKR);
        assertEq(newPayout.balance, 100 ether);
    }

    function test_StrangerCannotChangePayout() public {
        vm.prank(bob); // neither partner admin nor foundation
        vm.expectRevert(PartnerCommissionDistributor.NotPartnerAdmin.selector);
        commission.setPayout(ANKR, bob);
        // one partner cannot touch another partner's settings either
        vm.prank(nansenAdmin);
        vm.expectRevert(PartnerCommissionDistributor.NotPartnerAdmin.selector);
        commission.setPayout(ANKR, nansenAdmin);
    }

    function test_PartnerAdminHandOver() public {
        address newAdmin = makeAddr("ankrOps");
        vm.prank(ankrAdmin);
        commission.transferPartnerAdmin(ANKR, newAdmin);
        // old admin loses control, new admin gains it
        vm.prank(ankrAdmin);
        vm.expectRevert(PartnerCommissionDistributor.NotPartnerAdmin.selector);
        commission.setPayout(ANKR, ankrAdmin);
        vm.prank(newAdmin);
        commission.setPayout(ANKR, newAdmin);
        (, address adminNow, address payoutNow,,,) = commission.partnerCommissionInfo(ANKR);
        assertEq(adminNow, newAdmin);
        assertEq(payoutNow, newAdmin);
    }

    function test_FoundationRecoveryAccess() public {
        // foundation can recover a partner that lost its admin key
        address rescued = makeAddr("rescuedAdmin");
        vm.prank(admin);
        commission.transferPartnerAdmin(ANKR, rescued);
        vm.prank(rescued);
        commission.setPayout(ANKR, rescued);
    }

    function test_SetPayoutUnknownReverts() public {
        vm.prank(admin);
        vm.expectRevert(PartnerCommissionDistributor.PartnerUnknown.selector);
        commission.setPayout(keccak256("ghost"), ankrPayout);
    }

    function test_RemoveUnknownReverts() public {
        vm.prank(admin);
        vm.expectRevert(PartnerCommissionDistributor.PartnerUnknown.selector);
        commission.removePartner(keccak256("ghost"));
    }

    function test_ClaimNothingReverts() public {
        vm.expectRevert(PartnerCommissionDistributor.NothingToClaim.selector);
        commission.claim(ANKR);
    }

    function test_DistributeZeroReverts() public {
        vm.prank(admin);
        vm.expectRevert(PartnerCommissionDistributor.NothingToDistribute.selector);
        commission.distribute(0);
    }

    function test_FundViaReceiveAndViews() public {
        (bool ok,) = address(commission).call{value: 10 ether}("");
        assertTrue(ok);
        assertEq(commission.availableBudget(), 10 ether);
        assertEq(commission.partnerCount(), 2);
        assertEq(commission.registeredPartners().length, 2);
        (bool reg, address padmin, address payout,,,) = commission.partnerCommissionInfo(ANKR);
        assertTrue(reg);
        assertEq(padmin, ankrAdmin);
        assertEq(payout, ankrPayout);
    }

    function test_LastDistributionSnapshot() public {
        _referralDeposit(alice, 1_000_000 ether, ANKR);
        vm.prank(treasury);
        commission.fund{value: 200 ether}();
        vm.prank(admin);
        commission.distribute(200 ether);
        (, uint256 budget, uint256 allocated,) = commission.lastDistribution();
        assertEq(budget, 200 ether);
        assertEq(allocated, 200 ether);
    }

    function test_DoesNotTouchVaultRewardSplit() public {
        // commission distribution must not change staker rewards or burn
        _referralDeposit(alice, 1_000_000 ether, ANKR);
        _matchCapToStake();
        (uint256 burned, uint256 distributed) = _fundAndSettle(1000 ether);
        assertEq(burned, 400 ether);
        assertEq(distributed, 600 ether);

        vm.prank(treasury);
        commission.fund{value: 500 ether}();
        vm.prank(admin);
        commission.distribute(500 ether);

        // vault reward accounting unchanged by commission module
        assertEq(vault.rewardReserves(), 600 ether);
        assertEq(distributor.totalBurned(), 400 ether);
    }
}
