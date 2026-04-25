// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "../src/BlockStreetPriceOracle.sol";
import "../src/BToken.sol";
import "./mocks/MockPyth.sol";
import {Math as OZMath} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @dev Minimal mock BToken for BlockStreetPriceOracle tests.
 */
contract BSPOMockBToken is BToken {
    constructor() BToken() {}

    function getCashPrior() internal view virtual override returns (uint256) {
        return 0;
    }

    function doTransferIn(address from, uint256 amount) internal virtual override returns (uint256) {
        if (from == address(0) || amount == 0) return 0;
        return amount;
    }

    function doTransferOut(address payable to, uint256 amount) internal virtual override {
        if (to == address(0) || amount == 0) return;
    }
}

/**
 * @title Test Suite for BlockStreetPriceOracle
 * @author BlockStreet
 */
contract BlockStreetPriceOracleTest is Test {
    // --- Test environment ---
    uint256 internal constant TS = 1_672_531_200;
    uint256 internal constant BLOCK_NUM = 1_000_000;

    BlockStreetPriceOracle internal oracle;
    MockPyth internal mockPyth;

    address internal owner = address(0x1);
    address internal user  = address(0x2);

    // --- wtCOIN market (18 decimals) ---
    BSPOMockBToken internal constant WTCOIN_BT = BSPOMockBToken(payable(address(0xC01A)));
    address internal constant WTCOIN_UNDERLYING = 0x1111111111111111111111111111111111111111;
    bytes32 internal constant WTCOIN_PYTH_ID = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;

    // --- USDT market (6 decimals) ---
    BSPOMockBToken internal constant USDT_BT = BSPOMockBToken(payable(address(0xDEAD)));
    address internal constant USDT_UNDERLYING = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    bytes32 internal constant USDT_PYTH_ID = 0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;

    uint32 internal constant MAX_PRICE_AGE = 3600;
    uint32 internal constant MAX_FALLBACK_AGE = 14400; // 4 hours

    function setUp() public {
        vm.warp(TS);
        vm.roll(BLOCK_NUM);
        vm.startPrank(owner);
        mockPyth = new MockPyth();
        oracle = new BlockStreetPriceOracle(IPyth(address(mockPyth)), MAX_FALLBACK_AGE);
        vm.stopPrank();
    }

    // ============================================================
    // Section: Asset Configuration
    // ============================================================

    function test_OwnerCanSetAssetConfigs() public {
        _setupBothMarkets();

        (address u,,,, uint16 conf) = oracle.assetConfigs(address(WTCOIN_BT));
        assertEq(u, WTCOIN_UNDERLYING);
        assertEq(conf, 200);

        (address u2,,,,) = oracle.assetConfigs(address(USDT_BT));
        assertEq(u2, USDT_UNDERLYING);
    }

    function test_Fail_NonOwnerCannotSetConfig() public {
        vm.startPrank(user);
        address[] memory t = new address[](1);
        t[0] = address(WTCOIN_BT);
        BlockStreetPriceOracle.AssetConfig[] memory c = new BlockStreetPriceOracle.AssetConfig[](1);
        c[0] = _wtcoinConfig();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        oracle.setAssetConfigs(t, c);
        vm.stopPrank();
    }

    function test_Fail_InvalidConfig_ZeroBaseUnit() public {
        vm.startPrank(owner);
        address[] memory t = new address[](1);
        t[0] = address(WTCOIN_BT);
        BlockStreetPriceOracle.AssetConfig[] memory c = new BlockStreetPriceOracle.AssetConfig[](1);
        c[0] = _wtcoinConfig();
        c[0].baseUnit = 0;

        vm.expectRevert(BlockStreetPriceOracle.OracleInvalidConfiguration.selector);
        oracle.setAssetConfigs(t, c);
        vm.stopPrank();
    }

    function test_Fail_InvalidConfig_ZeroPriceAge() public {
        vm.startPrank(owner);
        address[] memory t = new address[](1);
        t[0] = address(WTCOIN_BT);
        BlockStreetPriceOracle.AssetConfig[] memory c = new BlockStreetPriceOracle.AssetConfig[](1);
        c[0] = _wtcoinConfig();
        c[0].maxPriceAge = 0;

        vm.expectRevert(BlockStreetPriceOracle.OracleInvalidConfiguration.selector);
        oracle.setAssetConfigs(t, c);
        vm.stopPrank();
    }

    function test_Fail_InvalidConfig_ExcessiveConfRatio() public {
        vm.startPrank(owner);
        address[] memory t = new address[](1);
        t[0] = address(WTCOIN_BT);
        BlockStreetPriceOracle.AssetConfig[] memory c = new BlockStreetPriceOracle.AssetConfig[](1);
        c[0] = _wtcoinConfig();
        c[0].maxConfidenceRatio = 10001;

        vm.expectRevert(BlockStreetPriceOracle.OracleInvalidConfiguration.selector);
        oracle.setAssetConfigs(t, c);
        vm.stopPrank();
    }

    function test_Fail_InvalidConfig_LengthMismatch() public {
        vm.startPrank(owner);
        address[] memory t = new address[](2);
        t[0] = address(WTCOIN_BT);
        t[1] = address(USDT_BT);
        BlockStreetPriceOracle.AssetConfig[] memory c = new BlockStreetPriceOracle.AssetConfig[](1);
        c[0] = _wtcoinConfig();

        vm.expectRevert(BlockStreetPriceOracle.OracleInvalidConfiguration.selector);
        oracle.setAssetConfigs(t, c);
        vm.stopPrank();
    }

    // ============================================================
    // Section: Normal Price Reading
    // ============================================================

    function test_NormalPrice_wtCOIN() public {
        _setupWtcoinMarket();
        mockPyth.setPrice(WTCOIN_PYTH_ID, 5_500_000, -6);

        uint256 price = oracle.getUnderlyingPrice(WTCOIN_BT);
        uint256 expected = OZMath.mulDiv(5_500_000, 1e30, 1e18);
        assertEq(price, expected);
    }

    function test_NormalPrice_USDT() public {
        _setupUsdtMarket();
        mockPyth.setPrice(USDT_PYTH_ID, 1_000_000, -6);

        uint256 price = oracle.getUnderlyingPrice(USDT_BT);
        uint256 expected = OZMath.mulDiv(1_000_000, 1e30, 1e6);
        assertEq(price, expected, "USDT should equal 1e30");
    }

    function test_Fail_MarketNotConfigured() public {
        vm.expectRevert(abi.encodeWithSelector(
            BlockStreetPriceOracle.OracleMarketNotConfigured.selector, address(WTCOIN_BT)
        ));
        oracle.getUnderlyingPrice(WTCOIN_BT);
    }

    function test_Fail_StalePythPrice_NoFallback() public {
        _setupWtcoinMarket();
        mockPyth.setPrice(WTCOIN_PYTH_ID, 5_500_000, -6);
        vm.warp(TS + MAX_PRICE_AGE + 1);

        vm.expectRevert(abi.encodeWithSelector(
            BlockStreetPriceOracle.OraclePriceNotFound.selector, address(WTCOIN_BT)
        ));
        oracle.getUnderlyingPrice(WTCOIN_BT);
    }

    function test_Fail_HighConfidence_NoFallback() public {
        _setupWtcoinMarket(); // maxConfidenceRatio = 200 (2%)
        // $100 ± $5 → 5% confidence, exceeds 2%
        mockPyth.setPriceWithConfidence(WTCOIN_PYTH_ID, 100_000_000, 5_000_000, -6);

        vm.expectRevert(abi.encodeWithSelector(
            BlockStreetPriceOracle.OraclePriceNotFound.selector, address(WTCOIN_BT)
        ));
        oracle.getUnderlyingPrice(WTCOIN_BT);
    }

    // ============================================================
    // Section: Admin Fallback Price
    // ============================================================

    function test_Fallback_UsedWhenPythFails() public {
        _setupWtcoinMarket();
        mockPyth.setPrice(WTCOIN_PYTH_ID, 100_000_000, -6);
        vm.warp(TS + MAX_PRICE_AGE + 1);

        vm.prank(owner);
        oracle.setFallbackPrice(address(WTCOIN_BT), 99_000_000);

        uint256 price = oracle.getUnderlyingPrice(WTCOIN_BT);
        uint256 expected = OZMath.mulDiv(99_000_000, 1e30, 1e18);
        assertEq(price, expected, "Should use fallback");
    }

    function test_Fallback_ExpiredReverts() public {
        _setupWtcoinMarket();

        vm.prank(owner);
        oracle.setFallbackPrice(address(WTCOIN_BT), 99_000_000);

        vm.warp(TS + MAX_FALLBACK_AGE + 1);

        vm.expectRevert(abi.encodeWithSelector(
            BlockStreetPriceOracle.OraclePriceNotFound.selector, address(WTCOIN_BT)
        ));
        oracle.getUnderlyingPrice(WTCOIN_BT);
    }

    function test_Fallback_ClearRemovesIt() public {
        _setupWtcoinMarket();
        mockPyth.setPrice(WTCOIN_PYTH_ID, 100_000_000, -6);
        vm.warp(TS + MAX_PRICE_AGE + 1);

        vm.startPrank(owner);
        oracle.setFallbackPrice(address(WTCOIN_BT), 99_000_000);
        oracle.clearFallbackPrice(address(WTCOIN_BT));
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(
            BlockStreetPriceOracle.OraclePriceNotFound.selector, address(WTCOIN_BT)
        ));
        oracle.getUnderlyingPrice(WTCOIN_BT);
    }

    function test_Fail_NonOwnerCannotSetFallback() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        oracle.setFallbackPrice(address(WTCOIN_BT), 99_000_000);
    }

    function test_Fail_SetFallbackZeroPrice() public {
        vm.prank(owner);
        vm.expectRevert(BlockStreetPriceOracle.OracleInvalidConfiguration.selector);
        oracle.setFallbackPrice(address(WTCOIN_BT), 0);
    }

    function test_Fallback_MaxAgeZeroNeverExpires() public {
        _setupWtcoinMarket();
        mockPyth.setPrice(WTCOIN_PYTH_ID, 100_000_000, -6);

        vm.startPrank(owner);
        oracle.setMaxFallbackAge(0);
        oracle.setFallbackPrice(address(WTCOIN_BT), 99_000_000);
        vm.stopPrank();

        vm.warp(TS + 999_999);

        uint256 price = oracle.getUnderlyingPrice(WTCOIN_BT);
        uint256 expected = OZMath.mulDiv(99_000_000, 1e30, 1e18);
        assertEq(price, expected, "Fallback with maxFallbackAge=0 should never expire");
    }

    // ============================================================
    // Section: Per-Asset Pause
    // ============================================================

    function test_Pause_RevertsOnPausedAsset() public {
        _setupWtcoinMarket();
        mockPyth.setPrice(WTCOIN_PYTH_ID, 100_000_000, -6);

        vm.prank(owner);
        oracle.pauseAsset(address(WTCOIN_BT));

        vm.expectRevert(abi.encodeWithSelector(
            BlockStreetPriceOracle.OracleAssetPaused.selector, address(WTCOIN_BT)
        ));
        oracle.getUnderlyingPrice(WTCOIN_BT);
    }

    function test_Pause_UnpauseRestoresAccess() public {
        _setupWtcoinMarket();
        mockPyth.setPrice(WTCOIN_PYTH_ID, 100_000_000, -6);

        vm.startPrank(owner);
        oracle.pauseAsset(address(WTCOIN_BT));
        oracle.unpauseAsset(address(WTCOIN_BT));
        vm.stopPrank();

        uint256 price = oracle.getUnderlyingPrice(WTCOIN_BT);
        assertGt(price, 0, "Should work after unpause");
    }

    function test_Pause_DoesNotAffectOtherAssets() public {
        _setupBothMarkets();
        mockPyth.setPrice(WTCOIN_PYTH_ID, 100_000_000, -6);
        mockPyth.setPrice(USDT_PYTH_ID, 1_000_000, -6);

        vm.prank(owner);
        oracle.pauseAsset(address(WTCOIN_BT));

        uint256 usdtPrice = oracle.getUnderlyingPrice(USDT_BT);
        assertGt(usdtPrice, 0, "USDT should not be affected by WTCOIN pause");

        vm.expectRevert(abi.encodeWithSelector(
            BlockStreetPriceOracle.OracleAssetPaused.selector, address(WTCOIN_BT)
        ));
        oracle.getUnderlyingPrice(WTCOIN_BT);
    }

    function test_Fail_NonOwnerCannotPause() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        oracle.pauseAsset(address(WTCOIN_BT));
    }

    // ============================================================
    // Section: Fuzz Tests
    // ============================================================

    function testFuzz_PriceScaling(uint64 rawPrice) public {
        vm.assume(rawPrice > 0 && rawPrice <= uint64(type(int64).max));

        // Use maxConfidenceRatio = 10000 (100%) so tiny prices don't trip conf check
        vm.startPrank(owner);
        address[] memory t = new address[](1);
        t[0] = address(WTCOIN_BT);
        BlockStreetPriceOracle.AssetConfig[] memory c = new BlockStreetPriceOracle.AssetConfig[](1);
        c[0] = BlockStreetPriceOracle.AssetConfig({
            underlying: WTCOIN_UNDERLYING,
            baseUnit: 1e18,
            pythPriceId: WTCOIN_PYTH_ID,
            maxPriceAge: MAX_PRICE_AGE,
            maxConfidenceRatio: 10000
        });
        oracle.setAssetConfigs(t, c);
        vm.stopPrank();

        mockPyth.setPrice(WTCOIN_PYTH_ID, int64(rawPrice), -6);

        uint256 price = oracle.getUnderlyingPrice(WTCOIN_BT);
        uint256 expected = OZMath.mulDiv(uint256(rawPrice), 1e30, 1e18);
        assertEq(price, expected);
    }

    // ============================================================
    // Section: Event Emission Tests
    // ============================================================

    function test_Events_AssetConfigUpdated() public {
        vm.startPrank(owner);
        address[] memory t = new address[](1);
        t[0] = address(WTCOIN_BT);
        BlockStreetPriceOracle.AssetConfig[] memory c = new BlockStreetPriceOracle.AssetConfig[](1);
        c[0] = _wtcoinConfig();

        vm.expectEmit(true, false, false, false);
        emit BlockStreetPriceOracle.AssetConfigUpdated(address(WTCOIN_BT), c[0]);
        oracle.setAssetConfigs(t, c);
        vm.stopPrank();
    }

    function test_Events_FallbackPriceSet() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit BlockStreetPriceOracle.FallbackPriceSet(address(WTCOIN_BT), 99_000_000);
        oracle.setFallbackPrice(address(WTCOIN_BT), 99_000_000);
    }

    function test_Events_AssetPaused() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit BlockStreetPriceOracle.AssetPaused(address(WTCOIN_BT));
        oracle.pauseAsset(address(WTCOIN_BT));
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _wtcoinConfig() internal pure returns (BlockStreetPriceOracle.AssetConfig memory) {
        return BlockStreetPriceOracle.AssetConfig({
            underlying: WTCOIN_UNDERLYING,
            baseUnit: 1e18,
            pythPriceId: WTCOIN_PYTH_ID,
            maxPriceAge: MAX_PRICE_AGE,
            maxConfidenceRatio: 200    // 2%
        });
    }

    function _usdtConfig() internal pure returns (BlockStreetPriceOracle.AssetConfig memory) {
        return BlockStreetPriceOracle.AssetConfig({
            underlying: USDT_UNDERLYING,
            baseUnit: 1e6,
            pythPriceId: USDT_PYTH_ID,
            maxPriceAge: MAX_PRICE_AGE,
            maxConfidenceRatio: 50     // 0.5%
        });
    }

    function _setupWtcoinMarket() internal {
        vm.startPrank(owner);
        address[] memory t = new address[](1);
        t[0] = address(WTCOIN_BT);
        BlockStreetPriceOracle.AssetConfig[] memory c = new BlockStreetPriceOracle.AssetConfig[](1);
        c[0] = _wtcoinConfig();
        oracle.setAssetConfigs(t, c);
        vm.stopPrank();
    }

    function _setupUsdtMarket() internal {
        vm.startPrank(owner);
        address[] memory t = new address[](1);
        t[0] = address(USDT_BT);
        BlockStreetPriceOracle.AssetConfig[] memory c = new BlockStreetPriceOracle.AssetConfig[](1);
        c[0] = _usdtConfig();
        oracle.setAssetConfigs(t, c);
        vm.stopPrank();
    }

    function _setupBothMarkets() internal {
        vm.startPrank(owner);
        address[] memory t = new address[](2);
        t[0] = address(WTCOIN_BT);
        t[1] = address(USDT_BT);
        BlockStreetPriceOracle.AssetConfig[] memory c = new BlockStreetPriceOracle.AssetConfig[](2);
        c[0] = _wtcoinConfig();
        c[1] = _usdtConfig();
        oracle.setAssetConfigs(t, c);
        vm.stopPrank();
    }
}
