// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

interface IAccessController {
    function isAllowedToMint(address user) external view returns (bool);
    function isAllowedToBorrow(address user) external view returns (bool);
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
 * @dev    Design decision — only mint and borrow are gated. redeem, repay,
 *         transfer (of bTokens), and seize (liquidation) are intentionally
 *         NOT gated. Rationale:
 *           - Users who were allowlisted and later removed (or who were
 *             present before the gate was enabled) must always be able to
 *             EXIT their positions: withdraw collateral (redeem), repay
 *             debt (repay), and have unhealthy positions liquidated (seize).
 *             Gating these would let a controller mis-configuration trap
 *             user funds or prevent liquidations, which is a solvency risk
 *             for the whole protocol.
 *           - bToken transfers are not gated for the same reason: existing
 *             holders must be able to move their positions out even if the
 *             allowlist later excludes them.
 *         The gate is therefore an ENTRY control (onboarding new exposure),
 *         not a full asset-freeze mechanism. If a full freeze is needed,
 *         use the existing pause guardian (`*GuardianPaused`) instead.
 */
contract AccessController is IAccessController {
    address public admin;
    address public pendingAdmin;

    mapping(address => bool) public allowed;

    event AccessUpdated(address indexed user, bool allowed);
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

    function setAllowed(address user, bool isAllowed) external onlyAdmin {
        allowed[user] = isAllowed;
        emit AccessUpdated(user, isAllowed);
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
