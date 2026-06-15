// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "../src/Blotroller.sol";
import "../src/AccessController.sol";
import "../src/BToken.sol";
import "../src/PriceOracle.sol";
import "../src/BlotrollerInterface.sol";

/// @dev Minimal BToken mock that satisfies `isBToken()` and returns a benign
///      snapshot (0 balance, 0 borrow, 1e18 exchange rate) for liquidity math.
contract AGMockBToken is BToken {
    constructor() BToken() {}

    function exchangeRateStoredInternal() internal view virtual override returns (uint) {
        return 1e18;
    }

    function getCashPrior() internal view virtual override returns (uint256) {
        return 0;
    }

    function doTransferIn(address, uint256 amount) internal virtual override returns (uint256) {
        return amount;
    }

    function doTransferOut(address payable, uint256) internal virtual override {}
}

/// @dev Minimal oracle that stores price per bToken address directly.
contract AGMockOracle is PriceOracle {
    mapping(address => uint256) public priceOf;

    function getUnderlyingPrice(BToken bToken) public view override returns (uint256) {
        return priceOf[address(bToken)];
    }

    function setPrice(address bToken, uint256 price) external {
        priceOf[bToken] = price;
    }
}

contract BlotrollerAccessGateTest is Test {
    Blotroller internal blotroller;
    AGMockBToken internal bToken;
    AGMockOracle internal oracle;
    AccessController internal ac;

    address internal alice = address(0xA1);
    address internal bob   = address(0xB0B);

    event NewAccessController(address oldAccessController, address newAccessController);

    function setUp() public {
        blotroller = new Blotroller();

        oracle = new AGMockOracle();
        uint err = blotroller._setPriceOracle(PriceOracle(address(oracle)));
        assertEq(err, 0, "setPriceOracle failed");

        bToken = new AGMockBToken();
        err = blotroller._supportMarket(BToken(address(bToken)));
        assertEq(err, 0, "supportMarket failed");

        oracle.setPrice(address(bToken), 1e18);

        ac = new AccessController();
    }

    // -------------------------------------------------------------------------
    // _setAccessController
    // -------------------------------------------------------------------------

    function test_accessController_defaultsToZero() public {
        assertEq(blotroller.accessController(), address(0));
    }

    function test_setAccessController_setsAndEmits() public {
        vm.expectEmit(false, false, false, true, address(blotroller));
        emit NewAccessController(address(0), address(ac));

        uint err = blotroller._setAccessController(address(ac));
        assertEq(err, 0);
        assertEq(blotroller.accessController(), address(ac));
    }

    function test_setAccessController_onlyAdmin() public {
        vm.prank(alice);
        uint err = blotroller._setAccessController(address(ac));
        assertTrue(err != 0, "non-admin should be rejected");
        assertEq(blotroller.accessController(), address(0));
    }

    function test_setAccessController_canBeDisabledAgain() public {
        uint err = blotroller._setAccessController(address(ac));
        assertEq(err, 0);
        assertEq(blotroller.accessController(), address(ac));

        err = blotroller._setAccessController(address(0));
        assertEq(err, 0);
        assertEq(blotroller.accessController(), address(0));
    }

    function test_mintAllowed_controllerIsEOA_reverts() public {
        // Pointing the gate at an EOA (or any address with no code at
        // isAllowedToMint) must not silently pass. staticcall into an EOA
        // returns success with empty data, which would decode as `false`
        // — so the gate correctly denies. We assert the on-chain behavior
        // rather than a specific revert string: either reject via
        // Error.REJECTION or revert on decode — both are safe-by-default.
        blotroller._setAccessController(address(0xDEAD));

        try blotroller.mintAllowed(address(bToken), alice, 1e18) returns (uint err) {
            assertEq(err, uint(BlotrollerErrorReporter.Error.REJECTION));
        } catch {
            // revert on decode is also acceptable
        }
    }

    // -------------------------------------------------------------------------
    // mintAllowed gate
    // -------------------------------------------------------------------------

    function test_mintAllowed_noController_returnsOk() public {
        uint err = blotroller.mintAllowed(address(bToken), alice, 1e18);
        assertEq(err, 0);
    }

    function test_mintAllowed_controllerDenies_returnsRejection() public {
        blotroller._setAccessController(address(ac));

        uint err = blotroller.mintAllowed(address(bToken), alice, 1e18);
        assertEq(err, uint(BlotrollerErrorReporter.Error.REJECTION));
    }

    function test_mintAllowed_controllerAllows_returnsOk() public {
        blotroller._setAccessController(address(ac));
        ac.setAllowed(alice, true);

        uint err = blotroller.mintAllowed(address(bToken), alice, 1e18);
        assertEq(err, 0);
    }

    function test_mintAllowed_allowlistIsPerUser() public {
        blotroller._setAccessController(address(ac));
        ac.setAllowed(alice, true);

        // alice ok
        uint err = blotroller.mintAllowed(address(bToken), alice, 1e18);
        assertEq(err, 0);

        // bob still denied
        err = blotroller.mintAllowed(address(bToken), bob, 1e18);
        assertEq(err, uint(BlotrollerErrorReporter.Error.REJECTION));
    }

    function test_mintAllowed_disablingGateRestoresAccess() public {
        blotroller._setAccessController(address(ac));

        uint err = blotroller.mintAllowed(address(bToken), alice, 1e18);
        assertEq(err, uint(BlotrollerErrorReporter.Error.REJECTION));

        blotroller._setAccessController(address(0));
        err = blotroller.mintAllowed(address(bToken), alice, 1e18);
        assertEq(err, 0);
    }

    // -------------------------------------------------------------------------
    // borrowAllowed gate
    //
    // We prank as the bToken itself so the msg.sender == bToken check passes
    // and the borrower is auto-added to the market. We call with amount 0 so
    // the downstream liquidity math yields no shortfall and returns NO_ERROR
    // on the happy path — isolating the gate from unrelated logic.
    // -------------------------------------------------------------------------

    function test_borrowAllowed_noController_returnsOk() public {
        vm.prank(address(bToken));
        uint err = blotroller.borrowAllowed(address(bToken), alice, 0);
        assertEq(err, 0);
    }

    function test_borrowAllowed_controllerDenies_returnsRejection() public {
        blotroller._setAccessController(address(ac));

        vm.prank(address(bToken));
        uint err = blotroller.borrowAllowed(address(bToken), alice, 0);
        assertEq(err, uint(BlotrollerErrorReporter.Error.REJECTION));
    }

    function test_borrowAllowed_controllerAllows_returnsOk() public {
        blotroller._setAccessController(address(ac));
        ac.setAllowed(alice, true);

        vm.prank(address(bToken));
        uint err = blotroller.borrowAllowed(address(bToken), alice, 0);
        assertEq(err, 0);
    }

    function test_borrowAllowed_allowlistIsPerUser() public {
        blotroller._setAccessController(address(ac));
        ac.setAllowed(alice, true);

        vm.prank(address(bToken));
        uint err = blotroller.borrowAllowed(address(bToken), alice, 0);
        assertEq(err, 0);

        vm.prank(address(bToken));
        err = blotroller.borrowAllowed(address(bToken), bob, 0);
        assertEq(err, uint(BlotrollerErrorReporter.Error.REJECTION));
    }

    // -------------------------------------------------------------------------
    // liquidateBorrowAllowed gate (spec §7.1 liquidator whitelist)
    //
    // The gate is checked after the markets-listed check. A non-whitelisted
    // liquidator returns REJECTION; a whitelisted one passes the gate and falls
    // through to the shortfall check (INSUFFICIENT_SHORTFALL here, since the
    // borrower has no debt) — i.e. NOT REJECTION. We use one listed market as
    // both the borrowed and collateral side.
    // -------------------------------------------------------------------------

    uint internal constant REJECTION = uint(BlotrollerErrorReporter.Error.REJECTION);

    function _liquidateAllowed(address liquidator) internal returns (uint) {
        return blotroller.liquidateBorrowAllowed(address(bToken), address(bToken), liquidator, alice, 0);
    }

    function test_liquidate_noController_anyoneAllowed() public {
        assertTrue(_liquidateAllowed(bob) != REJECTION, "no controller -> anyone may liquidate");
    }

    function test_liquidate_gateDisabledByDefault_anyoneAllowed() public {
        blotroller._setAccessController(address(ac)); // controller set, but liquidator gate OFF by default
        assertFalse(ac.liquidatorGateEnabled());
        assertTrue(_liquidateAllowed(bob) != REJECTION, "gate off -> anyone may liquidate");
    }

    function test_liquidate_gateEnabled_nonWhitelisted_returnsRejection() public {
        blotroller._setAccessController(address(ac));
        ac.setLiquidatorGateEnabled(true);
        assertEq(_liquidateAllowed(bob), REJECTION, "non-whitelisted liquidator rejected");
    }

    function test_liquidate_gateEnabled_whitelisted_passesGate() public {
        blotroller._setAccessController(address(ac));
        ac.setLiquidatorGateEnabled(true);
        ac.setLiquidator(bob, true);
        assertTrue(_liquidateAllowed(bob) != REJECTION, "whitelisted liquidator passes the gate");
    }

    function test_liquidate_enablingMintGateDoesNotBlockLiquidation() public {
        // Footgun guard: turning on the mint/borrow allowlist must NOT block liquidation,
        // because the liquidator gate is independent and defaults to OFF.
        blotroller._setAccessController(address(ac));
        ac.setAllowed(alice, true); // configure the depositor allowlist only
        assertTrue(_liquidateAllowed(bob) != REJECTION, "mint gate must not block liquidation");
    }
}
