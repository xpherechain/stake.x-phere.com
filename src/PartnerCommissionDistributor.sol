// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal read interface into the vault's on-chain partner accounting.
interface IPartnerTVL {
    function partnerTVL(bytes32 partnerId) external view returns (uint256);
}

/// @title PartnerCommissionDistributor
/// @notice Optional, fully-separate revenue module that pays external platforms (Ankr, Nansen…)
///         a commission proportional to the TVL they route into the XPStakingVault.
/// @dev DESIGN INVARIANT: this module NEVER touches the vault's 60/40 staker-reward / burn split
///      (ARCHITECTURE.md §2, immutable). Commission is paid from an INDEPENDENT budget the
///      foundation funds here. The vault is referenced read-only (`partnerTVL`) and is not
///      modified — this is the "separate module, added later" path reserved in §3.2 / §11.2.
///
///      Payout model: the foundation periodically calls `distribute(budget)`. The budget is
///      split across registered partners in proportion to their current vault TVL snapshot and
///      accrued to each partner's pull-claimable balance. Partners `claim()` to their payout
///      address. Solvency invariant: address(this).balance >= totalAccrued at all times.
contract PartnerCommissionDistributor is AccessControl, ReentrancyGuard {
    /// @notice Role allowed to register partners, fund the budget, and distribute commission.
    bytes32 public constant COMMISSION_ADMIN_ROLE = keccak256("COMMISSION_ADMIN_ROLE");

    /// @notice Vault whose partner TVL drives the pro-rata split.
    IPartnerTVL public immutable vault;

    struct Partner {
        bool registered;
        address admin; // partner-controlled wallet: manages its own payout + admin hand-over
        address payout; // where claimed commission is sent
        uint256 accrued; // pull-claimable, not yet withdrawn
        uint256 claimed; // lifetime claimed (analytics)
    }

    mapping(bytes32 => Partner) public partners;
    bytes32[] public partnerList;

    /// @notice Sum of all partners' unclaimed `accrued`. Always <= address(this).balance.
    uint256 public totalAccrued;
    /// @notice Lifetime commission accrued across all distributions (analytics).
    uint256 public totalDistributed;

    struct Distribution {
        uint64 at;
        uint256 budget;
        uint256 allocated;
        uint256 totalTvl;
    }

    /// @notice Snapshot of the most recent distribution (dashboard convenience).
    Distribution public lastDistribution;

    event PartnerRegistered(bytes32 indexed partnerId, address indexed admin, address indexed payout);
    event PayoutUpdated(bytes32 indexed partnerId, address indexed oldPayout, address indexed newPayout);
    event PartnerAdminUpdated(bytes32 indexed partnerId, address indexed oldAdmin, address indexed newAdmin);
    event PartnerRemoved(bytes32 indexed partnerId);
    event BudgetFunded(address indexed from, uint256 amount);
    event CommissionDistributed(uint256 indexed at, uint256 budget, uint256 allocated, uint256 totalTvl);
    event CommissionClaimed(bytes32 indexed partnerId, address indexed payout, uint256 amount);

    error ZeroAddress();
    error PartnerExists();
    error PartnerUnknown();
    error NotPartnerAdmin();
    error NothingToDistribute();
    error NoPartnerTVL();
    error InsufficientBudget();
    error NothingToClaim();
    error NativeTransferFailed();

    /// @param vault_ The staking vault to read partner TVL from.
    /// @param admin_ Initial holder of DEFAULT_ADMIN_ROLE and COMMISSION_ADMIN_ROLE.
    constructor(IPartnerTVL vault_, address admin_) {
        if (address(vault_) == address(0) || admin_ == address(0)) revert ZeroAddress();
        vault = vault_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(COMMISSION_ADMIN_ROLE, admin_);
    }

    /// @notice Funds the commission budget with native XP (independent of vault rewards).
    function fund() external payable {
        emit BudgetFunded(msg.sender, msg.value);
    }

    receive() external payable {
        emit BudgetFunded(msg.sender, msg.value);
    }

    /// @dev Partner self-service gate: the partner's registered admin wallet, or the foundation
    ///      (COMMISSION_ADMIN_ROLE, for key-loss recovery), may manage that partner's settings.
    modifier onlyPartnerAdmin(bytes32 partnerId) {
        Partner storage p = partners[partnerId];
        if (!p.registered) revert PartnerUnknown();
        if (msg.sender != p.admin && !hasRole(COMMISSION_ADMIN_ROLE, msg.sender)) revert NotPartnerAdmin();
        _;
    }

    /// @notice Registers a partner, binding it to a partner-controlled admin wallet.
    /// @dev The id must match the vault's partnerId (keccak256 of the partner slug). From this
    ///      point the partner manages its own payout via `setPayout` / `transferPartnerAdmin`
    ///      with `partnerAdmin` — no foundation involvement needed for wallet changes.
    /// @param partnerId Vault-side partner id.
    /// @param partnerAdmin Partner-controlled wallet that manages this registration.
    /// @param payout Address that receives claimed commission (may equal partnerAdmin).
    function registerPartner(bytes32 partnerId, address partnerAdmin, address payout)
        external
        onlyRole(COMMISSION_ADMIN_ROLE)
    {
        if (partnerAdmin == address(0) || payout == address(0)) revert ZeroAddress();
        if (partners[partnerId].registered) revert PartnerExists();
        partners[partnerId] = Partner({registered: true, admin: partnerAdmin, payout: payout, accrued: 0, claimed: 0});
        partnerList.push(partnerId);
        emit PartnerRegistered(partnerId, partnerAdmin, payout);
    }

    /// @notice Updates a partner's payout address. Self-service for the partner's admin wallet;
    ///         the foundation retains recovery access.
    function setPayout(bytes32 partnerId, address payout) external onlyPartnerAdmin(partnerId) {
        if (payout == address(0)) revert ZeroAddress();
        Partner storage p = partners[partnerId];
        emit PayoutUpdated(partnerId, p.payout, payout);
        p.payout = payout;
    }

    /// @notice Hands the partner's admin wallet over to a new address (key rotation, org change).
    ///         Self-service for the current admin; the foundation retains recovery access.
    function transferPartnerAdmin(bytes32 partnerId, address newAdmin) external onlyPartnerAdmin(partnerId) {
        if (newAdmin == address(0)) revert ZeroAddress();
        Partner storage p = partners[partnerId];
        emit PartnerAdminUpdated(partnerId, p.admin, newAdmin);
        p.admin = newAdmin;
    }

    /// @notice Removes a partner from future distributions. Any accrued balance stays claimable.
    function removePartner(bytes32 partnerId) external onlyRole(COMMISSION_ADMIN_ROLE) {
        Partner storage p = partners[partnerId];
        if (!p.registered) revert PartnerUnknown();
        p.registered = false;
        uint256 n = partnerList.length;
        for (uint256 i = 0; i < n; i++) {
            if (partnerList[i] == partnerId) {
                partnerList[i] = partnerList[n - 1];
                partnerList.pop();
                break;
            }
        }
        emit PartnerRemoved(partnerId);
    }

    /// @notice Splits `budget` across registered partners in proportion to their current vault
    ///         TVL and accrues it to each partner's claimable balance.
    /// @dev Rounding dust (budget - allocated) stays in the contract for the next distribution.
    /// @param budget Amount of the funded budget to distribute this round.
    /// @return allocated Amount actually accrued (<= budget; remainder is rounding dust).
    function distribute(uint256 budget) external onlyRole(COMMISSION_ADMIN_ROLE) returns (uint256 allocated) {
        if (budget == 0) revert NothingToDistribute();
        // Unallocated budget = balance not yet earmarked to partners.
        if (address(this).balance - totalAccrued < budget) revert InsufficientBudget();

        uint256 n = partnerList.length;
        uint256 totalTvl;
        for (uint256 i = 0; i < n; i++) {
            totalTvl += vault.partnerTVL(partnerList[i]);
        }
        if (totalTvl == 0) revert NoPartnerTVL();

        for (uint256 i = 0; i < n; i++) {
            bytes32 pid = partnerList[i];
            uint256 tvl = vault.partnerTVL(pid);
            if (tvl == 0) continue;
            uint256 share = (budget * tvl) / totalTvl; // floor; dust retained
            if (share == 0) continue;
            partners[pid].accrued += share;
            allocated += share;
        }

        totalAccrued += allocated;
        totalDistributed += allocated;
        lastDistribution =
            Distribution({at: uint64(block.timestamp), budget: budget, allocated: allocated, totalTvl: totalTvl});
        emit CommissionDistributed(block.timestamp, budget, allocated, totalTvl);
    }

    /// @notice Claims a partner's accrued commission to its payout address.
    /// @dev Callable by anyone; funds always go to the registered payout address (pull-safe).
    function claim(bytes32 partnerId) external nonReentrant returns (uint256 amount) {
        Partner storage p = partners[partnerId];
        amount = p.accrued;
        if (amount == 0) revert NothingToClaim();
        address payout = p.payout;
        if (payout == address(0)) revert ZeroAddress();

        p.accrued = 0;
        p.claimed += amount;
        totalAccrued -= amount;

        (bool ok,) = payout.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit CommissionClaimed(partnerId, payout, amount);
    }

    // ---------------------------------------------------------------------
    // Views (dashboard / partner integration)
    // ---------------------------------------------------------------------

    /// @notice Budget available to distribute (balance not yet earmarked to partners).
    function availableBudget() external view returns (uint256) {
        return address(this).balance - totalAccrued;
    }

    /// @notice Claimable commission currently accrued to a partner.
    function pendingCommission(bytes32 partnerId) external view returns (uint256) {
        return partners[partnerId].accrued;
    }

    /// @notice Number of registered partners.
    function partnerCount() external view returns (uint256) {
        return partnerList.length;
    }

    /// @notice All registered partner ids.
    function registeredPartners() external view returns (bytes32[] memory) {
        return partnerList;
    }

    /// @notice Full commission view for a partner, including live vault TVL.
    function partnerCommissionInfo(bytes32 partnerId)
        external
        view
        returns (bool registered, address admin, address payout, uint256 tvl, uint256 accrued, uint256 claimed)
    {
        Partner memory p = partners[partnerId];
        return (p.registered, p.admin, p.payout, vault.partnerTVL(partnerId), p.accrued, p.claimed);
    }

    /// @notice Previews the split of `budget` across partners at the current TVL snapshot.
    /// @return ids Registered partner ids.
    /// @return shares Amount each partner would accrue from `budget`.
    function previewDistribution(uint256 budget) external view returns (bytes32[] memory ids, uint256[] memory shares) {
        uint256 n = partnerList.length;
        ids = new bytes32[](n);
        shares = new uint256[](n);
        uint256 totalTvl;
        for (uint256 i = 0; i < n; i++) {
            totalTvl += vault.partnerTVL(partnerList[i]);
        }
        for (uint256 i = 0; i < n; i++) {
            ids[i] = partnerList[i];
            if (totalTvl == 0) continue;
            shares[i] = (budget * vault.partnerTVL(partnerList[i])) / totalTvl;
        }
    }
}
