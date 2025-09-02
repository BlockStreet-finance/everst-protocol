// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import "../src/TokenDepositContract.sol";

contract DeployTokenDepositContract is Script {
    function run(address signerAddress) external {
        // 获取部署者私钥
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        // 获取签名者地址（后端服务器地址）
        // address signerAddress = vm.envAddress("SIGNER_ADDRESS");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // 部署合约
        TokenDepositContract depositContract = new TokenDepositContract(signerAddress);
        
        console.log("TokenDepositContract deployed at:", address(depositContract));
        console.log("Admin:", depositContract.admin());
        console.log("Signer:", depositContract.signer());
        console.log("Total deposit count:", depositContract.totalDepositCount());
        
        vm.stopBroadcast();
    }
}
