// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import {Script, console} from "forge-std/Script.sol";
import "../src/BErc20Delegator.sol";
import "../src/Blotroller.sol";
import "../src/MockERC20.sol";

/**
 * @title TestSupplyBorrow - E2E test: supply -> enterMarket -> borrow -> repay -> redeem
 *
 * Usage:
 *   forge script script/TestSupplyBorrow.s.sol:TestSupplyBorrowScript \
 *       --rpc-url https://sepolia.base.org \
 *       --account blockstreet-everst \
 *       --sender 0x62bdd47787ff9ac1eb0f62ba800db821ed0323e1 \
 *       --broadcast -vvvv
 */
contract TestSupplyBorrowScript is Script {

    MockERC20 constant wtcoin = MockERC20(0x0e666458927C2f0a5f1b4bD9bA648976755b840c);
    BErc20Delegator constant bwtcoin = BErc20Delegator(payable(0x7706fD8245E400c71109B23a286272608bB5afa4));
    Blotroller constant comptroller = Blotroller(payable(0x97FCa6ad362bC5de29a4Dc39CE305812e762F4cB));

    function run() external {
        require(block.chainid == 84532, "Base Sepolia only");
        vm.startBroadcast();

        console.log("=== Supply/Borrow E2E Test ===");

        // Mint test tokens if needed
        if (wtcoin.balanceOf(msg.sender) < 100 ether) {
            wtcoin.mint(msg.sender, 200 ether);
        }
        console.log("wtCOIN balance:", wtcoin.balanceOf(msg.sender));

        // Step 1: Approve + Supply
        wtcoin.approve(address(bwtcoin), type(uint256).max);
        console.log("supply 100 wtCOIN...");
        console.log("  mint result:", bwtcoin.mint(100 ether));
        console.log("  bwtCOIN balance:", bwtcoin.balanceOf(msg.sender));

        // Step 2: Enter market
        _enterMarket();

        // Step 3: Check liquidity
        _logLiquidity("after supply");

        // Step 4: Borrow 10 wtCOIN
        console.log("borrow 10 wtCOIN...");
        console.log("  borrow result:", bwtcoin.borrow(10 ether));
        console.log("  wtCOIN balance:", wtcoin.balanceOf(msg.sender));
        _logLiquidity("after borrow");

        // Step 5: Repay FULL outstanding debt (principal + accrued interest)
        //   Pass type(uint256).max so BToken auto-fills current borrowBalance.
        //   approve() already set to max, wallet balance >> debt.
        uint256 debtBefore = bwtcoin.borrowBalanceCurrent(msg.sender);
        console.log("debt (with interest) before repay:", debtBefore);
        console.log("wallet wtCOIN before repay:       ", wtcoin.balanceOf(msg.sender));
        console.log("allowance bwtCOIN:                ", wtcoin.allowance(msg.sender, address(bwtcoin)));

        console.log("repay ALL (type(uint256).max)...");
        console.log("  repay result:", bwtcoin.repayBorrow(type(uint256).max));
        console.log("  debt after repay:", bwtcoin.borrowBalanceCurrent(msg.sender));

        // Step 6: Redeem all
        console.log("redeem all bwtCOIN...");
        console.log("  redeem result:", bwtcoin.redeem(bwtcoin.balanceOf(msg.sender)));
        console.log("  final wtCOIN:", wtcoin.balanceOf(msg.sender));
        console.log("  final bwtCOIN:", bwtcoin.balanceOf(msg.sender));

        vm.stopBroadcast();
        console.log("\n=== All Steps Passed ===");
    }

    function _enterMarket() internal {
        address[] memory m = new address[](1);
        m[0] = address(bwtcoin);
        uint256[] memory errs = comptroller.enterMarkets(m);
        console.log("enterMarkets result:", errs[0]);
    }

    function _logLiquidity(string memory label) internal view {
        (uint e, uint l, uint s) = comptroller.getAccountLiquidity(msg.sender);
        console.log(label);
        console.log("  err:", e, "liquidity:", l);
        console.log("  shortfall:", s);
    }
}
