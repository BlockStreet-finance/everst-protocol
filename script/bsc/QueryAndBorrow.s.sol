// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import {Script, console} from "forge-std/Script.sol";
import "../../src/BErc20Delegator.sol";
import "../../src/MockERC20.sol";
import "../../src/Blotroller.sol";
import "../../src/PriceOracle.sol";
import "../../src/BToken.sol";

/**
 * @title QueryAndBorrow - Log full account state, enter markets, borrow 9.9 USDC
 *
 * Usage:
 *   forge script script/bsc/QueryAndBorrow.s.sol:QueryAndBorrowScript \
 *       --rpc-url https://data-seed-prebsc-1-s1.binance.org:8545/ \
 *       --account iost \
 *       --sender 0x8901d084cAFeaD3FCFd223961ec479181057df68 \
 *       --broadcast --legacy -vvv
 */
contract QueryAndBorrowScript is Script {
    // BSC Testnet addresses
    MockERC20       constant usdc        = MockERC20(0xE28a51a5b83B7C9188416214E8D2AEf6A8A27458);
    MockERC20       constant wtcoin      = MockERC20(0x225037E610BfC00249dfcda2010d4B1A469E2e47);
    BErc20Delegator constant bUSDC       = BErc20Delegator(payable(0x3A6c3b866760622090975A7688e0Baf412109389));
    BErc20Delegator constant bwtCOIN     = BErc20Delegator(payable(0x9cECBb106E899A5F6Aa3e97d8E5061cf4eA5A35C));
    Blotroller      constant comptroller = Blotroller(payable(0x78f52868F6a8Ff5fb286982F6c9a75529835e93A));

    uint256 constant BORROW_AMOUNT = 9.9 ether; // 9.9 USDC (18-decimal mock)

    function run() external {
        require(block.chainid == 97, "BSC Testnet only");
        vm.startBroadcast();

        console.log("=== Account Status (before) ===");
        _status();

        // 1. Make sure bUSDC is entered as collateral
        if (!comptroller.checkMembership(msg.sender, BToken(address(bUSDC)))) {
            console.log("\nentering bUSDC market as collateral...");
            address[] memory m = new address[](1);
            m[0] = address(bUSDC);
            uint[] memory errs = comptroller.enterMarkets(m);
            require(errs[0] == 0, "enterMarkets failed");
        } else {
            console.log("\nbUSDC already entered as collateral");
        }

        // 2. Borrow 9.9 USDC
        console.log("\n--- Borrow 9.9 USDC ---");
        uint err = bUSDC.borrow(BORROW_AMOUNT);
        require(err == 0, "bUSDC.borrow failed");

        console.log("\n=== Account Status (after) ===");
        _status();

        vm.stopBroadcast();
    }

    function _status() internal {
        address who = msg.sender;
        console.log("account:             ", who);
        console.log("USDC  balance:       ", usdc.balanceOf(who));
        console.log("wtCOIN balance:      ", wtcoin.balanceOf(who));
        console.log("bUSDC   balance:     ", bUSDC.balanceOf(who));
        console.log("bwtCOIN balance:     ", bwtCOIN.balanceOf(who));

        uint256 supplyUsdc   = bUSDC.balanceOfUnderlying(who);
        uint256 supplyCoin   = bwtCOIN.balanceOfUnderlying(who);
        uint256 borrowUsdc   = bUSDC.borrowBalanceCurrent(who);
        uint256 borrowCoin   = bwtCOIN.borrowBalanceCurrent(who);
        console.log("supply USDC (under): ", supplyUsdc);
        console.log("supply wtCOIN(under):", supplyCoin);
        console.log("borrow USDC:         ", borrowUsdc);
        console.log("borrow wtCOIN:       ", borrowCoin);

        (uint e, uint liquidity, uint shortfall) = comptroller.getAccountLiquidity(who);
        console.log("liquidity err:       ", e);
        console.log("liquidity ($, 1e18): ", liquidity);
        console.log("shortfall ($, 1e18): ", shortfall);

        bool inUsdc = comptroller.checkMembership(who, BToken(address(bUSDC)));
        bool inCoin = comptroller.checkMembership(who, BToken(address(bwtCOIN)));
        console.log("bUSDC   in market:   ", inUsdc);
        console.log("bwtCOIN in market:   ", inCoin);
    }
}
