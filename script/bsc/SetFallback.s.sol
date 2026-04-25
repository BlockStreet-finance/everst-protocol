// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import {Script, console} from "forge-std/Script.sol";
import "../../src/BlockStreetPriceOracle.sol";

/**
 * @title SetFallback - Configure admin fallback prices on BSC Testnet
 * @notice Sets maxFallbackAge=0 (never expires) and writes fallback prices for
 *         bUSDC + bwtCOIN. After this, the oracle keeps serving even if the
 *         Pyth feed goes stale (useful for long-running test sessions).
 *
 *         Internal price scale is 6 decimals, so:
 *           USDC = $1.00   -> 1_000_000
 *           COIN = $250.00 -> 250_000_000
 *
 * Usage:
 *   forge script script/bsc/SetFallback.s.sol:SetFallbackScript \
 *       --rpc-url https://data-seed-prebsc-1-s1.binance.org:8545/ \
 *       --account iost \
 *       --sender 0x8901d084cAFeaD3FCFd223961ec479181057df68 \
 *       --broadcast --legacy -vvv
 */
contract SetFallbackScript is Script {
    BlockStreetPriceOracle constant oracle =
        BlockStreetPriceOracle(0xa672F7D3b068734e2E159bE3a7B208935186c443);

    address constant bUSDC   = 0x3A6c3b866760622090975A7688e0Baf412109389;
    address constant bwtCOIN = 0x9cECBb106E899A5F6Aa3e97d8E5061cf4eA5A35C;

    // 6-decimal internal scale
    uint128 constant USDC_FB = 1_000_000;     // $1.00
    uint128 constant COIN_FB = 250_000_000;   // $250.00

    function run() external {
        require(block.chainid == 97, "BSC Testnet only");
        vm.startBroadcast();

        console.log("=== Configuring fallback prices ===");
        console.log("oracle:", address(oracle));
        console.log("owner:", oracle.owner());

        // 1. Disable age check so fallback never expires.
        console.log("\nsetMaxFallbackAge(0)...");
        oracle.setMaxFallbackAge(0);

        // 2. Seed fallback prices.
        console.log("setFallbackPrice(bUSDC, $1.00)...");
        oracle.setFallbackPrice(bUSDC, USDC_FB);

        console.log("setFallbackPrice(bwtCOIN, $250.00)...");
        oracle.setFallbackPrice(bwtCOIN, COIN_FB);

        // 3. Read back to confirm
        console.log("\n=== Read-back ===");
        console.log("maxFallbackAge:", oracle.maxFallbackAge());

        (uint128 usdcPx, uint64 usdcTs) = oracle.fallbackPrices(bUSDC);
        (uint128 coinPx, uint64 coinTs) = oracle.fallbackPrices(bwtCOIN);
        console.log("bUSDC   fallback: price=", usdcPx, "ts=", usdcTs);
        console.log("bwtCOIN fallback: price=", coinPx, "ts=", coinTs);

        // 4. Sanity: actual getUnderlyingPrice via fallback path
        //    (will use Pyth if fresh, else fallback)
        console.log("\nscaled price bUSDC  :", oracle.getUnderlyingPrice(BToken(bUSDC)));
        console.log("scaled price bwtCOIN:", oracle.getUnderlyingPrice(BToken(bwtCOIN)));

        vm.stopBroadcast();
    }
}
