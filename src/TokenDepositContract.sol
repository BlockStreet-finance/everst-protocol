// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./EIP20Interface.sol";
import "./SafeMath.sol";

/**
 * @title TokenDepositContract
 * @notice 支持MON/ERC20代币存入和提取的合约，适用于Monad测试网络
 * @dev 用户可以存入代币，后端通过签名验证用户提取请求
 */
contract TokenDepositContract {
    using SafeMath for uint256;

    /// @notice 合约管理员
    address public admin;
    
    /// @notice 签名验证地址（后端服务器地址）
    address public signer;
    
    /// @notice 总存入计数
    uint256 public totalDepositCount;
    
    /// @notice 用户存入余额映射 user => token => amount
    mapping(address => mapping(address => uint256)) public userBalances;
    
    /// @notice 用户总存入金额映射 user => token => total_deposited
    mapping(address => mapping(address => uint256)) public userTotalDeposited;
    
    /// @notice 用户nonce映射，防止重放攻击
    mapping(address => uint256) public userNonces;
    
    /// @notice MON代币地址（原生代币用address(0)表示）
    address public constant MON_TOKEN = address(0);

    /// @notice 存入事件
    event Deposit(address indexed user, address indexed token, uint256 amount, uint256 depositCount);
    
    /// @notice 提取事件
    event Withdraw(address indexed user, address indexed token, uint256 amount, uint256 nonce);
    
    /// @notice 管理员变更事件
    event NewAdmin(address oldAdmin, address newAdmin);
    
    /// @notice 签名者变更事件
    event NewSigner(address oldSigner, address newSigner);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }

    constructor(address _signer) {
        admin = msg.sender;
        signer = _signer;
    }

    /**
     * @notice 存入MON代币（原生代币）
     */
    function depositMON() external payable {
        require(msg.value > 0, "Deposit amount must be greater than 0");
        
        userBalances[msg.sender][MON_TOKEN] = userBalances[msg.sender][MON_TOKEN].add(msg.value);
        userTotalDeposited[msg.sender][MON_TOKEN] = userTotalDeposited[msg.sender][MON_TOKEN].add(msg.value);
        totalDepositCount = totalDepositCount.add(1);
        
        emit Deposit(msg.sender, MON_TOKEN, msg.value, totalDepositCount);
    }

    /**
     * @notice 存入ERC20代币
     * @param token ERC20代币合约地址
     * @param amount 存入数量
     */
    function depositERC20(address token, uint256 amount) external {
        require(token != address(0), "Invalid token address");
        require(amount > 0, "Deposit amount must be greater than 0");
        
        EIP20Interface tokenContract = EIP20Interface(token);
        require(tokenContract.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        userBalances[msg.sender][token] = userBalances[msg.sender][token].add(amount);
        userTotalDeposited[msg.sender][token] = userTotalDeposited[msg.sender][token].add(amount);
        totalDepositCount = totalDepositCount.add(1);
        
        emit Deposit(msg.sender, token, amount, totalDepositCount);
    }

    /**
     * @notice 通过签名提取代币
     * @param token 代币地址（MON用address(0)）
     * @param amount 提取数量
     * @param nonce 防重放随机数
     * @param signature 后端签名
     */
    function withdrawWithSignature(
        address token,
        uint256 amount,
        uint256 nonce,
        bytes memory signature
    ) external {
        require(amount > 0, "Withdraw amount must be greater than 0");
        require(userBalances[msg.sender][token] >= amount, "Insufficient balance");
        
        // 创建签名哈希
        bytes32 messageHash = keccak256(abi.encodePacked(
            msg.sender,
            token,
            amount,
            nonce,
            address(this)
        ));
        
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));
        
        // 检查nonce是否有效（必须是用户当前nonce）
        require(nonce == userNonces[msg.sender]+1, "Invalid nonce");
        
        // 验证签名
        require(verifySignature(ethSignedMessageHash, signature), "Invalid signature");
        
        // 递增用户nonce
        userNonces[msg.sender]++;
        
        // 更新余额
        userBalances[msg.sender][token] = userBalances[msg.sender][token].sub(amount);
        
        // 执行转账
        if (token == MON_TOKEN) {
            // 提取MON（原生代币）
            payable(msg.sender).transfer(amount);
        } else {
            // 提取ERC20代币
            EIP20Interface tokenContract = EIP20Interface(token);
            require(tokenContract.transfer(msg.sender, amount), "Transfer failed");
        }
        
        emit Withdraw(msg.sender, token, amount, nonce);
    }

    /**
     * @notice 验证签名
     * @param messageHash 消息哈希
     * @param signature 签名
     * @return 签名是否有效
     */
    function verifySignature(bytes32 messageHash, bytes memory signature) internal view returns (bool) {
        require(signature.length == 65, "Invalid signature length");
        
        bytes32 r;
        bytes32 s;
        uint8 v;
        
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        
        if (v < 27) {
            v += 27;
        }
        
        require(v == 27 || v == 28, "Invalid signature v value");
        
        address recovered = ecrecover(messageHash, v, r, s);
        return recovered == signer;
    }

    /**
     * @notice 查询用户在特定代币的余额
     * @param user 用户地址
     * @param token 代币地址
     * @return 用户余额
     */
    function getUserBalance(address user, address token) external view returns (uint256) {
        return userBalances[user][token];
    }

    /**
     * @notice 查询用户在特定代币的总存入金额
     * @param user 用户地址
     * @param token 代币地址
     * @return 用户总存入金额
     */
    function getUserTotalDeposited(address user, address token) external view returns (uint256) {
        return userTotalDeposited[user][token];
    }

    /**
     * @notice 获取用户当前nonce
     * @param user 用户地址
     * @return 用户当前nonce
     */
    function getUserNonce(address user) external view returns (uint256) {
        return userNonces[user];
    }

    /**
     * @notice 设置新的管理员
     * @param newAdmin 新管理员地址
     */
    function setAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Invalid admin address");
        address oldAdmin = admin;
        admin = newAdmin;
        emit NewAdmin(oldAdmin, newAdmin);
    }

    /**
     * @notice 设置新的签名者
     * @param newSigner 新签名者地址
     */
    function setSigner(address newSigner) external onlyAdmin {
        require(newSigner != address(0), "Invalid signer address");
        address oldSigner = signer;
        signer = newSigner;
        emit NewSigner(oldSigner, newSigner);
    }

    /**
     * @notice 紧急提取合约中的代币（仅管理员）
     * @param token 代币地址
     * @param amount 提取数量
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyAdmin {
        if (token == MON_TOKEN) {
            payable(admin).transfer(amount);
        } else {
            EIP20Interface tokenContract = EIP20Interface(token);
            require(tokenContract.transfer(admin, amount), "Transfer failed");
        }
    }

    /**
     * @notice 获取合约中特定代币的余额
     * @param token 代币地址
     * @return 合约代币余额
     */
    function getContractBalance(address token) external view returns (uint256) {
        if (token == MON_TOKEN) {
            return address(this).balance;
        } else {
            EIP20Interface tokenContract = EIP20Interface(token);
            return tokenContract.balanceOf(address(this));
        }
    }

    /**
     * @notice 接收MON代币的fallback函数
     */
    receive() external payable {
        // 可以接收MON，但不会自动记录为存入
        // 用户需要调用depositMON()函数来正式存入
    }
}
