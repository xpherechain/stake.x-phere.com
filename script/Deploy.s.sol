// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {WXP} from "../src/WXP.sol";
import {XPStakingVault} from "../src/XPStakingVault.sol";
import {RewardDistributor} from "../src/RewardDistributor.sol";
import {IWXP} from "../src/interfaces/IWXP.sol";
import {IXPStakingVault} from "../src/interfaces/IXPStakingVault.sol";

/// @notice Deploys the vault system following the sequence in docs/ARCHITECTURE.md §10.
/// @dev Role hand-off to a Timelock/Safe and the foundation seed stake are operational
///      steps performed after this script; see §10 steps 5-9.
contract Deploy is Script {
    // Defaults — override via env before mainnet.
    address constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint256 constant CAP = 35_000_000 ether;
    uint256 constant COOLDOWN = 7 days;
    uint256 constant MAX_COOLDOWN = 30 days;
    uint256 constant REWARDS_DURATION = 1 days;
    uint256 constant MIN_REWARDS_DURATION = 1 hours;
    uint256 constant MAX_REWARDS_DURATION = 30 days;
    uint16 constant RATIO_BPS = 6000;
    uint256 constant EPOCH = 1 days;
    uint256 constant MIN_EPOCH = 1 hours;
    uint256 constant MAX_EPOCH = 30 days;
    uint256 constant MIN_SETTLE = 100 ether;

    function run() external returns (WXP wxp, XPStakingVault vault, RewardDistributor distributor) {
        address deployer = msg.sender;
        // Final role holder (e.g. a Safe/Timelock). Defaults to the deployer for local runs.
        address finalAdmin = vm.envOr("ADMIN", deployer);

        vm.startBroadcast();
        (wxp, vault, distributor) = deploySystem(deployer, finalAdmin);
        vm.stopBroadcast();

        console2.log("WXP:", address(wxp));
        console2.log("XPStakingVault:", address(vault));
        console2.log("RewardDistributor:", address(distributor));
        console2.log("admin:", finalAdmin);
        console2.log("");
        console2.log("Next (manual, see ARCHITECTURE.md section 10):");
        console2.log("  - Split roles across Timelock(48h)/Safe per section 8.3");
        console2.log("  - Verify burnAddress is code-less; register partners");
        console2.log("  - Foundation seed stake (before node reward routing!)");
        console2.log("  - Point node reward address to the distributor");
    }

    /// @notice Deploys and wires the full system. `initialAdmin` (the caller/broadcaster) wires
    ///         the contracts, then all roles are handed to `finalAdmin` and the initial admin's
    ///         are renounced. Broadcast-free so it is unit-testable.
    function deploySystem(address initialAdmin, address finalAdmin)
        public
        returns (WXP wxp, XPStakingVault vault, RewardDistributor distributor)
    {
        // 1. WXP
        wxp = new WXP();

        // 2. Vault — initialAdmin is the wiring admin so it can grant roles below even when
        //    finalAdmin is a Safe that cannot broadcast this transaction.
        vault = new XPStakingVault(
            IWXP(address(wxp)),
            CAP,
            COOLDOWN,
            MAX_COOLDOWN,
            REWARDS_DURATION,
            MIN_REWARDS_DURATION,
            MAX_REWARDS_DURATION,
            initialAdmin
        );

        // 3. Distributor
        distributor = new RewardDistributor(
            IXPStakingVault(address(vault)),
            IWXP(address(wxp)),
            BURN,
            initialAdmin,
            RATIO_BPS,
            EPOCH,
            MIN_EPOCH,
            MAX_EPOCH,
            MIN_SETTLE
        );

        // 4. Wire distributor role + sweep target (requires DEFAULT_ADMIN_ROLE = initialAdmin)
        vault.grantRole(vault.DISTRIBUTOR_ROLE(), address(distributor));
        vault.setDistributor(address(distributor));

        // 5. Hand roles to the final admin, then drop the initial admin's, if they differ.
        //    (Finer per-role splitting — PARAM_ADMIN→Timelock, PAUSER/PARTNER_MANAGER→Safe,
        //     see ARCHITECTURE.md §8.3 — is a manual follow-up from the finalAdmin.)
        if (finalAdmin != initialAdmin) {
            _handOff(vault, distributor, initialAdmin, finalAdmin);
        }
    }

    /// @dev Grants every role to `finalAdmin` and renounces the deployer's, atomically within
    ///      the broadcast, so no window exists where the system is unowned or dual-owned.
    function _handOff(XPStakingVault vault, RewardDistributor distributor, address deployer, address finalAdmin)
        internal
    {
        bytes32 vaultAdmin = vault.DEFAULT_ADMIN_ROLE();

        // Grant to finalAdmin first (never leave the system without an admin).
        vault.grantRole(vaultAdmin, finalAdmin);
        vault.grantRole(vault.PARAM_ADMIN_ROLE(), finalAdmin);
        vault.grantRole(vault.PARTNER_MANAGER_ROLE(), finalAdmin);
        vault.grantRole(vault.PAUSER_ROLE(), finalAdmin);
        distributor.grantRole(distributor.DEFAULT_ADMIN_ROLE(), finalAdmin);
        distributor.grantRole(distributor.PARAM_ADMIN_ROLE(), finalAdmin);

        // Renounce the deployer's roles (DEFAULT_ADMIN last).
        vault.renounceRole(vault.PARAM_ADMIN_ROLE(), deployer);
        vault.renounceRole(vault.PARTNER_MANAGER_ROLE(), deployer);
        vault.renounceRole(vault.PAUSER_ROLE(), deployer);
        distributor.renounceRole(distributor.PARAM_ADMIN_ROLE(), deployer);
        distributor.renounceRole(distributor.DEFAULT_ADMIN_ROLE(), deployer);
        vault.renounceRole(vaultAdmin, deployer);
    }
}
