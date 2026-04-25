// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import {Script, console} from "forge-std/Script.sol";
import "../../src/BErc20Delegator.sol";
import "../../src/MockERC20.sol";

/**
 * @title SupplyUsdc - Supply 1000 USDC into bUSDC market on BSC Testnet
 *
 * Usage:
 *   forge script script/bsc/SupplyUsdc.s.sol:SupplyUsdcScript \
 *       --rpc-url https://data-seed-prebsc-1-s1.binance.org:8545/ \
 *       --account iost \
 *       --sender 0x8901d084cAFeaD3FCFd223961ec479181057df68 \
 *       --broadcast --legacy -vvv
 */
contract SupplyUsdcScript is Script {
    // BSC Testnet addresses (see deployments/bsc_testnet-latest.json)
    MockERC20       constant usdc  = MockERC20(0xE28a51a5b83B7C9188416214E8D2AEf6A8A27458);
    BErc20Delegator constant bUSDC = BErc20Delegator(payable(0x3A6c3b866760622090975A7688e0Baf412109389));

    uint256 constant SUPPLY_AMOUNT = 1_000 ether; // 1000 USDC (18 decimals mock)

    function run() external {
        require(block.chainid == 97, "BSC Testnet only");
        vm.startBroadcast();

        console.log("=== Supply USDC on BSC Testnet ===");
        console.log("supplier:", msg.sender);

        // 1. Make sure we have enough USDC (mint if below target)
        uint256 bal = usdc.balanceOf(msg.sender);
        console.log("USDC balance before:", bal);
        if (bal < SUPPLY_AMOUNT) {
            uint256 need = SUPPLY_AMOUNT - bal;
            console.log("minting MockUSDC:", need);
            usdc.mint(msg.sender, need);
        }

        // 2. Approve
        uint256 allowance = usdc.allowance(msg.sender, address(bUSDC));
        if (allowance < SUPPLY_AMOUNT) {
            console.log("approving bUSDC for max...");
            usdc.approve(address(bUSDC), type(uint256).max);
        }

        // 3. Mint bUSDC (supply)
        uint256 bUSDCBefore = bUSDC.balanceOf(msg.sender);
        console.log("bUSDC balance before:", bUSDCBefore);

        console.log("minting 1000 bUSDC shares by supplying 1000 USDC...");
        uint err = bUSDC.mint(SUPPLY_AMOUNT);
        require(err == 0, "bUSDC.mint failed");

        // 4. Report
        uint256 bUSDCAfter = bUSDC.balanceOf(msg.sender);
        uint256 usdcAfter  = usdc.balanceOf(msg.sender);
        console.log("bUSDC balance after :", bUSDCAfter);
        console.log("bUSDC minted        :", bUSDCAfter - bUSDCBefore);
        console.log("USDC balance after  :", usdcAfter);

        vm.stopBroadcast();
        console.log("\n=== Supply Done ===");
    }
}
