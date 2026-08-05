// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PartnerCommissionDistributor, IPartnerTVL} from "../src/PartnerCommissionDistributor.sol";

/// @notice Deploys the OPTIONAL partner commission revenue module (ARCHITECTURE.md §11.2).
/// @dev Independent of the core vault — deploy only when the foundation turns on partner
///      commissions. Reads the vault address from env and hands admin to `ADMIN` (defaults to
///      the broadcaster). Partner registration + budget funding are manual follow-ups.
///
///      Usage: VAULT=0x... ADMIN=0xSafe forge script script/DeployCommission.s.sol --broadcast
contract DeployCommission is Script {
    function run() external returns (PartnerCommissionDistributor commission) {
        address vault = vm.envAddress("VAULT");
        address deployer = msg.sender;
        address finalAdmin = vm.envOr("ADMIN", deployer);

        vm.startBroadcast();
        commission = deploy(vault, deployer, finalAdmin);
        vm.stopBroadcast();

        console2.log("PartnerCommissionDistributor:", address(commission));
        console2.log("admin:", finalAdmin);
        console2.log("");
        console2.log("Next (manual):");
        console2.log("  - registerPartner(keccak256('ankr'), ankrAdminWallet, ankrPayout) per partner");
        console2.log("    (partner manages its own payout afterwards via setPayout/transferPartnerAdmin)");
        console2.log("  - fund{value: budget}() the commission budget");
        console2.log("  - distribute(epochBudget) each period");
    }

    /// @notice Broadcast-free deploy + admin hand-off (unit-testable).
    function deploy(address vault, address initialAdmin, address finalAdmin)
        public
        returns (PartnerCommissionDistributor commission)
    {
        commission = new PartnerCommissionDistributor(IPartnerTVL(vault), initialAdmin);
        if (finalAdmin != initialAdmin) {
            commission.grantRole(commission.DEFAULT_ADMIN_ROLE(), finalAdmin);
            commission.grantRole(commission.COMMISSION_ADMIN_ROLE(), finalAdmin);
            commission.renounceRole(commission.COMMISSION_ADMIN_ROLE(), initialAdmin);
            commission.renounceRole(commission.DEFAULT_ADMIN_ROLE(), initialAdmin);
        }
    }
}
