// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import "../src/BlockStreetPriceOracle.sol";
import "../src/Blotroller.sol";
import "../src/PriceOracle.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";

/**
 * @title DeployAndConfigureOracle
 * @notice Deploys BlockStreetPriceOracle, wires it into the Blotroller, and configures
 *         per-market Pyth feeds (stock-risk-control-spec §3).
 *
 * Required env:
 *   PYTH_ADDRESS  — on-chain Pyth contract (Base mainnet: 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a)
 *   BLOTROLLER    — the Unitroller proxy address (must be callable by the broadcaster = admin)
 *   BWTCOIN       — bToken market for wtCOIN (Coinbase). Set to address(0) to skip.
 *
 * The broadcaster must be the Blotroller admin (for _setPriceOracle) and becomes the
 * oracle owner (for setAssetConfig). On a governance-controlled deployment, run the
 * deploy here and route _setPriceOracle / setAssetConfig through the timelock instead.
 *
 * Usage:
 *   forge script script/DeployAndConfigureOracle.s.sol --rpc-url <rpc> --broadcast
 */
contract DeployAndConfigureOracle is Script {
    // ---- COIN (Coinbase) feed ids — verified from Pyth Hermes 2026-06 ----
    bytes32 constant COIN_REG  = 0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245;
    bytes32 constant COIN_PRE  = 0x8bdee6bc9dc5a61b971e31dcfae96fc0c7eae37b2604aa6002ad22980bd3517c;
    bytes32 constant COIN_POST = 0x5c3bd92f2eed33779040caea9f82fac705f5121d26251f8f5e17ec35b9559cd4;
    bytes32 constant COIN_ON   = 0x42ded7a3ed036606ab22ece1c942f6f9245a67f6f4ec27cfad5974d45fe9d6b6;
    bytes32 constant COINX     = 0x641435d5dffb5311140b480517c79986d8488d5cf08a11eec53b83ad02cab33f;
    bytes32 constant COINX_RR  = 0xb663e208031820ed2ea373346501ceb897f230623439482f0e2a13150af08549;

    // ---- Default risk thresholds (tune with the pyth-monitor data) ----
    uint256 constant MAX_PRICE_AGE = 300;     // 5 min staleness window
    uint256 constant MAX_CONF_BPS  = 50;      // 0.5% conf/price ceiling
    uint256 constant RR_LOWER      = 0.98e18; // proxy accepted while RR in [0.98, 1.02]
    uint256 constant RR_UPPER      = 1.02e18;

    function run() external {
        address pyth = vm.envAddress("PYTH_ADDRESS");
        address blotroller = vm.envAddress("BLOTROLLER");
        address bWtCoin = vm.envOr("BWTCOIN", address(0));

        vm.startBroadcast();

        // 1. Deploy the oracle.
        BlockStreetPriceOracle oracle = new BlockStreetPriceOracle(IPyth(pyth));
        console.log("BlockStreetPriceOracle:", address(oracle));

        // 2. Wire it into the Blotroller (replaces the old oracle).
        uint256 rc = Blotroller(payable(blotroller))._setPriceOracle(PriceOracle(address(oracle)));
        require(rc == 0, "setPriceOracle failed");

        // 3. Configure markets.
        if (bWtCoin != address(0)) {
            // COIN has the full set: 4 session feeds + 24/7 xStock proxy + RR gate.
            oracle.setAssetConfig(
                bWtCoin,
                _config(
                    1e18,                                   // wtCOIN underlying = 18 decimals
                    _equity(COIN_REG, COIN_PRE, COIN_POST, COIN_ON),
                    COINX,
                    COINX_RR
                )
            );
            console.log("configured wtCOIN market:", bWtCoin);
        }

        // Add more markets the same way, e.g. a no-xStock stock (MSFT/ORCL):
        //   oracle.setAssetConfig(bMsft, _config(1e18, _equity(MSFT_REG, MSFT_PRE, MSFT_POST, MSFT_ON),
        //                                        bytes32(0), bytes32(0)));

        vm.stopBroadcast();
    }

    // ---- helpers ----

    function _equity(bytes32 reg, bytes32 pre, bytes32 post, bytes32 on)
        internal
        pure
        returns (bytes32[] memory feeds)
    {
        feeds = new bytes32[](4);
        feeds[0] = reg; feeds[1] = pre; feeds[2] = post; feeds[3] = on;
    }

    function _config(uint256 baseUnit, bytes32[] memory equityFeeds, bytes32 proxyFeed, bytes32 rrFeed)
        internal
        pure
        returns (BlockStreetPriceOracle.AssetConfig memory)
    {
        bool hasRr = rrFeed != bytes32(0);
        return BlockStreetPriceOracle.AssetConfig({
            baseUnit: baseUnit,
            equityFeeds: equityFeeds,
            proxyFeed: proxyFeed,
            rrFeed: rrFeed,
            maxPriceAge: MAX_PRICE_AGE,
            maxConfBps: MAX_CONF_BPS,
            rrLowerMantissa: hasRr ? RR_LOWER : 0,
            rrUpperMantissa: hasRr ? RR_UPPER : 0
        });
    }
}
