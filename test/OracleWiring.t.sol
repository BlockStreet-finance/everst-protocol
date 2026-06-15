// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "../src/Blotroller.sol";
import "../src/Unitroller.sol";
import "../src/PriceOracle.sol";
import "../src/BlockStreetPriceOracle.sol";
import "../src/BToken.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

/**
 * @title Oracle wiring — BlockStreetPriceOracle plugged into the Blotroller
 * @dev Mirrors script/DeployAndConfigureOracle: deploy -> _setPriceOracle -> setAssetConfig,
 *      then confirm the Blotroller reads prices through the new oracle.
 */
contract OracleWiringTest is Test {
    Unitroller internal unitroller;
    Blotroller internal blotroller;
    MockPyth internal pyth;
    BlockStreetPriceOracle internal oracle;

    address internal constant BWTCOIN = address(0xC01);

    bytes32 constant COIN_REG = 0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245;
    bytes32 constant COIN_ON  = 0x42ded7a3ed036606ab22ece1c942f6f9245a67f6f4ec27cfad5974d45fe9d6b6;
    bytes32 constant COINX    = 0x641435d5dffb5311140b480517c79986d8488d5cf08a11eec53b83ad02cab33f;

    function setUp() public {
        vm.warp(1_000_000); // move off genesis so publishTime - N doesn't underflow

        // Blotroller behind Unitroller proxy (admin = this test).
        Blotroller impl = new Blotroller();
        unitroller = new Unitroller();
        unitroller._setPendingImplementation(address(impl));
        impl._become(unitroller);
        blotroller = Blotroller(payable(address(unitroller)));

        pyth = new MockPyth();
        oracle = new BlockStreetPriceOracle(IPyth(address(pyth)));

        // The wiring steps the deploy script performs:
        uint256 rc = blotroller._setPriceOracle(PriceOracle(address(oracle)));
        assertEq(rc, 0, "setPriceOracle should succeed");

        bytes32[] memory eq = new bytes32[](2);
        eq[0] = COIN_REG; eq[1] = COIN_ON;
        oracle.setAssetConfig(BWTCOIN, BlockStreetPriceOracle.AssetConfig({
            baseUnit: 1e18,
            equityFeeds: eq,
            proxyFeed: COINX,
            rrFeed: bytes32(0),     // RR gate off for this wiring test
            maxPriceAge: 300,
            maxConfBps: 50,
            rrLowerMantissa: 0,
            rrUpperMantissa: 0
        }));
    }

    function test_BlotrollerUsesNewOracle() public {
        assertEq(address(blotroller.oracle()), address(oracle), "Blotroller points at new oracle");
    }

    function test_PriceReadThroughBlotrollerOracle() public {
        // Live regular feed -> Blotroller's oracle returns the scaled equity price.
        pyth.setPriceFull(COIN_REG, int64(15_973_000), 1000, -5, uint64(block.timestamp));
        uint256 p = blotroller.oracle().getUnderlyingPrice(BToken(BWTCOIN));
        assertEq(p, 159_73 * 1e16, "159.73 * 1e18"); // 18-dec underlying
    }

    function test_NoPriceReturnsZeroNotRevert() public {
        // No feed set at all -> oracle returns 0 (failsafe), the Blotroller path does not revert.
        uint256 p = blotroller.oracle().getUnderlyingPrice(BToken(BWTCOIN));
        assertEq(p, 0, "unpriced -> 0, never revert");
    }

    function test_FallsBackToProxyThroughBlotroller() public {
        // Equity stale, xStock fresh -> proxy price, flagged for liquidation guardrails.
        pyth.setPriceFull(COIN_REG, int64(15_973_000), 1000, -5, uint64(block.timestamp - 5000));
        pyth.setPriceFull(COINX, int64(16_795_000), 1000, -5, uint64(block.timestamp));
        uint256 p = blotroller.oracle().getUnderlyingPrice(BToken(BWTCOIN));
        assertEq(p, 167_95 * 1e16, "uses xStock proxy");
        assertTrue(oracle.isProxyPrice(BWTCOIN), "flagged as proxy");
    }
}
