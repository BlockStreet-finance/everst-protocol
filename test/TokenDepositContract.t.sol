// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "../src/TokenDepositContract.sol";
import "../src/MockERC20.sol";

contract TokenDepositContractTest is Test {
    TokenDepositContract public depositContract;
    MockERC20 public mockToken;
    
    address public admin = address(0x1);
    address public signer = address(0x2);
    address public user = address(0x3);
    address public user2 = address(0x4);
    
    uint256 public signerPrivateKey = 0x2;
    
    function setUp() public {
        vm.startPrank(admin);
        depositContract = new TokenDepositContract(signer);
        mockToken = new MockERC20("Test Token", "TEST", 18, 1000000000000000000);
        vm.stopPrank();
        
        // 给用户分配一些测试代币
        vm.deal(user, 10 ether);
        vm.deal(user2, 10 ether);
        
        mockToken.mint(user, 1000e18);
        mockToken.mint(user2, 1000e18);
    }
    
    function testDepositMON() public {
        vm.startPrank(user);
        
        uint256 depositAmount = 1 ether;
        uint256 initialCount = depositContract.totalDepositCount();
        
        depositContract.depositMON{value: depositAmount}();
        
        assertEq(depositContract.getUserBalance(user, address(0)), depositAmount);
        assertEq(depositContract.getUserTotalDeposited(user, address(0)), depositAmount);
        assertEq(depositContract.totalDepositCount(), initialCount + 1);
        
        vm.stopPrank();
    }
    
    function testDepositERC20() public {
        vm.startPrank(user);
        
        uint256 depositAmount = 100e18;
        mockToken.approve(address(depositContract), depositAmount);
        
        uint256 initialCount = depositContract.totalDepositCount();
        
        depositContract.depositERC20(address(mockToken), depositAmount);
        
        assertEq(depositContract.getUserBalance(user, address(mockToken)), depositAmount);
        assertEq(depositContract.getUserTotalDeposited(user, address(mockToken)), depositAmount);
        assertEq(depositContract.totalDepositCount(), initialCount + 1);
        assertEq(mockToken.balanceOf(address(depositContract)), depositAmount);
        
        vm.stopPrank();
    }
    
    function testWithdrawMONWithValidSignature() public {
        // 首先存入一些MON
        vm.startPrank(user);
        uint256 depositAmount = 2 ether;
        depositContract.depositMON{value: depositAmount}();
        vm.stopPrank();
        
        // 准备提取
        uint256 withdrawAmount = 1 ether;
        uint256 nonce = depositContract.getUserNonce(user); // 使用当前用户nonce
        
        // 创建签名
        bytes32 messageHash = keccak256(abi.encodePacked(
            user,
            address(0), // MON token
            withdrawAmount,
            nonce,
            address(depositContract)
        ));
        
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        // 执行提取
        vm.startPrank(user);
        uint256 userBalanceBefore = user.balance;
        
        depositContract.withdrawWithSignature(address(0), withdrawAmount, nonce, signature);
        
        assertEq(depositContract.getUserBalance(user, address(0)), depositAmount - withdrawAmount);
        assertEq(user.balance, userBalanceBefore + withdrawAmount);
        assertEq(depositContract.getUserNonce(user), nonce + 1); // nonce应该递增
        
        vm.stopPrank();
    }
    
    function testWithdrawERC20WithValidSignature() public {
        // 首先存入一些ERC20代币
        vm.startPrank(user);
        uint256 depositAmount = 200e18;
        mockToken.approve(address(depositContract), depositAmount);
        depositContract.depositERC20(address(mockToken), depositAmount);
        vm.stopPrank();
        
        // 准备提取
        uint256 withdrawAmount = 100e18;
        uint256 nonce = depositContract.getUserNonce(user); // 使用当前用户nonce
        
        // 创建签名
        bytes32 messageHash = keccak256(abi.encodePacked(
            user,
            address(mockToken),
            withdrawAmount,
            nonce,
            address(depositContract)
        ));
        
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        // 执行提取
        vm.startPrank(user);
        uint256 userTokenBalanceBefore = mockToken.balanceOf(user);
        
        depositContract.withdrawWithSignature(address(mockToken), withdrawAmount, nonce, signature);
        
        assertEq(depositContract.getUserBalance(user, address(mockToken)), depositAmount - withdrawAmount);
        assertEq(mockToken.balanceOf(user), userTokenBalanceBefore + withdrawAmount);
        assertEq(depositContract.getUserNonce(user), nonce + 1); // nonce应该递增
        
        vm.stopPrank();
    }
    
    function testWithdrawFailsWithInvalidSignature() public {
        // 首先存入一些MON
        vm.startPrank(user);
        uint256 depositAmount = 2 ether;
        depositContract.depositMON{value: depositAmount}();
        vm.stopPrank();
        
        // 使用错误的签名者私钥
        uint256 wrongPrivateKey = 0x999;
        uint256 withdrawAmount = 1 ether;
        uint256 nonce = depositContract.getUserNonce(user); // 使用当前用户nonce
        
        bytes32 messageHash = keccak256(abi.encodePacked(
            user,
            address(0),
            withdrawAmount,
            nonce,
            address(depositContract)
        ));
        
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        // 应该失败
        vm.startPrank(user);
        vm.expectRevert("Invalid signature");
        depositContract.withdrawWithSignature(address(0), withdrawAmount, nonce, signature);
        vm.stopPrank();
    }
    
    function testWithdrawFailsWithInsufficientBalance() public {
        // 尝试提取超过余额的金额
        uint256 withdrawAmount = 1 ether;
        uint256 nonce = depositContract.getUserNonce(user); // 使用当前用户nonce
        
        bytes32 messageHash = keccak256(abi.encodePacked(
            user,
            address(0),
            withdrawAmount,
            nonce,
            address(depositContract)
        ));
        
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.startPrank(user);
        vm.expectRevert("Insufficient balance");
        depositContract.withdrawWithSignature(address(0), withdrawAmount, nonce, signature);
        vm.stopPrank();
    }
    
    function testNonceReplayProtection() public {
        // 首先存入一些MON
        vm.startPrank(user);
        uint256 depositAmount = 3 ether;
        depositContract.depositMON{value: depositAmount}();
        vm.stopPrank();
        
        uint256 withdrawAmount = 1 ether;
        uint256 nonce = depositContract.getUserNonce(user); // 获取当前nonce
        
        bytes32 messageHash = keccak256(abi.encodePacked(
            user,
            address(0),
            withdrawAmount,
            nonce,
            address(depositContract)
        ));
        
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.startPrank(user);
        
        // 第一次提取应该成功
        depositContract.withdrawWithSignature(address(0), withdrawAmount, nonce, signature);
        
        // 第二次使用相同nonce应该失败（因为nonce已经递增）
        vm.expectRevert("Invalid nonce");
        depositContract.withdrawWithSignature(address(0), withdrawAmount, nonce, signature);
        
        vm.stopPrank();
    }
    
    function testWithdrawFailsWithWrongNonce() public {
        // 首先存入一些MON
        vm.startPrank(user);
        uint256 depositAmount = 2 ether;
        depositContract.depositMON{value: depositAmount}();
        vm.stopPrank();
        
        uint256 withdrawAmount = 1 ether;
        uint256 wrongNonce = depositContract.getUserNonce(user) + 1; // 使用错误的nonce
        
        bytes32 messageHash = keccak256(abi.encodePacked(
            user,
            address(0),
            withdrawAmount,
            wrongNonce,
            address(depositContract)
        ));
        
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        // 应该失败
        vm.startPrank(user);
        vm.expectRevert("Invalid nonce");
        depositContract.withdrawWithSignature(address(0), withdrawAmount, wrongNonce, signature);
        vm.stopPrank();
    }
    
    function testAdminFunctions() public {
        vm.startPrank(admin);
        
        // 测试设置新管理员
        address newAdmin = address(0x5);
        depositContract.setAdmin(newAdmin);
        assertEq(depositContract.admin(), newAdmin);
        
        // 测试设置新签名者
        address newSigner = address(0x6);
        depositContract.setSigner(newSigner);
        assertEq(depositContract.signer(), newSigner);
        
        vm.stopPrank();
    }
    
    function testEmergencyWithdraw() public {
        // 先存入一些代币到合约
        vm.startPrank(user);
        uint256 depositAmount = 2 ether;
        depositContract.depositMON{value: depositAmount}();
        
        uint256 tokenDepositAmount = 100e18;
        mockToken.approve(address(depositContract), tokenDepositAmount);
        depositContract.depositERC20(address(mockToken), tokenDepositAmount);
        vm.stopPrank();
        
        vm.startPrank(admin);
        
        // 紧急提取MON
        uint256 adminBalanceBefore = admin.balance;
        depositContract.emergencyWithdraw(address(0), 1 ether);
        assertEq(admin.balance, adminBalanceBefore + 1 ether);
        
        // 紧急提取ERC20
        uint256 adminTokenBalanceBefore = mockToken.balanceOf(admin);
        depositContract.emergencyWithdraw(address(mockToken), 50e18);
        assertEq(mockToken.balanceOf(admin), adminTokenBalanceBefore + 50e18);
        
        vm.stopPrank();
    }
    
    function testGetContractBalance() public {
        // 存入一些代币
        vm.startPrank(user);
        uint256 monAmount = 2 ether;
        depositContract.depositMON{value: monAmount}();
        
        uint256 tokenAmount = 100e18;
        mockToken.approve(address(depositContract), tokenAmount);
        depositContract.depositERC20(address(mockToken), tokenAmount);
        vm.stopPrank();
        
        // 检查合约余额
        assertEq(depositContract.getContractBalance(address(0)), monAmount);
        assertEq(depositContract.getContractBalance(address(mockToken)), tokenAmount);
    }
    
    function testDepositZeroAmount() public {
        vm.startPrank(user);
        
        // MON存入0应该失败
        vm.expectRevert("Deposit amount must be greater than 0");
        depositContract.depositMON{value: 0}();
        
        // ERC20存入0应该失败
        vm.expectRevert("Deposit amount must be greater than 0");
        depositContract.depositERC20(address(mockToken), 0);
        
        vm.stopPrank();
    }
    
    function testNonAdminCannotCallAdminFunctions() public {
        vm.startPrank(user);
        
        vm.expectRevert("Only admin can call this function");
        depositContract.setAdmin(address(0x5));
        
        vm.expectRevert("Only admin can call this function");
        depositContract.setSigner(address(0x6));
        
        vm.expectRevert("Only admin can call this function");
        depositContract.emergencyWithdraw(address(0), 1 ether);
        
        vm.stopPrank();
    }
}
