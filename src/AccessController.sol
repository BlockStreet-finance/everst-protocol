// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

interface IAccessController {
    function isAllowedToMint(address user) external view returns (bool);
    function isAllowedToBorrow(address user) external view returns (bool);
    function isAllowedToLiquidate(address liquidator) external view returns (bool);
}

/**
 * @title AccessController
 * @notice Gates who can mint (deposit) and borrow on BlockStreet markets.
 *         The initial implementation is a simple admin-managed allowlist;
 *         future versions can plug in KYC providers, Merkle proofs,
 *         NFT-gated access, etc. without touching the Blotroller.
 *
 *         To disable the gate entirely, set `Blotroller.accessController`
 *         to address(0) via `Blotroller._setAccessController(address(0))` —
 *         Blotroller skips all gating when the configured controller is the
 *         zero address, so any user may mint/borrow.
 *
 * @dev    Design decision — for the borrower/depositor side, only mint and borrow
 *         are gated. redeem, repay, and transfer (of bTokens) are intentionally
 *         NOT gated. Rationale:
 *           - Users who were allowlisted and later removed (or who were
 *             present before the gate was enabled) must always be able to
 *             EXIT their positions: withdraw collateral (redeem), repay
 *             debt (repay). Gating these would let a controller mis-configuration
 *             trap user funds, a solvency risk for the whole protocol.
 *           - bToken transfers are not gated for the same reason.
 *         The depositor/borrower gate is therefore an ENTRY control (onboarding
 *         new exposure), not a full asset-freeze mechanism.
 *
 *         Liquidation is a SEPARATE role (spec §7.1): liquidation calls may be
 *         restricted to whitelisted partners via `isAllowedToLiquidate`. This
 *         gates WHO performs a liquidation, not whether an unhealthy position
 *         CAN be liquidated — so it does not trap borrowers. It uses its own
 *         `liquidators` list and an independent `liquidatorGateEnabled` toggle
 *         (default OFF = anyone may liquidate), so enabling the mint/borrow
 *         allowlist never accidentally blocks liquidations.
 */
contract AccessController is IAccessController {
    address public admin;
    address public pendingAdmin;

    mapping(address => bool) public allowed;

    /// @notice Whitelist of addresses permitted to perform liquidations (spec §7.1).
    mapping(address => bool) public liquidators;

    /// @notice When false (default) the liquidator whitelist is bypassed — anyone may
    ///         liquidate. Enable it to restrict liquidation to whitelisted partners.
    bool public liquidatorGateEnabled;

    event AccessUpdated(address indexed user, bool allowed);
    event LiquidatorUpdated(address indexed liquidator, bool allowed);
    event LiquidatorGateToggled(bool enabled);
    event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);
    event NewAdmin(address oldAdmin, address newAdmin);

    modifier onlyAdmin() {
        require(msg.sender == admin, "AccessController: not admin");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    function isAllowedToMint(address user) external view override returns (bool) {
        return allowed[user];
    }

    function isAllowedToBorrow(address user) external view override returns (bool) {
        return allowed[user];
    }

    /// @notice Anyone may liquidate while the gate is off; otherwise only whitelisted liquidators.
    function isAllowedToLiquidate(address liquidator) external view override returns (bool) {
        return !liquidatorGateEnabled || liquidators[liquidator];
    }

    function setAllowed(address user, bool isAllowed) external onlyAdmin {
        allowed[user] = isAllowed;
        emit AccessUpdated(user, isAllowed);
    }

    function setLiquidator(address liquidator, bool isAllowed) external onlyAdmin {
        liquidators[liquidator] = isAllowed;
        emit LiquidatorUpdated(liquidator, isAllowed);
    }

    function setLiquidatorBatch(address[] calldata accounts, bool isAllowed) external onlyAdmin {
        for (uint256 i = 0; i < accounts.length; i++) {
            liquidators[accounts[i]] = isAllowed;
            emit LiquidatorUpdated(accounts[i], isAllowed);
        }
    }

    function setLiquidatorGateEnabled(bool enabled) external onlyAdmin {
        liquidatorGateEnabled = enabled;
        emit LiquidatorGateToggled(enabled);
    }

    function setAllowedBatch(address[] calldata users, bool isAllowed) external onlyAdmin {
        for (uint256 i = 0; i < users.length; i++) {
            allowed[users[i]] = isAllowed;
            emit AccessUpdated(users[i], isAllowed);
        }
    }

    function _setPendingAdmin(address newPendingAdmin) external onlyAdmin {
        address old = pendingAdmin;
        pendingAdmin = newPendingAdmin;
        emit NewPendingAdmin(old, newPendingAdmin);
    }

    function _acceptAdmin() external {
        require(msg.sender == pendingAdmin && msg.sender != address(0), "AccessController: not pending admin");
        address old = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit NewAdmin(old, admin);
    }
}
