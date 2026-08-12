// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "../src/Blotroller.sol";
import "../src/Unitroller.sol";
import "../src/BlotrollerStorage.sol";
import "../src/SimplePriceOracle.sol";
import "../src/BErc20Delegate.sol";
import "../src/BErc20Delegator.sol";
import "../src/JumpRateModel.sol";
import "../src/MockERC20.sol";

/// @dev Measures getAccountLiquiditySeparated for an account that is a member of
///      several markets but holds a position in only one of them -- the case an
///      early return on (balance == 0 && borrow == 0) would skip.
contract SeparationGasBenchTest is Test {
    Unitroller internal unitroller;
    Blotroller internal blotroller;
    SimplePriceOracle internal oracle;
    JumpRateModel internal irm;
    BErc20Delegate internal delegate;

    MockERC20[4] internal tok;
    BErc20Delegator[4] internal bTok;

    address internal admin = address(0x1);
    address internal user = address(0x2);

    function setUp() public {
        vm.startPrank(admin);

        Blotroller impl = new Blotroller();
        unitroller = new Unitroller();
        unitroller._setPendingImplementation(address(impl));
        impl._become(unitroller);
        blotroller = Blotroller(payable(address(unitroller)));

        oracle = new SimplePriceOracle();
        blotroller._setPriceOracle(oracle);
        irm = new JumpRateModel(0, 0, 0, 0.8e18);
        delegate = new BErc20Delegate();

        for (uint i = 0; i < 4; i++) {
            tok[i] = new MockERC20("T", "T", 18, 1_000_000e18);
            bTok[i] = new BErc20Delegator(
                address(tok[i]),
                BlotrollerInterface(address(unitroller)),
                InterestRateModel(address(irm)),
                2e26,
                "bT",
                "bT",
                18,
                payable(admin),
                address(delegate),
                ""
            );
            oracle.setUnderlyingPrice(BToken(address(bTok[i])), 1e18);
            blotroller._supportMarket(BToken(address(bTok[i])));
            blotroller._setTokenType(
                BToken(address(bTok[i])),
                i % 2 == 0 ? BlotrollerStorage.TokenType.TYPE_A : BlotrollerStorage.TokenType.TYPE_B
            );
            blotroller._setCollateralFactor(BToken(address(bTok[i])), 0.8e18);
            blotroller._setBorrowFactor(BToken(address(bTok[i])), 0.8e18);
            tok[i].transfer(user, 10_000e18);
        }
        blotroller._setSeparationMode(true);
        vm.stopPrank();

        // User holds a position in market 0 only, but is a member of all four.
        vm.startPrank(user);
        tok[0].approve(address(bTok[0]), 1000e18);
        bTok[0].mint(1000e18);
        address[] memory all = new address[](4);
        for (uint i = 0; i < 4; i++) all[i] = address(bTok[i]);
        blotroller.enterMarkets(all);
        vm.stopPrank();
    }

    function test_GasFourMarketsOneFunded() public view {
        uint g0 = gasleft();
        blotroller.getAccountLiquiditySeparated(user);
        uint used = g0 - gasleft();
        console.log("4 markets, 1 funded / 3 empty  gas:", used);
    }

    /// The path actually executing in production today (separation mode off).
    function test_GasSingleLineFourMarketsOneFunded() public {
        vm.prank(admin);
        blotroller._setSeparationMode(false);
        uint g0 = gasleft();
        blotroller.getAccountLiquidity(user);
        uint used = g0 - gasleft();
        console.log("SINGLE-LINE 4 markets, 1 funded / 3 empty  gas:", used);
    }

    function test_GasSingleLineOneMarketOnly() public {
        vm.prank(admin);
        blotroller._setSeparationMode(false);
        for (uint i = 1; i < 4; i++) {
            vm.prank(user);
            blotroller.exitMarket(address(bTok[i]));
        }
        uint g0 = gasleft();
        blotroller.getAccountLiquidity(user);
        uint used = g0 - gasleft();
        console.log("SINGLE-LINE 1 market,  1 funded / 0 empty  gas:", used);
    }

    function test_GasOneMarketOnly() public {
        for (uint i = 1; i < 4; i++) {
            vm.prank(user);
            blotroller.exitMarket(address(bTok[i]));
        }
        uint g0 = gasleft();
        blotroller.getAccountLiquiditySeparated(user);
        uint used = g0 - gasleft();
        console.log("1 market,  1 funded / 0 empty  gas:", used);
    }
}
