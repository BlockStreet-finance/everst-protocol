// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "../src/Blotroller.sol";
import "../src/Unitroller.sol";
import "../src/BlotrollerStorage.sol";
import "../src/ErrorReporter.sol";
import "../src/SimplePriceOracle.sol";
import "../src/BErc20Delegate.sol";
import "../src/BErc20Delegator.sol";
import "../src/JumpRateModel.sol";
import "../src/MockERC20.sol";

/**
 * @dev Separation mode pairs each debt with the collateral of the OPPOSITE type:
 *      a TYPE_B (wrapped-stock) debt is secured by TYPE_A (liquid) collateral.
 *      Liquidation is where that pairing has to be cashed in, but neither
 *      liquidateBorrowAllowed nor seizeAllowed looks at the collateral's type --
 *      they only gate on the BORROWED market. A liquidator may therefore repay a
 *      TYPE_B debt and seize TYPE_B collateral, leaving the TYPE_A collateral that
 *      actually backs that debt untouched and putting two stock legs in one
 *      liquidation -- the exact case A/B separation exists to rule out.
 */
contract SeparationLiquidationLineTest is Test {
    Unitroller internal unitroller;
    Blotroller internal blotroller;
    SimplePriceOracle internal oracle;
    JumpRateModel internal irm;
    BErc20Delegate internal delegate;

    MockERC20 internal liquidTok; // TYPE_A, think USDC
    MockERC20 internal stockTok;  // TYPE_B, think wtCOIN
    BErc20Delegator internal bLiquid;
    BErc20Delegator internal bStock;

    address internal admin = address(0x1);
    address internal borrower = address(0x2);
    address internal liquidator = address(0x3);

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

        liquidTok = new MockERC20("Liquid", "LIQ", 18, 10_000_000e18);
        stockTok = new MockERC20("Stock", "STK", 18, 10_000_000e18);
        bLiquid = _deploy(liquidTok, "bLIQ");
        bStock = _deploy(stockTok, "bSTK");

        oracle.setUnderlyingPrice(BToken(address(bLiquid)), 1e18);
        oracle.setUnderlyingPrice(BToken(address(bStock)), 1e18);

        blotroller._supportMarket(BToken(address(bLiquid)));
        blotroller._supportMarket(BToken(address(bStock)));
        blotroller._setTokenType(BToken(address(bLiquid)), BlotrollerStorage.TokenType.TYPE_A);
        blotroller._setTokenType(BToken(address(bStock)), BlotrollerStorage.TokenType.TYPE_B);
        blotroller._setCollateralFactor(BToken(address(bLiquid)), 0.8e18);
        blotroller._setCollateralFactor(BToken(address(bStock)), 0.8e18);
        blotroller._setBorrowFactor(BToken(address(bLiquid)), 0.8e18);
        blotroller._setBorrowFactor(BToken(address(bStock)), 0.8e18);
        blotroller._setCloseFactor(0.5e18);
        blotroller._setLiquidationIncentive(1.08e18);
        blotroller._setSeparationMode(true);

        // Protocol-side cash.
        stockTok.approve(address(bStock), 100_000e18);
        bStock.mint(100_000e18);
        liquidTok.approve(address(bLiquid), 100_000e18);
        bLiquid.mint(100_000e18);

        liquidTok.transfer(borrower, 10_000e18);
        stockTok.transfer(borrower, 10_000e18);
        stockTok.transfer(liquidator, 10_000e18);
        vm.stopPrank();

        // Borrower runs both lines:
        //   line A -> $800 of TYPE_A collateral securing a $600 TYPE_B debt
        //   line B -> $800 of TYPE_B collateral securing nothing
        vm.startPrank(borrower);
        liquidTok.approve(address(bLiquid), 1000e18);
        bLiquid.mint(1000e18);
        stockTok.approve(address(bStock), 1000e18);
        bStock.mint(1000e18);
        address[] memory mkts = new address[](2);
        mkts[0] = address(bLiquid);
        mkts[1] = address(bStock);
        blotroller.enterMarkets(mkts);
        assertEq(bStock.borrow(600e18), 0, "TYPE_B borrow against TYPE_A collateral");
        vm.stopPrank();

        // The stock rallies: the TYPE_B debt outgrows the TYPE_A collateral securing it.
        vm.prank(admin);
        oracle.setUnderlyingPrice(BToken(address(bStock)), 1.5e18);
    }

    function _deploy(MockERC20 underlying, string memory sym) internal returns (BErc20Delegator) {
        return new BErc20Delegator(
            address(underlying),
            BlotrollerInterface(address(unitroller)),
            InterestRateModel(address(irm)),
            2e26,
            sym,
            sym,
            18,
            payable(admin),
            address(delegate),
            ""
        );
    }

    function test_LiquidatingLineAMustNotSeizeLineBCollateral() public {
        (, , uint shortfallA, , uint shortfallB) = blotroller.getAccountLiquiditySeparated(borrower);
        assertGt(shortfallA, 0, "line A is the one under water");
        assertEq(shortfallB, 0, "line B is healthy and must stay out of it");

        uint stockCollatBefore = bStock.balanceOf(borrower);
        uint liquidCollatBefore = bLiquid.balanceOf(borrower);

        // Repay the TYPE_B debt but seize TYPE_B collateral -- the wrong line.
        vm.startPrank(liquidator);
        stockTok.approve(address(bStock), 300e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenErrorReporter.LiquidateComptrollerRejection.selector,
                uint(BlotrollerErrorReporter.Error.REJECTION)
            )
        );
        bStock.liquidateBorrow(borrower, 300e18, BToken(address(bStock)));
        vm.stopPrank();

        assertEq(bStock.balanceOf(borrower), stockCollatBefore, "line B collateral untouched");
        assertEq(bLiquid.balanceOf(borrower), liquidCollatBefore, "line A collateral untouched");
    }

    /// seize is a separate comptroller entry point and must carry the same constraint.
    function test_SeizeAllowedRejectsSameLineCollateral() public {
        assertEq(
            blotroller.seizeAllowed(address(bStock), address(bStock), liquidator, borrower, 1e18),
            uint(BlotrollerErrorReporter.Error.REJECTION),
            "same-type seize must be rejected"
        );
        assertEq(
            blotroller.seizeAllowed(address(bLiquid), address(bStock), liquidator, borrower, 1e18),
            0,
            "opposite-type seize must be allowed"
        );
    }

    /// Retyping a live market would rewrite both lines under its holders: with no price moving
    /// and no token changing hands, this borrower went from (liqA 200, liqB 800) to a 600
    /// shortfall on line B -- and, because every market then sat on one line, no seize pair
    /// was legal any more, so the shortfall could not even be liquidated.
    function test_RetypingLiveMarketIsRefused() public {
        vm.prank(admin);
        oracle.setUnderlyingPrice(BToken(address(bStock)), 1e18); // healthy account

        (, , uint shortABefore, , uint shortBBefore) = blotroller.getAccountLiquiditySeparated(borrower);
        assertEq(shortABefore + shortBBefore, 0, "healthy on both lines to begin with");

        vm.prank(admin);
        assertEq(
            blotroller._setTokenType(BToken(address(bStock)), BlotrollerStorage.TokenType.TYPE_A),
            uint(BlotrollerErrorReporter.Error.REJECTION),
            "retyping a market with live positions must be refused"
        );

        (, , uint shortAAfter, , uint shortBAfter) = blotroller.getAccountLiquiditySeparated(borrower);
        assertEq(shortAAfter + shortBAfter, 0, "the borrower must not be pushed into shortfall");
        assertEq(uint(blotroller.tokenTypes(address(bStock))), uint(BlotrollerStorage.TokenType.TYPE_B), "type unchanged");
    }

    /// The new constraint must be gated on separation mode: with it off this is an ordinary
    /// Compound pool again and any collateral may be seized for any debt.
    function test_SeparationOffLeavesLiquidationUnconstrained() public {
        vm.prank(admin);
        blotroller._setSeparationMode(false);

        assertEq(
            blotroller.seizeAllowed(address(bStock), address(bStock), liquidator, borrower, 1e18),
            0,
            "same-type seize must be allowed outside separation mode"
        );
        assertTrue(
            blotroller.liquidateBorrowAllowed(address(bStock), address(bStock), liquidator, borrower, 300e18)
                != uint(BlotrollerErrorReporter.Error.REJECTION),
            "the line constraint must not fire outside separation mode"
        );
    }

    /// Everything off-chain (Lens.getAccountLimits, UIs, third-party liquidation bots)
    /// reads the single-line getAccountLiquidity, which nets both lines into one pool.
    function test_SingleLineViewAgreesWithSeparatedView() public view {
        (, , uint shortfallA, , uint shortfallB) = blotroller.getAccountLiquiditySeparated(borrower);
        (, uint mergedLiquidity, uint mergedShortfall) = blotroller.getAccountLiquidity(borrower);

        console.log("separated: shortfallA =", shortfallA, " shortfallB =", shortfallB);
        console.log("single-line: liquidity =", mergedLiquidity, " shortfall =", mergedShortfall);

        assertGt(shortfallA + shortfallB, 0, "the account IS under water on a line");
        assertGt(mergedShortfall, 0, "the view every bot reads must not call it healthy");
    }

    /// The legitimate liquidation -- repay TYPE_B debt, seize the TYPE_A collateral
    /// that actually secures it -- must keep working.
    function test_LiquidatingLineASeizingLineACollateralStillWorks() public {
        vm.startPrank(liquidator);
        stockTok.approve(address(bStock), 300e18);
        uint err = bStock.liquidateBorrow(borrower, 300e18, BToken(address(bLiquid)));
        vm.stopPrank();

        assertEq(err, 0, "repaying TYPE_B debt against TYPE_A collateral must succeed");
        assertGt(bLiquid.balanceOf(liquidator), 0, "liquidator seized TYPE_A collateral");
    }
}
