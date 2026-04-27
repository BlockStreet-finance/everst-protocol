// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "../src/AccessController.sol";

contract AccessControllerTest is Test {
    AccessController internal ac;

    address internal admin = address(0xA11CE);
    address internal alice = address(0xA1);
    address internal bob   = address(0xB0B);
    address internal carol = address(0xCA501);

    event AccessUpdated(address indexed user, bool allowed);
    event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);
    event NewAdmin(address oldAdmin, address newAdmin);

    function setUp() public {
        vm.prank(admin);
        ac = new AccessController();
    }

    function test_adminSetAtDeploy() public {
        assertEq(ac.admin(), admin);
        assertEq(ac.pendingAdmin(), address(0));
    }

    function test_defaultDenied() public {
        assertFalse(ac.allowed(alice));
        assertFalse(ac.isAllowedToMint(alice));
        assertFalse(ac.isAllowedToBorrow(alice));
    }

    function test_setAllowed_grantsMintAndBorrow() public {
        vm.expectEmit(true, false, false, true, address(ac));
        emit AccessUpdated(alice, true);

        vm.prank(admin);
        ac.setAllowed(alice, true);

        assertTrue(ac.allowed(alice));
        assertTrue(ac.isAllowedToMint(alice));
        assertTrue(ac.isAllowedToBorrow(alice));
    }

    function test_setAllowed_revoke() public {
        vm.prank(admin);
        ac.setAllowed(alice, true);
        assertTrue(ac.allowed(alice));

        vm.expectEmit(true, false, false, true, address(ac));
        emit AccessUpdated(alice, false);

        vm.prank(admin);
        ac.setAllowed(alice, false);

        assertFalse(ac.allowed(alice));
        assertFalse(ac.isAllowedToMint(alice));
        assertFalse(ac.isAllowedToBorrow(alice));
    }

    function test_setAllowed_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert(bytes("AccessController: not admin"));
        ac.setAllowed(bob, true);
    }

    function test_setAllowedBatch_grantsAll() public {
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;

        vm.prank(admin);
        ac.setAllowedBatch(users, true);

        assertTrue(ac.isAllowedToMint(alice));
        assertTrue(ac.isAllowedToMint(bob));
        assertTrue(ac.isAllowedToMint(carol));
        assertTrue(ac.isAllowedToBorrow(carol));
    }

    function test_setAllowedBatch_revokesAll() public {
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.startPrank(admin);
        ac.setAllowedBatch(users, true);
        ac.setAllowedBatch(users, false);
        vm.stopPrank();

        assertFalse(ac.isAllowedToMint(alice));
        assertFalse(ac.isAllowedToBorrow(bob));
    }

    function test_setAllowedBatch_onlyAdmin() public {
        address[] memory users = new address[](1);
        users[0] = alice;

        vm.prank(bob);
        vm.expectRevert(bytes("AccessController: not admin"));
        ac.setAllowedBatch(users, true);
    }

    function test_pendingAdminFlow() public {
        vm.expectEmit(false, false, false, true, address(ac));
        emit NewPendingAdmin(address(0), alice);

        vm.prank(admin);
        ac._setPendingAdmin(alice);
        assertEq(ac.pendingAdmin(), alice);

        vm.expectEmit(false, false, false, true, address(ac));
        emit NewAdmin(admin, alice);

        vm.prank(alice);
        ac._acceptAdmin();

        assertEq(ac.admin(), alice);
        assertEq(ac.pendingAdmin(), address(0));
    }

    function test_setPendingAdmin_onlyAdmin() public {
        vm.prank(bob);
        vm.expectRevert(bytes("AccessController: not admin"));
        ac._setPendingAdmin(bob);
    }

    function test_acceptAdmin_onlyPending() public {
        vm.prank(admin);
        ac._setPendingAdmin(alice);

        vm.prank(bob);
        vm.expectRevert(bytes("AccessController: not pending admin"));
        ac._acceptAdmin();
    }
}
