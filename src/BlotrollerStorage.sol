// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./BToken.sol";
import "./PriceOracle.sol";

contract UnitrollerAdminStorage {
    /**
    * @notice Administrator for this contract
    */
    address public admin;

    /**
    * @notice Pending administrator for this contract
    */
    address public pendingAdmin;

    /**
    * @notice Active brains of Unitroller
    */
    address public comptrollerImplementation;

    /**
    * @notice Pending brains of Unitroller
    */
    address public pendingBlotrollerImplementation;
}

contract BlotrollerStorage is UnitrollerAdminStorage {

    /**
     * @notice Oracle which gives the price of any given asset
     */
    PriceOracle public oracle;

    /**
     * @notice Multiplier used to calculate the maximum repayAmount when liquidating a borrow
     */
    uint public closeFactorMantissa;

    /**
     * @notice Multiplier representing the discount on collateral that a liquidator receives
     */
    uint public liquidationIncentiveMantissa;

    /**
     * @notice Max number of assets a single account can participate in (borrow or use as collateral)
     */
    uint public maxAssets;

    /**
     * @notice Per-account mapping of "assets you are in", capped by maxAssets
     */
    mapping(address => BToken[]) public accountAssets;

    struct Market {
        // Whether or not this market is listed
        bool isListed;

        //  LIQUIDATION line (liquidation threshold). Multiplier representing how much debt the
        //  collateral can carry before the position becomes liquidatable. Used ONLY by the
        //  liquidation/shortfall path. Must be between 0 and 1, stored as a mantissa.
        //  (Name kept as `collateralFactorMantissa` for storage/ABI continuity.)
        uint collateralFactorMantissa;

        // Per-market mapping of "accounts in this asset"
        mapping(address => bool) accountMembership;

        //  BORROW line. Multiplier representing the most one can borrow against this collateral
        //  when opening/extending a position. Used ONLY by the borrow/redeem path, never by
        //  liquidation. Invariant: borrowFactorMantissa <= collateralFactorMantissa.
        //  Lowering it only blocks NEW borrows; it can never make an existing position
        //  liquidatable. Appended at the end of the struct for storage-layout safety.
        uint borrowFactorMantissa;
    }

    /**
     * @notice Official mapping of bTokens -> Market metadata
     * @dev Used e.g. to determine if a market is supported
     */
    mapping(address => Market) public markets;

    /**
     * @notice The Pause Guardian can pause certain actions as a safety mechanism.
     *  Actions which allow users to remove their own assets cannot be paused.
     *  Liquidation / seizing / transfer can only be paused globally, not by market.
     */
    address public pauseGuardian;
    bool public _mintGuardianPaused;
    bool public _borrowGuardianPaused;
    bool public transferGuardianPaused;
    bool public seizeGuardianPaused;
    mapping(address => bool) public mintGuardianPaused;
    mapping(address => bool) public borrowGuardianPaused;

    /// @notice A list of all markets
    BToken[] public allMarkets;

    // @notice The borrowCapGuardian can set borrowCaps to any number for any market. Lowering the borrow cap could disable borrowing on the given market.
    address public borrowCapGuardian;

    // @notice Borrow caps enforced by borrowAllowed for each bToken address. Defaults to zero which corresponds to unlimited borrowing.
    mapping(address => uint) public borrowCaps;

    /// @notice Token classification system for A/B borrowing rules
    /// @dev 0 = Type A, 1 = Type B.
    enum TokenType {
        TYPE_A,        // 0: When deposited, can only borrow Type B tokens
        TYPE_B         // 1: When deposited, can only borrow Type A tokens
    }

    /// @notice Mapping of bToken address to its classification type
    mapping(address => TokenType) public tokenTypes;

    /// @notice Whether the A/B separation mode is enabled
    /// @dev When true, A/B tokens have separate liquidity pools
    bool public separationModeEnabled;

    /// @notice Event emitted when a token type is set
    event TokenTypeSet(address indexed bToken, TokenType oldType, TokenType newType);

    /// @notice Event emitted when separation mode is toggled
    event SeparationModeToggled(bool oldMode, bool newMode);

    /// @notice External access controller gating mint (deposit) and borrow.
    /// @dev When set to address(0) the gate is DISABLED — anyone may mint/borrow.
    ///      When set to a non-zero address, Blotroller calls
    ///      IAccessController(accessController).isAllowedToMint/Borrow on every
    ///      mint/borrow and reverts if it returns false.
    address public accessController;

    /// @notice Risk keeper (CF_KEEPER) allowed to LOWER borrowFactor immediately, without timelock.
    /// @dev Fast de-risk path. May only reduce borrowFactor (never raise). Raising borrowFactor and
    ///      any liquidationThreshold change stays admin-only (admin is expected to be a Timelock).
    address public cfKeeper;

    /// @notice Max single-step reduction of a market's liquidationThreshold (collateralFactor), as a mantissa.
    /// @dev Guards against pushing borderline users into shortfall in one move. 0 = unlimited (disabled).
    uint public liquidationThresholdMaxReductionMantissa;

    /// @notice Global borrow haircut set by RISK_KEEPER, driven by overall protocol LTV (spec §10.2).
    uint public keeperHaircutMantissa;

    /// @notice Global borrow haircut set by the GUARDIAN — manual emergency lever (100% = halt all new borrows).
    uint public guardianHaircutMantissa;

    /// @notice RISK_KEEPER: may RAISE keeperHaircut (tighten) immediately; lowering is admin-only.
    address public riskKeeper;
}
