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
 * @title Separation-mode redeem risk-line PoC (H1)
 * @dev In separation mode the A line is "TYPE_A collateral backs TYPE_B borrows"
 *      (shortfallA = borrowsB - collateralA) and the B line is the mirror
 *      (shortfallB = borrowsA - collateralB).
 *
 *      A redeem of TYPE_A collateral therefore belongs on the A line, but the
 *      original code booked the redeem value into sumBorrowPlusEffectsA (the
 *      borrow side of the *B* line) and then checked shortfallB. Both the
 *      accounting and the check land on the wrong line, which
 *        (a) freezes debt-free users who hold only one type of collateral, and
 *        (b) lets a borrower withdraw the entire collateral backing their debt.
 */
contract SeparationRedeemPoCTest is Test {
    Unitroller internal unitroller;
    Blotroller internal blotrollerImplementation;
    Blotroller internal blotroller;
    SimplePriceOracle internal oracle;
    JumpRateModel internal interestRateModel;
    BErc20Delegate internal bErc20Delegate;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    BErc20Delegator internal bTokenA; // TYPE_A
    BErc20Delegator internal bTokenB; // TYPE_B

    address internal admin = address(0x1);
    address internal user1 = address(0x2);

    uint internal constant CF = 0.8e18;

    function setUp() public {
        vm.startPrank(admin);

        tokenA = new MockERC20("Token A", "TOKA", 18, 1_000_000 * 10 ** 18);
        tokenB = new MockERC20("Token B", "TOKB", 6, 1_000_000 * 10 ** 6);

        blotrollerImplementation = new Blotroller();
        unitroller = new Unitroller();
        unitroller._setPendingImplementation(address(blotrollerImplementation));
        blotrollerImplementation._become(unitroller);
        blotroller = Blotroller(payable(address(unitroller)));

        oracle = new SimplePriceOracle();
        blotroller._setPriceOracle(oracle);

        interestRateModel = new JumpRateModel(0, 0, 0, 0.8e18); // zero-rate: keeps the PoC arithmetic exact
        bErc20Delegate = new BErc20Delegate();

        bTokenA = new BErc20Delegator(
            address(tokenA),
            BlotrollerInterface(address(unitroller)),
            InterestRateModel(address(interestRateModel)),
            200000000000000000000000000, // 0.2 * 10^18
            "BlockStreet Token A",
            "bTOKA",
            18,
            payable(admin),
            address(bErc20Delegate),
            ""
        );
        bTokenB = new BErc20Delegator(
            address(tokenB),
            BlotrollerInterface(address(unitroller)),
            InterestRateModel(address(interestRateModel)),
            200000000000000, // 0.2 * 10^6
            "BlockStreet Token B",
            "bTOKB",
            8,
            payable(admin),
            address(bErc20Delegate),
            ""
        );

        oracle.setUnderlyingPrice(BToken(address(bTokenA)), 1e18); // $1.00
        oracle.setUnderlyingPrice(BToken(address(bTokenB)), 1e30); // $1.00 (6-decimal underlying)

        blotroller._supportMarket(BToken(address(bTokenA)));
        blotroller._supportMarket(BToken(address(bTokenB)));
        blotroller._setTokenType(BToken(address(bTokenA)), BlotrollerStorage.TokenType.TYPE_A);
        blotroller._setTokenType(BToken(address(bTokenB)), BlotrollerStorage.TokenType.TYPE_B);
        blotroller._setCollateralFactor(BToken(address(bTokenA)), CF);
        blotroller._setCollateralFactor(BToken(address(bTokenB)), CF);
        blotroller._setBorrowFactor(BToken(address(bTokenA)), CF);
        blotroller._setBorrowFactor(BToken(address(bTokenB)), CF);
        blotroller._setSeparationMode(true);

        // Protocol-side cash so borrows can actually be funded.
        tokenA.approve(address(bTokenA), 100_000 * 10 ** 18);
        bTokenA.mint(100_000 * 10 ** 18);
        tokenB.approve(address(bTokenB), 100_000 * 10 ** 6);
        bTokenB.mint(100_000 * 10 ** 6);

        tokenA.transfer(user1, 10_000 * 10 ** 18);
        tokenB.transfer(user1, 10_000 * 10 ** 6);

        vm.stopPrank();
    }

    function _enter(address who, address[] memory mkts) internal {
        vm.prank(who);
        blotroller.enterMarkets(mkts);
    }

    function _markets(address m0) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = m0;
    }

    function _markets(address m0, address m1) internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = m0;
        a[1] = m1;
    }

    // ------------------------------------------------------------------
    // Case 1: a debt-free supplier of TYPE_A collateral cannot redeem it.
    // ------------------------------------------------------------------
    function test_PoC_DebtFreeUserCanRedeemTypeACollateral() public {
        vm.startPrank(user1);
        tokenA.approve(address(bTokenA), 1000 * 10 ** 18);
        bTokenA.mint(1000 * 10 ** 18);
        vm.stopPrank();

        _enter(user1, _markets(address(bTokenA)));

        // No borrows at all -> redeeming must always be allowed.
        assertEq(bTokenA.borrowBalanceStored(user1), 0, "precondition: no debt");

        uint half = bTokenA.balanceOf(user1) / 2;
        vm.prank(user1);
        uint err = bTokenA.redeem(half);
        assertEq(err, 0, "debt-free user must be able to redeem TYPE_A collateral");
    }

    // Mirror of case 1 on the TYPE_B side.
    function test_PoC_DebtFreeUserCanRedeemTypeBCollateral() public {
        vm.startPrank(user1);
        tokenB.approve(address(bTokenB), 1000 * 10 ** 6);
        bTokenB.mint(1000 * 10 ** 6);
        vm.stopPrank();

        _enter(user1, _markets(address(bTokenB)));

        uint half = bTokenB.balanceOf(user1) / 2;
        vm.prank(user1);
        uint err = bTokenB.redeem(half);
        assertEq(err, 0, "debt-free user must be able to redeem TYPE_B collateral");
    }

    // ------------------------------------------------------------------
    // Case 2: the same wrong line freezes exitMarket for a debt-free user.
    // ------------------------------------------------------------------
    function test_PoC_DebtFreeUserCanExitMarket() public {
        vm.startPrank(user1);
        tokenA.approve(address(bTokenA), 1000 * 10 ** 18);
        bTokenA.mint(1000 * 10 ** 18);
        vm.stopPrank();

        _enter(user1, _markets(address(bTokenA)));

        vm.prank(user1);
        uint err = blotroller.exitMarket(address(bTokenA));
        assertEq(err, 0, "debt-free user must be able to exit the market");
    }

    // ------------------------------------------------------------------
    // Case 3 (the severe one): a borrower withdraws 100% of the collateral
    // that backs their debt and the account lands in shortfall.
    // ------------------------------------------------------------------
    function test_PoC_CannotRedeemAllCollateralBackingABorrow() public {
        vm.startPrank(user1);
        // $1000 TYPE_A collateral -> $800 weighted on the A line.
        tokenA.approve(address(bTokenA), 1000 * 10 ** 18);
        bTokenA.mint(1000 * 10 ** 18);
        // $1000 TYPE_B collateral -> $800 weighted on the B line, backs nothing yet.
        tokenB.approve(address(bTokenB), 1000 * 10 ** 6);
        bTokenB.mint(1000 * 10 ** 6);
        vm.stopPrank();

        _enter(user1, _markets(address(bTokenA), address(bTokenB)));

        // Borrow $700 of TYPE_B, backed by the $800 of TYPE_A collateral (A line).
        vm.prank(user1);
        assertEq(bTokenB.borrow(700 * 10 ** 6), 0, "TYPE_B borrow against TYPE_A collateral");

        (, , uint shortfallABefore, , ) = blotroller.getAccountLiquiditySeparated(user1);
        assertEq(shortfallABefore, 0, "healthy before the redeem");

        // Now try to pull ALL the TYPE_A collateral out. The A line would be
        // 700 of borrows against 0 of collateral, so this must be rejected.
        uint allA = bTokenA.balanceOf(user1);
        vm.prank(user1);
        try bTokenA.redeem(allA) returns (uint err) {
            assertTrue(err != 0, "redeeming all backing collateral must not be allowed");
        } catch {
            // Reverting with RedeemComptrollerRejection is the expected outcome.
        }

        // Whatever path was taken, the account must not be left in shortfall.
        (, , uint shortfallAAfter, , ) = blotroller.getAccountLiquiditySeparated(user1);
        assertEq(shortfallAAfter, 0, "account must not be pushed into shortfall by its own redeem");
        assertGt(bTokenA.balanceOf(user1), 0, "backing collateral must still be there");
    }

    // Mirror of case 3: TYPE_B collateral backing a TYPE_A borrow.
    function test_PoC_CannotRedeemAllTypeBCollateralBackingABorrow() public {
        vm.startPrank(user1);
        tokenA.approve(address(bTokenA), 1000 * 10 ** 18);
        bTokenA.mint(1000 * 10 ** 18);
        tokenB.approve(address(bTokenB), 1000 * 10 ** 6);
        bTokenB.mint(1000 * 10 ** 6);
        vm.stopPrank();

        _enter(user1, _markets(address(bTokenA), address(bTokenB)));

        vm.prank(user1);
        assertEq(bTokenA.borrow(700 * 10 ** 18), 0, "TYPE_A borrow against TYPE_B collateral");

        uint allB = bTokenB.balanceOf(user1);
        vm.prank(user1);
        try bTokenB.redeem(allB) returns (uint err) {
            assertTrue(err != 0, "redeeming all backing collateral must not be allowed");
        } catch {}

        (, , , , uint shortfallBAfter) = blotroller.getAccountLiquiditySeparated(user1);
        assertEq(shortfallBAfter, 0, "account must not be pushed into shortfall by its own redeem");
        assertGt(bTokenB.balanceOf(user1), 0, "backing collateral must still be there");
    }

    // ------------------------------------------------------------------
    // The fix must compute the right withdrawal limit, not just deny everything.
    // $1000 TYPE_A collateral @ 80% = $800 on line A; a $400 TYPE_B borrow leaves
    // exactly $500 of TOKA (= half the bTokenA balance) withdrawable.
    // ------------------------------------------------------------------
    function test_PartialRedeemAllowedUpToTheLineLimit() public {
        vm.startPrank(user1);
        tokenA.approve(address(bTokenA), 1000 * 10 ** 18);
        bTokenA.mint(1000 * 10 ** 18);
        vm.stopPrank();

        _enter(user1, _markets(address(bTokenA)));

        vm.prank(user1);
        assertEq(bTokenB.borrow(400 * 10 ** 6), 0, "borrow $400 of TYPE_B");

        uint half = bTokenA.balanceOf(user1) / 2;

        // One wei past the limit is rejected.
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(TokenErrorReporter.RedeemComptrollerRejection.selector, 4));
        bTokenA.redeem(half + 1e9);

        // Exactly at the limit is allowed.
        vm.prank(user1);
        assertEq(bTokenA.redeem(half), 0, "redeem up to the line limit must be allowed");

        (, , uint shortfallA, , ) = blotroller.getAccountLiquiditySeparated(user1);
        assertEq(shortfallA, 0, "still healthy at the limit");
    }
}
