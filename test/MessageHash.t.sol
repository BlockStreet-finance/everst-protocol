// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";

contract MessageHashTest is Test {
    
    function testCalculateMessageHash() public {
        // 参数值
        address msgSender = 0xC8724EDDB741B2BeBeBe7AAf2cb2c51300000000;
        address token = 0x0000000000000000000000000000000000000000;
        uint256 amount = 100000000000000000; // 0.1 ETH in wei
        uint256 nonce = 1;
        uint256 timestamp = 1756896049;
        address contractAddress = 0x91a33b604565958101c786fE5ddB8AE4c67cE2e6;
        
        // 计算messageHash (使用abi.encodePacked)
        bytes memory messageHashen = abi.encodePacked(
            msgSender,
            token,
            amount,
            nonce,
            timestamp,
            contractAddress
        );
        console.log("messageHashen:");
        console.logBytes(messageHashen);
        bytes32 messageHash = keccak256(messageHashen);
        
        console.log("Parameters:");
        console.log("msg.sender:", msgSender);
        console.log("token:", token);
        console.log("amount:", amount);
        console.log("nonce:", nonce);
        console.log("timestamp:", timestamp);
        console.log("contract address:", contractAddress);
        console.log("\nCalculated messageHash:");
        console.logBytes32(messageHash);
    }
}
