// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import {Script, console} from "forge-std/Script.sol";
import "../../src/BErc20Delegator.sol";
import "../../src/MockERC20.sol";
import "../../src/Blotroller.sol";
import "../../src/BToken.sol";

/**
 * @title RepayAll - Full USDC repay on BSC Testnet
 *
 * Usage:
 *   forge script script/bsc/RepayAll.s.sol:RepayAllScript \
 *       --rpc-url https://data-seed-prebsc-1-s1.binance.org:8545/ \
 *       --account iost \
 *       --sender 0x8901d084cAFeaD3FCFd223961ec479181057df68 \
 *       --broadcast --legacy -vvv
 */
contract RepayAllScript is Script {
    MockERC20       constant usdc        = MockERC20(0xE28a51a5b83B7C9188416214E8D2AEf6A8A27458);
    BErc20Delegator constant bUSDC       = BErc20Delegator(payable(0x3A6c3b866760622090975A7688e0Baf412109389));
    Blotroller      constant comptroller = Blotroller(payable(0x78f52868F6a8Ff5fb286982F6c9a75529835e93A));

    function run() external {
        require(block.chainid == 97, "BSC Testnet only");
        vm.startBroadcast();

        address me = msg.sender;

        console.log("=== Before Repay ===");
        uint256 debtBefore   = bUSDC.borrowBalanceCurrent(me);
        uint256 walletBefore = usdc.balanceOf(me);
        uint256 allowance    = usdc.allowance(me, address(bUSDC));
        console.log("debt (current):      ", debtBefore);
        console.log("USDC wallet:         ", walletBefore);
        console.log("USDC allowance->bUSDC:", allowance);

        require(debtBefore > 0, "no debt to repay");
        require(walletBefore >= debtBefore, "wallet < debt");

        // Approve max (safe)
        if (allowance < type(uint128).max) {
            console.log("\napproving bUSDC for max...");
            usdc.approve(address(bUSDC), type(uint256).max);
        }

        // Full repay
        console.log("\ncalling bUSDC.repayBorrow(type(uint256).max)...");
        uint err = bUSDC.repayBorrow(type(uint256).max);
        require(err == 0, "repayBorrow failed");

        console.log("\n=== After Repay ===");
        uint256 debtAfter   = bUSDC.borrowBalanceCurrent(me);
        uint256 walletAfter = usdc.balanceOf(me);
        console.log("debt (current):      ", debtAfter);
        console.log("USDC wallet:         ", walletAfter);
        console.log("paid (wallet delta): ", walletBefore - walletAfter);

        (uint e, uint liq, uint sf) = comptroller.getAccountLiquidity(me);
        console.log("\nliquidity err:       ", e);
        console.log("liquidity ($, 1e18): ", liq);
        console.log("shortfall ($, 1e18): ", sf);

        vm.stopBroadcast();
    }
}
