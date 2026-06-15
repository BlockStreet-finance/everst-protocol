// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "../src/BlockStreetPriceOracle.sol";
import "../src/BToken.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

/**
 * @title BlockStreetPriceOracle — session-aware three-tier price selection
 * @dev Verifies spec §3: freshest valid equity feed -> xStock proxy (RR-gated) -> 0 (no revert).
 */
contract BlockStreetPriceOracleTest is Test {
    MockPyth internal pyth;
    BlockStreetPriceOracle internal oracle;

    // Pretend bToken (oracle only uses the address as a config key).
    address internal constant BTOKEN = address(0xB10C);

    // COIN session feeds + xStock proxy + RR (arbitrary ids for the mock).
    bytes32 constant F_REG  = keccak256("Equity.US.COIN/USD");
    bytes32 constant F_PRE  = keccak256("Equity.US.COIN/USD.PRE");
    bytes32 constant F_POST = keccak256("Equity.US.COIN/USD.POST");
    bytes32 constant F_ON   = keccak256("Equity.US.COIN/USD.ON");
    bytes32 constant F_XSTK = keccak256("Crypto.COINX/USD");
    bytes32 constant F_RR   = keccak256("Crypto.COINX/COIN.RR");

    int32 constant EXPO = -5;            // COIN equity feeds use expo -5 on Pyth
    uint256 constant MAX_AGE = 60;       // 60s staleness window
    uint256 constant MAX_CONF_BPS = 50;  // 0.5%
    uint256 constant BASE_UNIT = 1e18;   // 18-decimal underlying

    uint64 constant NOW = 1_000_000;     // fixed wall clock for the tests

    function setUp() public {
        pyth = new MockPyth();
        oracle = new BlockStreetPriceOracle(IPyth(address(pyth)));
        vm.warp(NOW);
        _configureCoin(F_XSTK, F_RR); // full COIN config incl. proxy + RR gate
    }

    function _configureCoin(bytes32 proxyFeed, bytes32 rrFeed) internal {
        bytes32[] memory eq = new bytes32[](4);
        eq[0] = F_REG; eq[1] = F_PRE; eq[2] = F_POST; eq[3] = F_ON;
        oracle.setAssetConfig(
            BTOKEN,
            BlockStreetPriceOracle.AssetConfig({
                baseUnit: BASE_UNIT,
                equityFeeds: eq,
                proxyFeed: proxyFeed,
                rrFeed: rrFeed,
                maxPriceAge: MAX_AGE,
                maxConfBps: MAX_CONF_BPS,
                rrLowerMantissa: 0.98e18,
                rrUpperMantissa: 1.02e18
            })
        );
    }

    // price ($) -> Pyth int64 mantissa at EXPO (-5)
    function _m(uint256 dollars, uint256 cents) internal pure returns (int64) {
        return int64(uint64((dollars * 100 + cents) * 1000)); // *1e3 to reach 1e5 scale
    }

    // expected getUnderlyingPrice for an 18-dec underlying = price * 1e18
    function _expected(uint256 dollars, uint256 cents) internal pure returns (uint256) {
        return (dollars * 1e18) + (cents * 1e16);
    }

    // ---- Tier 1: freshest valid equity ----

    function test_Tier1_PicksLiveSessionFeed() public {
        // regular/pre/post stale, overnight fresh (the live session) -> use overnight.
        pyth.setPriceFull(F_REG,  _m(159, 73), 1000, EXPO, NOW - 5000);
        pyth.setPriceFull(F_PRE,  _m(160, 51), 1000, EXPO, NOW - 4000);
        pyth.setPriceFull(F_POST, _m(159, 92), 1000, EXPO, NOW - 3000);
        pyth.setPriceFull(F_ON,   _m(168, 28), 1000, EXPO, NOW - 2);

        (uint256 price, bool isProxy, BlockStreetPriceOracle.Tier tier) = oracle.getPriceDetails(BTOKEN);
        assertEq(price, _expected(168, 28), "should use the live overnight feed");
        assertFalse(isProxy, "tier-1 is not a proxy");
        assertEq(uint(tier), uint(BlockStreetPriceOracle.Tier.EQUITY));
        assertEq(oracle.getUnderlyingPrice(BToken(BTOKEN)), _expected(168, 28));
    }

    function test_Tier1_FreshestWinsAmongValid() public {
        // Two feeds fresh; the one with the newer publishTime wins.
        pyth.setPriceFull(F_REG, _m(159, 73), 1000, EXPO, NOW - 30);
        pyth.setPriceFull(F_ON,  _m(168, 28), 1000, EXPO, NOW - 3);
        assertEq(oracle.getUnderlyingPrice(BToken(BTOKEN)), _expected(168, 28), "newer publishTime wins");
    }

    function test_Tier1_ConfTooWideRejected() public {
        // Only regular present and fresh, but conf/price = ~6.3% > 0.5% -> invalid.
        // price 159.73 (=15,973,000 at expo-5), conf 1,000,000 -> ~6.26%.
        pyth.setPriceFull(F_REG, _m(159, 73), 1_000_000, EXPO, NOW - 2);
        // no proxy fresh -> no price
        pyth.clearPrice(F_XSTK);
        assertEq(oracle.getUnderlyingPrice(BToken(BTOKEN)), 0, "wide-conf feed must be rejected");
    }

    // ---- Tier 2: xStock proxy ----

    function test_Tier2_ProxyUsedWhenEquityDark() public {
        // All equity stale (weekend), xStock fresh, RR healthy -> proxy, flagged.
        pyth.setPriceFull(F_REG, _m(159, 73), 1000, EXPO, NOW - 5000);
        pyth.setPriceFull(F_XSTK, _m(167, 95), 1000, EXPO, NOW - 2);
        pyth.setPriceFull(F_RR, int64(1e8), 1, -8, NOW - 2); // RR = 1.0

        (uint256 price, bool isProxy, BlockStreetPriceOracle.Tier tier) = oracle.getPriceDetails(BTOKEN);
        assertEq(price, _expected(167, 95), "falls back to xStock proxy");
        assertTrue(isProxy, "proxy must be flagged for liquidation guardrails");
        assertEq(uint(tier), uint(BlockStreetPriceOracle.Tier.PROXY));
        assertTrue(oracle.isProxyPrice(BTOKEN));
    }

    function test_Tier2_ProxyRejectedWhenRrDepegged() public {
        pyth.setPriceFull(F_REG, _m(159, 73), 1000, EXPO, NOW - 5000); // equity dark
        pyth.setPriceFull(F_XSTK, _m(167, 95), 1000, EXPO, NOW - 2);    // proxy fresh
        pyth.setPriceFull(F_RR, int64(9e7), 1, -8, NOW - 2);            // RR = 0.90 -> depegged

        assertEq(oracle.getUnderlyingPrice(BToken(BTOKEN)), 0, "depegged proxy must be rejected -> no price");
    }

    function test_EquityPreferredOverProxy() public {
        // Both a live equity feed AND the proxy are fresh -> the real equity price wins.
        pyth.setPriceFull(F_ON, _m(168, 28), 1000, EXPO, NOW - 2);
        pyth.setPriceFull(F_XSTK, _m(167, 95), 1000, EXPO, NOW - 1);
        pyth.setPriceFull(F_RR, int64(1e8), 1, -8, NOW - 1);

        (, bool isProxy, BlockStreetPriceOracle.Tier tier) = oracle.getPriceDetails(BTOKEN);
        assertFalse(isProxy, "real equity feed preferred over proxy");
        assertEq(uint(tier), uint(BlockStreetPriceOracle.Tier.EQUITY));
        assertEq(oracle.getUnderlyingPrice(BToken(BTOKEN)), _expected(168, 28));
    }

    // ---- Tier 3: no price (never revert) ----

    function test_Tier3_NoProxyStock_WeekendIsUnpriced() public {
        // Reconfigure as a stock WITHOUT xStock (e.g. MSFT/ORCL): no fallback.
        _configureCoin(bytes32(0), bytes32(0));
        pyth.setPriceFull(F_REG, _m(397, 30), 1000, EXPO, NOW - 5000); // all equity stale
        assertEq(oracle.getUnderlyingPrice(BToken(BTOKEN)), 0, "no xStock -> weekend unpriced");
    }

    function test_Tier3_ReturnsZeroNotRevert_WhenUnconfigured() public {
        // A market with no config must return 0, never revert (failsafe / invariant #2).
        uint256 p = oracle.getUnderlyingPrice(BToken(address(0xDEAD)));
        assertEq(p, 0);
    }

    function test_Tier3_AllStaleWithProxyStale_NoPrice() public {
        pyth.setPriceFull(F_REG, _m(159, 73), 1000, EXPO, NOW - 5000);
        pyth.setPriceFull(F_XSTK, _m(167, 95), 1000, EXPO, NOW - 5000); // proxy also stale
        assertEq(oracle.getUnderlyingPrice(BToken(BTOKEN)), 0);
    }

    // ---- scaling ----

    function test_Scaling_SixDecimalUnderlying() public {
        // A 6-decimal underlying should scale to price * 1e30.
        bytes32[] memory eq = new bytes32[](1);
        eq[0] = F_REG;
        address sixDec = address(0x6D);
        oracle.setAssetConfig(sixDec, BlockStreetPriceOracle.AssetConfig({
            baseUnit: 1e6, equityFeeds: eq, proxyFeed: bytes32(0), rrFeed: bytes32(0),
            maxPriceAge: MAX_AGE, maxConfBps: 0, rrLowerMantissa: 0, rrUpperMantissa: 0
        }));
        pyth.setPriceFull(F_REG, _m(159, 73), 1, EXPO, NOW - 2);
        assertEq(oracle.getUnderlyingPrice(BToken(sixDec)), 15973 * 1e28, "159.73 * 1e30");
    }

    // ---- admin ----

    function test_Admin_OnlyOwnerCanConfigure() public {
        bytes32[] memory eq = new bytes32[](1); eq[0] = F_REG;
        BlockStreetPriceOracle.AssetConfig memory c = BlockStreetPriceOracle.AssetConfig({
            baseUnit: 1e18, equityFeeds: eq, proxyFeed: bytes32(0), rrFeed: bytes32(0),
            maxPriceAge: MAX_AGE, maxConfBps: 0, rrLowerMantissa: 0, rrUpperMantissa: 0
        });
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        oracle.setAssetConfig(BTOKEN, c);
    }

    function test_Admin_RejectsInvalidConfig() public {
        bytes32[] memory empty = new bytes32[](0);
        BlockStreetPriceOracle.AssetConfig memory c = BlockStreetPriceOracle.AssetConfig({
            baseUnit: 1e18, equityFeeds: empty, proxyFeed: bytes32(0), rrFeed: bytes32(0), // no feeds at all
            maxPriceAge: MAX_AGE, maxConfBps: 0, rrLowerMantissa: 0, rrUpperMantissa: 0
        });
        vm.expectRevert(BlockStreetPriceOracle.OracleInvalidConfiguration.selector);
        oracle.setAssetConfig(BTOKEN, c);
    }
}
