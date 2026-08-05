// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {WXP} from "../src/WXP.sol";
import {XPStakingVault} from "../src/XPStakingVault.sol";
import {RewardDistributor} from "../src/RewardDistributor.sol";
import {IWXP} from "../src/interfaces/IWXP.sol";
import {IXPStakingVault} from "../src/interfaces/IXPStakingVault.sol";

/// @notice Testnet deployment REHEARSAL for the confirmed launch policy.
/// @dev Mirrors the mainnet plan (docs/LAUNCH_CHECKLIST.md Phase 0) but with SHORT
///      time windows so the full user journey can be rehearsed in minutes instead of days:
///        cooldown 10m · rewardsDuration 5m · epoch 5m   (mainnet: 7d / 1d / 1d)
///
///      Governance wired per decision — Safe + Timelock:
///        PARAM_ADMIN / DEFAULT_ADMIN  → TimelockController (short delay on testnet)
///        PAUSER / PARTNER_MANAGER      → Safe (defaults to deployer for rehearsal)
///      Deployer renounces all roles after wiring. Commission module is NOT deployed
///      (off-chain settlement); seed staking is skipped.
///
///      Usage:
///        SAFE=0xSafe TIMELOCK_DELAY=300 \
///        forge script script/DeployTestnet.s.sol --rpc-url $XPHERE_TESTNET --broadcast \
///          --private-key $PK --verify
contract DeployTestnet is Script {
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

    // ── testnet (rehearsal) parameters ──
    // Smaller cap than mainnet (35M) so a modest test deposit is a meaningful % of
    // the cap and the utilization-based burn is clearly visible in the rehearsal.
    uint256 constant CAP = 100_000 ether;
    uint256 constant COOLDOWN = 10 minutes;
    uint256 constant MAX_COOLDOWN = 1 days;
    uint256 constant REWARDS_DURATION = 5 minutes;
    uint256 constant MIN_REWARDS_DURATION = 1 minutes;
    uint256 constant MAX_REWARDS_DURATION = 1 days;
    uint16 constant RATIO_BPS = 6000;
    uint256 constant EPOCH = 5 minutes;
    uint256 constant MIN_EPOCH = 1 minutes;
    uint256 constant MAX_EPOCH = 1 days;
    uint256 constant MIN_SETTLE = 1 ether;

    function run()
        external
        returns (WXP wxp, XPStakingVault vault, RewardDistributor distributor, TimelockController timelock)
    {
        address deployer = msg.sender;
        address safe = vm.envOr("SAFE", deployer); // multisig; defaults to deployer for rehearsal
        uint256 delay = vm.envOr("TIMELOCK_DELAY", uint256(300)); // 300s on testnet; 48h on mainnet

        vm.startBroadcast();
        (wxp, vault, distributor, timelock) = _deploy(deployer, safe, delay);
        vm.stopBroadcast();

        console2.log("== deployed ==");
        console2.log("WXP:               ", address(wxp));
        console2.log("XPStakingVault:    ", address(vault));
        console2.log("RewardDistributor: ", address(distributor));
        console2.log("TimelockController:", address(timelock));
        console2.log("Safe (pauser/partner-mgr):", safe);
        console2.log("Timelock delay (s):", delay);
        console2.log("");
        console2.log("Rehearse the user journey with: ./script/rehearse.sh");
        console2.log("(cooldown 10m / rewardsDuration 5m / epoch 5m on testnet)");
    }

    /// @notice Broadcast-free deploy + governance wiring (unit-testable).
    function _deploy(address deployer, address safe, uint256 timelockDelay)
        public
        returns (WXP wxp, XPStakingVault vault, RewardDistributor distributor, TimelockController timelock)
    {
        // 1. WXP
        wxp = new WXP();

        // 2. Vault (deployer is initial admin so it can wire, then hands off)
        vault = new XPStakingVault(
            IWXP(address(wxp)),
            CAP,
            COOLDOWN,
            MAX_COOLDOWN,
            REWARDS_DURATION,
            MIN_REWARDS_DURATION,
            MAX_REWARDS_DURATION,
            deployer
        );

        // 3. Distributor
        distributor = new RewardDistributor(
            IXPStakingVault(address(vault)),
            IWXP(address(wxp)),
            BURN,
            deployer,
            RATIO_BPS,
            EPOCH,
            MIN_EPOCH,
            MAX_EPOCH,
            MIN_SETTLE
        );

        // 4. Timelock — Safe is the sole proposer/executor; timelock self-administers (admin=0)
        address[] memory props = new address[](1);
        props[0] = safe;
        address[] memory execs = new address[](1);
        execs[0] = safe;
        timelock = new TimelockController(timelockDelay, props, execs, address(0));

        // 5. Wire distributor role + sweep target (needs DEFAULT_ADMIN = deployer)
        vault.grantRole(vault.DISTRIBUTOR_ROLE(), address(distributor));
        vault.setDistributor(address(distributor));

        // 6. Register partners (Vault only — commission is off-chain)
        vault.registerPartner(keccak256("ankr"), 0);
        vault.registerPartner(keccak256("nansen"), 0);

        // 7. Governance hand-off (grant before renounce; DEFAULT_ADMIN last)
        //    param/admin → timelock, pauser/partner-manager → safe
        vault.grantRole(vault.PARAM_ADMIN_ROLE(), address(timelock));
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), address(timelock));
        vault.grantRole(vault.PAUSER_ROLE(), safe);
        vault.grantRole(vault.PARTNER_MANAGER_ROLE(), safe);
        distributor.grantRole(distributor.PARAM_ADMIN_ROLE(), address(timelock));
        distributor.grantRole(distributor.DEFAULT_ADMIN_ROLE(), address(timelock));

        vault.renounceRole(vault.PARAM_ADMIN_ROLE(), deployer);
        vault.renounceRole(vault.PARTNER_MANAGER_ROLE(), deployer);
        vault.renounceRole(vault.PAUSER_ROLE(), deployer);
        distributor.renounceRole(distributor.PARAM_ADMIN_ROLE(), deployer);
        distributor.renounceRole(distributor.DEFAULT_ADMIN_ROLE(), deployer);
        vault.renounceRole(vault.DEFAULT_ADMIN_ROLE(), deployer);
    }
}
