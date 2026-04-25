// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import {Script, console} from "forge-std/Script.sol";
import "../../src/AccessController.sol";
import "../../src/Blotroller.sol";

/**
 * @title DeployAccessController — patch AccessController onto existing BSC Testnet deploy
 * @notice The initial BSC Testnet deploy left `accessController = address(0)` (gating
 *         disabled). This script deploys AccessController, wires it onto Unitroller
 *         via Blotroller._setAccessController, and allowlists the deployer so
 *         mint/borrow keep working for them.
 *
 * Usage:
 *   forge script script/bsc/DeployAccessController.s.sol:DeployAccessControllerScript \
 *       --rpc-url https://data-seed-prebsc-1-s1.binance.org:8545/ \
 *       --account iost \
 *       --sender 0x8901d084cAFeaD3FCFd223961ec479181057df68 \
 *       --broadcast --legacy -vvv
 *
 * After running, manually add "accessController" to
 *   deployments/bsc_testnet-latest.json
 * (kept out of this script so we don't clobber the existing file).
 */
contract DeployAccessControllerScript is Script {
    // Unitroller proxy from deployments/bsc_testnet-latest.json
    address constant UNITROLLER = 0x78f52868F6a8Ff5fb286982F6c9a75529835e93A;

    function run() external {
        require(block.chainid == 97, "BSC Testnet only");

        vm.startBroadcast();

        console.log("=== Deploy AccessController (BSC Testnet) ===");
        console.log("deployer:", msg.sender);

        AccessController ac = new AccessController();
        console.log("AccessController:", address(ac));

        // Allowlist deployer so existing flows keep working
        ac.setAllowed(msg.sender, true);
        console.log("allowlisted deployer");

        // Wire onto Blotroller (must be called through Unitroller proxy, as admin)
        Blotroller comptroller = Blotroller(payable(UNITROLLER));
        uint err = comptroller._setAccessController(address(ac));
        require(err == 0, "_setAccessController failed");
        console.log("Blotroller.accessController set");

        // Sanity read-back
        address wired = comptroller.accessController();
        require(wired == address(ac), "mismatch after wire");
        console.log("verified accessController =", wired);

        vm.stopBroadcast();

        console.log("\n=== Done ===");
        console.log("Add to deployments/bsc_testnet-latest.json:");
        console.log('  "accessController": "', address(ac), '"');
    }
}
