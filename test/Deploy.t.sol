// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {WXP} from "../src/WXP.sol";
import {XPStakingVault} from "../src/XPStakingVault.sol";
import {RewardDistributor} from "../src/RewardDistributor.sol";

/// @dev Verifies the deploy script's two-step admin hand-off leaves the system fully owned
///      by the final admin (Safe) and the deployer with zero residual privilege.
contract DeployTest is Test {
    Deploy internal deployScript;
    address internal safe = makeAddr("safe");
    address internal deployer = makeAddr("deployer");

    function setUp() public {
        deployScript = new Deploy();
    }

    function test_HandOffTransfersAllRolesToFinalAdmin() public {
        // deployScript (as initialAdmin) wires the system, then hands all roles to `safe`.
        (, XPStakingVault vault, RewardDistributor distributor) = deployScript.deploySystem(address(deployScript), safe);

        // Final admin holds every role.
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), safe));
        assertTrue(vault.hasRole(vault.PARAM_ADMIN_ROLE(), safe));
        assertTrue(vault.hasRole(vault.PARTNER_MANAGER_ROLE(), safe));
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), safe));
        assertTrue(distributor.hasRole(distributor.DEFAULT_ADMIN_ROLE(), safe));
        assertTrue(distributor.hasRole(distributor.PARAM_ADMIN_ROLE(), safe));

        // Deployer retains nothing.
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(vault.hasRole(vault.PARAM_ADMIN_ROLE(), deployer));
        assertFalse(vault.hasRole(vault.PARTNER_MANAGER_ROLE(), deployer));
        assertFalse(vault.hasRole(vault.PAUSER_ROLE(), deployer));
        assertFalse(distributor.hasRole(distributor.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(distributor.hasRole(distributor.PARAM_ADMIN_ROLE(), deployer));

        // Wiring survived the hand-off.
        assertTrue(vault.hasRole(vault.DISTRIBUTOR_ROLE(), address(distributor)));
        assertEq(vault.distributor(), address(distributor));
    }

    function test_LocalRunKeepsInitialAdmin() public {
        // finalAdmin == initialAdmin -> no hand-off, initial admin retains control.
        (, XPStakingVault vault,) = deployScript.deploySystem(address(deployScript), address(deployScript));
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), address(deployScript)));
    }
}
