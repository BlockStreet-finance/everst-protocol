// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import {Script, console} from "forge-std/Script.sol";
import "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

/**
 * @title RefreshMockPrice - Push fresh price to MockPyth
 *
 * Usage:
 *   forge script script/RefreshMockPrice.s.sol:RefreshMockPriceScript \
 *       --rpc-url https://sepolia.base.org \
 *       --account blockstreet-everst \
 *       --sender 0x62bdd47787ff9ac1eb0f62ba800db821ed0323e1 \
 *       --broadcast -vvvv
 */
contract RefreshMockPriceScript is Script {
    MockPyth constant mockPyth = MockPyth(0x9c2c94E1a47EFdF1Ce35DFb0b3768D45C3CfF83E);
    bytes32 constant COIN_USD_PRICE_ID = 0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245;

    function run() external {
        vm.startBroadcast();

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = mockPyth.createPriceFeedUpdateData(
            COIN_USD_PRICE_ID,
            int64(25_000_000_000),   // $250
            uint64(50_000_000),      // conf
            int32(-8),               // expo
            int64(25_000_000_000),   // emaPrice
            uint64(50_000_000),      // emaConf
            uint64(block.timestamp), // publishTime = now
            uint64(block.timestamp - 1)
        );
        mockPyth.updatePriceFeeds{value: 1}(updateData);

        console.log("Price refreshed at timestamp:", block.timestamp);
        vm.stopBroadcast();
    }
}
