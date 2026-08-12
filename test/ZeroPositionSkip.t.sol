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
 * @dev Guards the "skip assets with an empty position" optimisation in
 *      getHypotheticalAccountLiquidityInternal.
 *
 *      The market being borrowed from is usually EMPTY at the moment of the very
 *      first borrow: balance 0, borrow 0. Skipping it on that basis also skips the
 *      `asset == bTokenModify` block that applies the hypothetical borrow, so the
 *      new debt never enters sumBorrowPlusEffects and any borrow size passes.
 *      An early return must therefore always exclude bTokenModify.
 */
contract ZeroPositionSkipTest is Test {
    Unitroller internal unitroller;
    Blotroller internal blotroller;
    SimplePriceOracle internal oracle;
    JumpRateModel internal irm;
    BErc20Delegate internal delegate;

    MockERC20 internal collatTok;
    MockERC20 internal borrowTok;
    BErc20Delegator internal bCollat;
    BErc20Delegator internal bBorrow;

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

        collatTok = new MockERC20("Collateral", "COL", 18, 1_000_000e18);
        borrowTok = new MockERC20("Borrowable", "BOR", 18, 1_000_000e18);

        bCollat = _deploy(collatTok, "bCOL");
        bBorrow = _deploy(borrowTok, "bBOR");

        oracle.setUnderlyingPrice(BToken(address(bCollat)), 1e18);
        oracle.setUnderlyingPrice(BToken(address(bBorrow)), 1e18);
        blotroller._supportMarket(BToken(address(bCollat)));
        blotroller._supportMarket(BToken(address(bBorrow)));
        blotroller._setCollateralFactor(BToken(address(bCollat)), 0.8e18);
        blotroller._setCollateralFactor(BToken(address(bBorrow)), 0.8e18);
        blotroller._setBorrowFactor(BToken(address(bCollat)), 0.8e18);
        blotroller._setBorrowFactor(BToken(address(bBorrow)), 0.8e18);

        // Protocol-side cash to lend out.
        borrowTok.approve(address(bBorrow), 500_000e18);
        bBorrow.mint(500_000e18);

        collatTok.transfer(user, 10_000e18);
        vm.stopPrank();

        // $1000 of collateral @ 80% => $800 of borrowing power, and nothing at all
        // in the market the user is about to borrow from.
        vm.startPrank(user);
        collatTok.approve(address(bCollat), 1000e18);
        bCollat.mint(1000e18);
        address[] memory mkts = new address[](1);
        mkts[0] = address(bCollat);
        blotroller.enterMarkets(mkts);
        vm.stopPrank();
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

    /// First borrow from an untouched market must still respect the collateral limit.
    function test_FirstBorrowFromEmptyMarketRespectsCollateral() public {
        assertEq(bBorrow.balanceOf(user), 0, "precondition: no position in the borrow market");
        assertEq(bBorrow.borrowBalanceStored(user), 0, "precondition: no debt in the borrow market");

        // $5000 against $800 of borrowing power.
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(TokenErrorReporter.BorrowComptrollerRejection.selector, 4));
        bBorrow.borrow(5000e18);

        assertEq(borrowTok.balanceOf(user), 0, "no funds may leave the protocol");
    }

    /// A dead price feed on a market the account merely entered, and holds nothing in,
    /// must not brick unrelated positions.
    function test_DeadOracleOnEmptyMarketDoesNotBlockTheAccount() public {
        address[] memory mkts = new address[](1);
        mkts[0] = address(bBorrow);
        vm.prank(user);
        blotroller.enterMarkets(mkts);

        vm.prank(admin);
        oracle.setUnderlyingPrice(BToken(address(bBorrow)), 0); // feed goes dark

        assertEq(bBorrow.balanceOf(user), 0, "nothing held in the dark market");

        uint half = bCollat.balanceOf(user) / 2;
        vm.prank(user);
        assertEq(bCollat.redeem(half), 0, "unrelated collateral must stay withdrawable");
    }

    /// The limit itself must still be reachable.
    function test_FirstBorrowUpToTheLimitStillWorks() public {
        vm.prank(user);
        assertEq(bBorrow.borrow(800e18), 0, "borrowing exactly the limit must succeed");
        assertEq(borrowTok.balanceOf(user), 800e18, "user received the funds");
    }
}
