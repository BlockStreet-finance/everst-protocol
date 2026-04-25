// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "../src/Unitroller.sol";
import "../src/Blotroller.sol";
import "../src/BErc20Delegate.sol";
import "../src/BErc20Delegator.sol";
import "../src/BlockStreetPriceOracle.sol";
import "../src/JumpRateModel.sol";
import "../src/MockERC20.sol";
import "../src/BToken.sol";
import "../src/PriceOracle.sol";
import "../src/BlotrollerInterface.sol";

import "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";

/**
 * @title RepayBorrowTest — full-stack repay-after-interest tests
 * @notice Spins up the entire protocol in a single foundry test so we can
 *         supply → borrow → warp 10min → repay(uint256.max) and verify
 *         behaviour deterministically.
 *
 * Run:  forge test --match-contract RepayBorrowTest -vvv
 */
contract RepayBorrowTest is Test {
    // ===== Test actors =====
    address internal admin = address(this);
    address internal alice = makeAddr("alice");

    // ===== Protocol =====
    MockPyth                internal pyth;
    MockERC20               internal wtCOIN;
    Unitroller              internal unitroller;
    Blotroller              internal blotrollerImpl;
    Blotroller              internal comptroller; // proxy
    BlockStreetPriceOracle  internal oracle;
    JumpRateModel           internal irm;
    BErc20Delegate          internal bErc20Delegate;
    BErc20Delegator         internal bwtCOIN;

    // ===== Pyth config =====
    bytes32 constant COIN_USD_PRICE_ID =
        0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245;
    int64  constant MOCK_PRICE = 25_000_000_000; // $250 with expo=-8
    uint64 constant MOCK_CONF  = 50_000_000;     // 0.2%
    int32  constant MOCK_EXPO  = -8;

    // Blocks in 10 minutes if a block is ~15s (JumpRateModel.blocksPerYear basis).
    uint256 constant BLOCKS_IN_TEN_MIN = 40;

    function setUp() public {
        // --- Mocks ---
        pyth = new MockPyth(3600, 0); // fee=0 to simplify
        wtCOIN = new MockERC20("Mock Wrapped COIN", "wtCOIN", 18, 0);

        _pushPythPrice();

        // --- Core ---
        irm = new JumpRateModel(
            0.02e18,  // 2% APY base
            0.20e18,  // 20% APY multiplier
            2.0e18,   // 200% APY jump
            0.80e18   // kink at 80%
        );

        unitroller     = new Unitroller();
        blotrollerImpl = new Blotroller();
        unitroller._setPendingImplementation(address(blotrollerImpl));
        blotrollerImpl._become(unitroller);
        comptroller = Blotroller(payable(address(unitroller)));

        oracle = new BlockStreetPriceOracle(IPyth(address(pyth)), 14400);
        comptroller._setPriceOracle(PriceOracle(address(oracle)));
        comptroller._setCloseFactor(0.5e18);
        comptroller._setLiquidationIncentive(1.08e18);

        // --- Market ---
        bErc20Delegate = new BErc20Delegate();
        bwtCOIN = new BErc20Delegator(
            address(wtCOIN),
            BlotrollerInterface(address(unitroller)),
            InterestRateModel(address(irm)),
            2e26, // 1 wtCOIN = 50 bwtCOIN (8 decimals)
            "BlockStreet wtCOIN",
            "bwtCOIN",
            8,
            payable(admin),
            address(bErc20Delegate),
            ""
        );

        address[] memory bTokens = new address[](1);
        BlockStreetPriceOracle.AssetConfig[] memory cfgs =
            new BlockStreetPriceOracle.AssetConfig[](1);
        bTokens[0] = address(bwtCOIN);
        cfgs[0] = BlockStreetPriceOracle.AssetConfig({
            underlying:          address(wtCOIN),
            baseUnit:            1e18,
            pythPriceId:         COIN_USD_PRICE_ID,
            maxPriceAge:         3600,
            maxConfidenceRatio:  200
        });
        oracle.setAssetConfigs(bTokens, cfgs);

        comptroller._supportMarket(BToken(address(bwtCOIN)));
        comptroller._setCollateralFactor(BToken(address(bwtCOIN)), 0.5e18);

        BToken[] memory capT = new BToken[](1);
        uint[]   memory caps = new uint[](1);
        capT[0] = BToken(address(bwtCOIN));
        caps[0] = 100_000 ether;
        comptroller._setMarketBorrowCaps(capT, caps);

        bwtCOIN._setReserveFactor(0.2e18);

        // --- Fund alice ---
        wtCOIN.mint(alice, 200 ether);
    }

    // =========================================================
    // Happy path: borrow, warp 10min, repay(max)
    // =========================================================
    function test_fullRepay_afterTenMinutes_succeeds() public {
        _supplyAndBorrow(alice, 100 ether, 10 ether);

        // Snapshot before warp
        uint256 debtBefore = BErc20Delegator(bwtCOIN).borrowBalanceCurrent(alice);
        emit log_named_uint("debt right after borrow", debtBefore);
        assertEq(debtBefore, 10 ether, "fresh borrow should equal principal");

        // ---- Simulate 10 minutes of blocks ----
        vm.warp(block.timestamp + 10 minutes);
        vm.roll(block.number + BLOCKS_IN_TEN_MIN);
        _pushPythPrice(); // keep oracle fresh, though repay doesn't require price

        // accrueInterest via a state-changing call
        bwtCOIN.accrueInterest();

        uint256 debtAfter = bwtCOIN.borrowBalanceCurrent(alice);
        emit log_named_uint("debt after 10min warp  ", debtAfter);
        assertGt(debtAfter, debtBefore, "interest should have accrued");

        // ---- Full repay ----
        uint256 walletBefore = wtCOIN.balanceOf(alice);
        emit log_named_uint("wallet wtCOIN before   ", walletBefore);

        vm.startPrank(alice);
        wtCOIN.approve(address(bwtCOIN), type(uint256).max);
        uint err = bwtCOIN.repayBorrow(type(uint256).max);
        vm.stopPrank();

        assertEq(err, 0, "repayBorrow should return NO_ERROR");

        uint256 debtFinal   = bwtCOIN.borrowBalanceCurrent(alice);
        uint256 walletAfter = wtCOIN.balanceOf(alice);
        emit log_named_uint("wallet wtCOIN after    ", walletAfter);
        emit log_named_uint("debt after full repay  ", debtFinal);

        assertEq(debtFinal, 0, "debt should be fully cleared");
        assertEq(walletBefore - walletAfter, debtAfter,
                 "wallet should be debited exactly the accrued debt");
    }

    // =========================================================
    // Failure: insufficient wallet balance
    // =========================================================
    function test_fullRepay_insufficientBalance_reverts() public {
        _supplyAndBorrow(alice, 100 ether, 10 ether);

        // Drain alice's wallet so she only has 5 wtCOIN — below the debt.
        uint256 drain = wtCOIN.balanceOf(alice) - 5 ether;
        vm.prank(alice);
        wtCOIN.transfer(address(0xdead), drain);

        vm.warp(block.timestamp + 10 minutes);
        vm.roll(block.number + BLOCKS_IN_TEN_MIN);

        vm.startPrank(alice);
        wtCOIN.approve(address(bwtCOIN), type(uint256).max);
        vm.expectRevert(bytes("Insufficient balance"));
        bwtCOIN.repayBorrow(type(uint256).max);
        vm.stopPrank();
    }

    // =========================================================
    // Failure: approval too low (exactly principal, debt grew via interest)
    // =========================================================
    function test_fullRepay_approveExactPrincipal_revertsAfterInterest() public {
        _supplyAndBorrow(alice, 100 ether, 10 ether);

        vm.warp(block.timestamp + 10 minutes);
        vm.roll(block.number + BLOCKS_IN_TEN_MIN);

        vm.startPrank(alice);
        // Approve *exactly* the principal — not the accrued debt.
        wtCOIN.approve(address(bwtCOIN), 10 ether);
        vm.expectRevert(bytes("Insufficient allowance"));
        bwtCOIN.repayBorrow(type(uint256).max);
        vm.stopPrank();
    }

    // =========================================================
    // Failure: repay(fixedAmount=principal) leaves dust after interest
    // =========================================================
    function test_fixedRepay_leavesDust() public {
        _supplyAndBorrow(alice, 100 ether, 10 ether);

        vm.warp(block.timestamp + 10 minutes);
        vm.roll(block.number + BLOCKS_IN_TEN_MIN);

        vm.startPrank(alice);
        wtCOIN.approve(address(bwtCOIN), type(uint256).max);
        uint err = bwtCOIN.repayBorrow(10 ether); // principal only
        vm.stopPrank();

        assertEq(err, 0);
        uint256 dust = bwtCOIN.borrowBalanceCurrent(alice);
        emit log_named_uint("dust left after principal-only repay", dust);
        assertGt(dust, 0, "repaying only principal should leave interest dust");
    }

    // =========================================================
    // helpers
    // =========================================================
    function _supplyAndBorrow(address who, uint256 supply, uint256 borrow) internal {
        vm.startPrank(who);
        wtCOIN.approve(address(bwtCOIN), type(uint256).max);
        require(bwtCOIN.mint(supply) == 0, "mint failed");

        address[] memory markets = new address[](1);
        markets[0] = address(bwtCOIN);
        uint[] memory errs = comptroller.enterMarkets(markets);
        require(errs[0] == 0, "enterMarkets failed");

        require(bwtCOIN.borrow(borrow) == 0, "borrow failed");
        vm.stopPrank();
    }

    function _pushPythPrice() internal {
        bytes[] memory upd = new bytes[](1);
        upd[0] = pyth.createPriceFeedUpdateData(
            COIN_USD_PRICE_ID,
            MOCK_PRICE, MOCK_CONF, MOCK_EXPO,
            MOCK_PRICE, MOCK_CONF,
            uint64(block.timestamp),
            uint64(block.timestamp - 1)
        );
        pyth.updatePriceFeeds{value: 0}(upd);
    }
}
