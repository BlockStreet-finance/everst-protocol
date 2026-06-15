// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "../src/Blotroller.sol";
import "../src/Unitroller.sol";
import "../src/BlotrollerStorage.sol";
import "../src/ErrorReporter.sol";
import "../src/SimplePriceOracle.sol";
import "../src/BTokenInterfaces.sol";
import "../src/BErc20Delegate.sol";
import "../src/BErc20Delegator.sol";
import "../src/JumpRateModel.sol";
import "../src/MockERC20.sol";

/**
 * @title Dual-line collateral invariants
 * @dev Verifies that borrowFactor (borrow line) and collateralFactor (liquidation threshold)
 *      are two independent lines:
 *        - borrow/redeem are gated by borrowFactor;
 *        - liquidation is gated by the liquidation threshold;
 *        - lowering borrowFactor can never make an existing position liquidatable.
 */
contract DualLineCollateralTest is Test {
    uint internal constant EXP = 1e18;

    Unitroller internal unitroller;
    Blotroller internal blotroller;
    SimplePriceOracle internal oracle;
    JumpRateModel internal irm;
    BErc20Delegate internal delegate;

    MockERC20 internal collUnderlying;   // 18 decimals, used as collateral
    MockERC20 internal borrowUnderlying;  // 18 decimals, the borrowed asset

    BErc20Delegator internal bColl;
    BErc20Delegator internal bBorrow;

    address internal admin = address(0x1);
    address internal user = address(0x2);
    address internal keeper = address(0x3);
    address internal lp = address(0x4);

    uint internal constant LT = 0.8e18;       // liquidation threshold 80%
    uint internal constant BF = 0.5e18;       // borrow line 50%

    function setUp() public {
        vm.startPrank(admin);

        collUnderlying = new MockERC20("Collateral", "COLL", 18, 1_000_000 * EXP);
        borrowUnderlying = new MockERC20("Borrowable", "BORR", 18, 1_000_000 * EXP);

        Blotroller impl = new Blotroller();
        unitroller = new Unitroller();
        unitroller._setPendingImplementation(address(impl));
        impl._become(unitroller);
        blotroller = Blotroller(payable(address(unitroller)));

        oracle = new SimplePriceOracle();
        blotroller._setPriceOracle(oracle);
        blotroller._setCloseFactor(0.5e18);
        blotroller._setLiquidationIncentive(1.08e18);

        irm = new JumpRateModel(0, 0, 0, 0.8e18); // zero-rate model -> no interest noise
        delegate = new BErc20Delegate();

        bColl = _deployBToken(collUnderlying, "bCOLL");
        bBorrow = _deployBToken(borrowUnderlying, "bBORR");

        oracle.setUnderlyingPrice(BToken(address(bColl)), 1 * EXP);   // $1
        oracle.setUnderlyingPrice(BToken(address(bBorrow)), 1 * EXP); // $1

        blotroller._supportMarket(BToken(address(bColl)));
        blotroller._supportMarket(BToken(address(bBorrow)));

        blotroller._setCollateralFactor(BToken(address(bColl)), LT);
        blotroller._setBorrowFactor(BToken(address(bColl)), BF);

        // Seed liquidity for the borrowable market.
        borrowUnderlying.transfer(lp, 100_000 * EXP);
        vm.stopPrank();

        vm.startPrank(lp);
        borrowUnderlying.approve(address(bBorrow), 100_000 * EXP);
        bBorrow.mint(100_000 * EXP);
        vm.stopPrank();

        // Fund the user with collateral underlying.
        vm.prank(admin);
        collUnderlying.transfer(user, 10_000 * EXP);
    }

    function _deployBToken(MockERC20 underlying, string memory sym) internal returns (BErc20Delegator) {
        return new BErc20Delegator(
            address(underlying),
            BlotrollerInterface(address(unitroller)),
            InterestRateModel(address(irm)),
            0.2e18 * 1e9, // initial exchange rate (mirrors existing suite: 0.2 * 1e27 region)
            "BlockStreet Token",
            sym,
            18,
            payable(admin),
            address(delegate),
            ""
        );
    }

    /// @dev user deposits 1000 COLL ($1000) and enters the collateral market.
    function _depositCollateral(uint amount) internal {
        vm.startPrank(user);
        collUnderlying.approve(address(bColl), amount);
        bColl.mint(amount);
        address[] memory m = new address[](1);
        m[0] = address(bColl);
        blotroller.enterMarkets(m);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // Gap: borrowing is capped by borrowFactor, not the liquidation line
    // -----------------------------------------------------------------
    function test_BorrowCappedByBorrowFactor_NotLiquidationThreshold() public {
        _depositCollateral(1000 * EXP); // $1000 collateral

        // borrowFactor 50% -> $500 capacity. $400 must succeed.
        vm.prank(user);
        assertEq(bBorrow.borrow(400 * EXP), 0, "borrow within borrow line should pass");

        // $400 + $150 = $550 > $500 borrow line, yet < $800 liquidation line.
        // Single-line model would have allowed this; dual-line must reject.
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(TokenErrorReporter.BorrowComptrollerRejection.selector, uint(BlotrollerErrorReporter.Error.INSUFFICIENT_LIQUIDITY))
        );
        bBorrow.borrow(150 * EXP);
    }

    // -----------------------------------------------------------------
    // CORE INVARIANT: lowering borrowFactor blocks NEW borrows but never
    // makes an existing position liquidatable.
    // -----------------------------------------------------------------
    function test_LoweringBorrowFactor_BlocksNewBorrow_KeepsExistingSafe() public {
        _depositCollateral(1000 * EXP);

        vm.prank(user);
        assertEq(bBorrow.borrow(400 * EXP), 0, "initial borrow should pass");

        // Sanity: not liquidatable now (debt $400 vs liquidation collateral $800).
        assertEq(
            blotroller.liquidateBorrowAllowed(address(bBorrow), address(bColl), keeper, user, 1),
            uint(BlotrollerErrorReporter.Error.INSUFFICIENT_SHORTFALL),
            "should not be liquidatable before"
        );

        // Drop the borrow line to ZERO (simulates high-risk freeze / pre-earnings de-risk).
        vm.prank(admin);
        assertEq(blotroller._setBorrowFactor(BToken(address(bColl)), 0), 0, "setBorrowFactor(0) ok");

        // New borrow is now blocked.
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(TokenErrorReporter.BorrowComptrollerRejection.selector, uint(BlotrollerErrorReporter.Error.INSUFFICIENT_LIQUIDITY))
        );
        bBorrow.borrow(1);

        // ...but the existing position is STILL NOT liquidatable: liquidation uses the
        // untouched liquidation threshold, not borrowFactor.
        assertEq(
            blotroller.liquidateBorrowAllowed(address(bBorrow), address(bColl), keeper, user, 1),
            uint(BlotrollerErrorReporter.Error.INSUFFICIENT_SHORTFALL),
            "lowering borrowFactor must not make the position liquidatable"
        );

        // Repay must still be allowed (price-independent exit).
        vm.startPrank(user);
        borrowUnderlying.approve(address(bBorrow), 400 * EXP);
        assertEq(bBorrow.repayBorrow(400 * EXP), 0, "repay must always be allowed");
        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // Liquidation DOES respond to the liquidation threshold.
    // -----------------------------------------------------------------
    function test_LoweringLiquidationThreshold_MakesPositionLiquidatable() public {
        _depositCollateral(1000 * EXP);
        vm.prank(user);
        assertEq(bBorrow.borrow(400 * EXP), 0, "borrow ok");

        // Lower borrowFactor first so the threshold can legally drop below it.
        vm.startPrank(admin);
        blotroller._setBorrowFactor(BToken(address(bColl)), 0.2e18);
        // Liquidation collateral becomes $300 < $400 debt -> shortfall.
        blotroller._setCollateralFactor(BToken(address(bColl)), 0.3e18);
        vm.stopPrank();

        // Now the shortfall check passes; a within-closeFactor repay is allowed.
        assertEq(
            blotroller.liquidateBorrowAllowed(address(bBorrow), address(bColl), keeper, user, 100 * EXP),
            0,
            "position should be liquidatable after lowering the liquidation threshold"
        );
    }

    // -----------------------------------------------------------------
    // Two-line ordering invariant: borrowFactor <= liquidationThreshold
    // -----------------------------------------------------------------
    function test_SetBorrowFactor_RejectedAboveLiquidationThreshold() public {
        vm.prank(admin);
        // LT is 0.8 -> 0.9 borrowFactor must be rejected.
        assertEq(
            blotroller._setBorrowFactor(BToken(address(bColl)), 0.9e18),
            uint(BlotrollerErrorReporter.Error.INVALID_COLLATERAL_FACTOR),
            "borrowFactor above liquidation threshold must be rejected"
        );
    }

    function test_SetCollateralFactor_RejectedBelowBorrowFactor() public {
        // borrowFactor is 0.5 -> lowering LT to 0.4 must be rejected.
        vm.prank(admin);
        assertEq(
            blotroller._setCollateralFactor(BToken(address(bColl)), 0.4e18),
            uint(BlotrollerErrorReporter.Error.INVALID_COLLATERAL_FACTOR),
            "liquidation threshold below borrow line must be rejected"
        );
    }

    // -----------------------------------------------------------------
    // Asymmetric access: cfKeeper may only LOWER borrowFactor.
    // -----------------------------------------------------------------
    function test_CfKeeper_CanLowerNotRaise() public {
        vm.prank(admin);
        blotroller._setCfKeeper(keeper);

        // Keeper lowers: ok, immediate.
        vm.prank(keeper);
        assertEq(blotroller._setBorrowFactor(BToken(address(bColl)), 0.3e18), 0, "keeper may lower");
        (, , uint bf) = blotroller.markets(address(bColl));
        assertEq(bf, 0.3e18, "borrowFactor lowered");

        // Keeper raises: unauthorized.
        vm.prank(keeper);
        assertEq(
            blotroller._setBorrowFactor(BToken(address(bColl)), 0.4e18),
            uint(BlotrollerErrorReporter.Error.UNAUTHORIZED),
            "keeper may not raise borrowFactor"
        );
    }

    function test_NonKeeperNonAdmin_CannotSetBorrowFactor() public {
        vm.prank(user);
        assertEq(
            blotroller._setBorrowFactor(BToken(address(bColl)), 0.1e18),
            uint(BlotrollerErrorReporter.Error.UNAUTHORIZED),
            "random caller cannot set borrowFactor"
        );
    }

    // -----------------------------------------------------------------
    // Step limit on lowering the liquidation threshold.
    // -----------------------------------------------------------------
    function test_LiquidationThreshold_StepLimitEnforced() public {
        vm.startPrank(admin);
        blotroller._setLiquidationThresholdMaxReduction(0.05e18); // max 5% per change

        // LT 0.8 -> 0.7 is a 0.10 drop > 0.05 cap -> rejected.
        assertEq(
            blotroller._setCollateralFactor(BToken(address(bColl)), 0.7e18),
            uint(BlotrollerErrorReporter.Error.INVALID_COLLATERAL_FACTOR),
            "drop beyond step cap must be rejected"
        );

        // LT 0.8 -> 0.76 is a 0.04 drop <= cap -> allowed.
        assertEq(blotroller._setCollateralFactor(BToken(address(bColl)), 0.76e18), 0, "within-cap drop allowed");

        // Raising is never step-limited.
        assertEq(blotroller._setCollateralFactor(BToken(address(bColl)), 0.85e18), 0, "raising not step-limited");
        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // Global borrow haircut (spec §10.2)
    // -----------------------------------------------------------------

    uint internal constant UNAUTH = uint(BlotrollerErrorReporter.Error.UNAUTHORIZED);

    function test_GlobalHaircut_GuardianHalt_StopsNewBorrow_KeepsExistingSafe() public {
        _depositCollateral(1000 * EXP);
        vm.prank(user);
        assertEq(bBorrow.borrow(400 * EXP), 0, "initial borrow ok");

        // GUARDIAN slams the global haircut to 100% (e.g. USDC depeg / system event).
        vm.prank(admin);
        assertEq(blotroller._setGuardianHaircut(1e18), 0, "guardian halt ok");
        assertEq(blotroller.effectiveBorrowHaircutMantissa(), 1e18);

        // All new borrowing is frozen across the protocol...
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(TokenErrorReporter.BorrowComptrollerRejection.selector, uint(BlotrollerErrorReporter.Error.INSUFFICIENT_LIQUIDITY))
        );
        bBorrow.borrow(1);

        // ...but existing positions are NOT force-liquidated (haircut never touches the liquidation line).
        assertEq(
            blotroller.liquidateBorrowAllowed(address(bBorrow), address(bColl), keeper, user, 1),
            uint(BlotrollerErrorReporter.Error.INSUFFICIENT_SHORTFALL),
            "haircut must not make positions liquidatable"
        );

        // Repay still works.
        vm.startPrank(user);
        borrowUnderlying.approve(address(bBorrow), 400 * EXP);
        assertEq(bBorrow.repayBorrow(400 * EXP), 0, "repay still allowed");
        vm.stopPrank();
    }

    function test_GlobalHaircut_PartialReducesCapacity() public {
        _depositCollateral(1000 * EXP); // borrowFactor 50% -> $500 capacity
        vm.prank(user);
        assertEq(bBorrow.borrow(200 * EXP), 0, "borrow 200 ok");

        // keeper haircut 60% -> effective borrowFactor 0.5*0.4 = 0.2 -> $200 capacity (already used).
        vm.prank(admin);
        blotroller._setKeeperHaircut(0.6e18);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(TokenErrorReporter.BorrowComptrollerRejection.selector, uint(BlotrollerErrorReporter.Error.INSUFFICIENT_LIQUIDITY))
        );
        bBorrow.borrow(1); // capacity exhausted by the haircut
    }

    function test_GlobalHaircut_EffectiveIsMax() public {
        vm.startPrank(admin);
        blotroller._setKeeperHaircut(0.3e18);
        blotroller._setGuardianHaircut(0.1e18);
        assertEq(blotroller.effectiveBorrowHaircutMantissa(), 0.3e18, "max(keeper, guardian)");
        blotroller._setGuardianHaircut(0.5e18);
        assertEq(blotroller.effectiveBorrowHaircutMantissa(), 0.5e18);
        vm.stopPrank();
    }

    function test_KeeperHaircut_RoleCanRaiseNotLower() public {
        vm.prank(admin);
        blotroller._setRiskKeeper(keeper);

        // keeper raises (tightens) -> immediate
        vm.prank(keeper);
        assertEq(blotroller._setKeeperHaircut(0.2e18), 0, "keeper may raise");
        assertEq(blotroller.keeperHaircutMantissa(), 0.2e18);

        // keeper tries to lower (relax) -> unauthorized, value unchanged
        vm.prank(keeper);
        assertEq(blotroller._setKeeperHaircut(0.1e18), UNAUTH, "keeper may not lower");
        assertEq(blotroller.keeperHaircutMantissa(), 0.2e18);

        // admin may lower
        vm.prank(admin);
        assertEq(blotroller._setKeeperHaircut(0.1e18), 0, "admin may lower");
    }

    function test_GuardianHaircut_RoleCanRaiseNotLower() public {
        vm.prank(admin);
        blotroller._setPauseGuardian(lp); // reuse lp as the guardian

        vm.prank(lp);
        assertEq(blotroller._setGuardianHaircut(1e18), 0, "guardian may raise to halt");

        vm.prank(lp);
        assertEq(blotroller._setGuardianHaircut(0), UNAUTH, "guardian may not lift");

        vm.prank(admin);
        assertEq(blotroller._setGuardianHaircut(0), 0, "admin may lift");
    }

    function test_Haircut_RejectsAboveOne() public {
        vm.prank(admin);
        assertEq(
            blotroller._setKeeperHaircut(1e18 + 1),
            uint(BlotrollerErrorReporter.Error.INVALID_COLLATERAL_FACTOR),
            "haircut > 100% rejected"
        );
    }
}
