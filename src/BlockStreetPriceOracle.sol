// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "./PriceOracle.sol";
import "./BToken.sol";

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "@pythnetwork/pyth-sdk-solidity/PythUtils.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {Math as OZMath} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title BlockStreetPriceOracle — Pure Pyth price oracle with safety mechanisms
 * @author BlockStreet
 * @notice Provides Pyth-sourced prices for the BlockStreet protocol with
 *         staleness check, confidence check, admin fallback, and per-asset pause.
 */
contract BlockStreetPriceOracle is PriceOracle, Ownable {
    // ================================================================
    // Constants
    // ================================================================

    uint256 private constant INTERNAL_PRICE_DECIMALS = 6;
    uint256 private constant BPS = 10_000;

    // ================================================================
    // Immutables
    // ================================================================

    IPyth public immutable pyth;

    // ================================================================
    // Per-asset configuration
    // ================================================================

    struct AssetConfig {
        address underlying;
        uint256 baseUnit;           // e.g. 1e18 for wtCOIN, 1e6 for USDT
        bytes32 pythPriceId;
        uint32  maxPriceAge;        // staleness threshold (seconds)
        uint16  maxConfidenceRatio; // max confidence/price ratio (bps)
    }

    mapping(address => AssetConfig) public assetConfigs;

    // ================================================================
    // Admin fallback price
    // ================================================================

    struct FallbackPrice {
        uint128 price;
        uint64  timestamp;
    }

    mapping(address => FallbackPrice) public fallbackPrices;
    uint32 public maxFallbackAge;

    // ================================================================
    // Per-asset pause
    // ================================================================

    mapping(address => bool) public paused;

    // ================================================================
    // Events
    // ================================================================

    event AssetConfigUpdated(address indexed bToken, AssetConfig config);
    event FallbackPriceSet(address indexed bToken, uint128 price);
    event FallbackPriceCleared(address indexed bToken);
    event AssetPaused(address indexed bToken);
    event AssetUnpaused(address indexed bToken);
    event MaxFallbackAgeUpdated(uint32 newAge);

    // ================================================================
    // Errors
    // ================================================================

    error OracleMarketNotConfigured(address bToken);
    error OraclePriceNotFound(address bToken);
    error OracleInvalidConfiguration();
    error OracleAssetPaused(address bToken);

    // ================================================================
    // Constructor
    // ================================================================

    constructor(IPyth pythOracle, uint32 initialMaxFallbackAge) Ownable(msg.sender) {
        pyth = pythOracle;
        maxFallbackAge = initialMaxFallbackAge;
    }

    // ================================================================
    // Core: getUnderlyingPrice  (view — called by Blotroller)
    // ================================================================

    /**
     * @notice Returns the underlying price of a bToken, scaled by 1e(36 - underlyingDecimals).
     * @dev Priority: Pyth → admin fallback → revert.
     */
    function getUnderlyingPrice(BToken bToken) external view override returns (uint256) {
        address bTokenAddr = address(bToken);
        AssetConfig memory cfg = assetConfigs[bTokenAddr];

        if (cfg.underlying == address(0)) revert OracleMarketNotConfigured(bTokenAddr);
        if (paused[bTokenAddr]) revert OracleAssetPaused(bTokenAddr);

        // 1. Try Pyth
        uint256 price = _fetchPythPrice(cfg);

        // 2. Fallback to admin price
        if (price == 0) {
            price = _fetchFallbackPrice(bTokenAddr);
        }

        if (price == 0) revert OraclePriceNotFound(bTokenAddr);

        // Scale: internal price (6 dec) → Blotroller expects 1e(36 - underlyingDecimals)
        return OZMath.mulDiv(price, 1e30, cfg.baseUnit);
    }

    // ================================================================
    // Admin: asset configuration
    // ================================================================

    function setAssetConfigs(address[] calldata bTokens, AssetConfig[] calldata configs) external onlyOwner {
        uint256 len = bTokens.length;
        if (len != configs.length) revert OracleInvalidConfiguration();
        for (uint256 i; i < len; ++i) {
            _setAssetConfig(bTokens[i], configs[i]);
        }
    }

    // ================================================================
    // Admin: fallback price
    // ================================================================

    function setFallbackPrice(address bToken, uint128 price) external onlyOwner {
        if (price == 0) revert OracleInvalidConfiguration();
        fallbackPrices[bToken] = FallbackPrice({price: price, timestamp: uint64(block.timestamp)});
        emit FallbackPriceSet(bToken, price);
    }

    function clearFallbackPrice(address bToken) external onlyOwner {
        delete fallbackPrices[bToken];
        emit FallbackPriceCleared(bToken);
    }

    function setMaxFallbackAge(uint32 newAge) external onlyOwner {
        maxFallbackAge = newAge;
        emit MaxFallbackAgeUpdated(newAge);
    }

    // ================================================================
    // Admin: per-asset pause
    // ================================================================

    function pauseAsset(address bToken) external onlyOwner {
        paused[bToken] = true;
        emit AssetPaused(bToken);
    }

    function unpauseAsset(address bToken) external onlyOwner {
        paused[bToken] = false;
        emit AssetUnpaused(bToken);
    }

    // ================================================================
    // Internal: Pyth price fetching
    // ================================================================

    /**
     * @dev Fetches Pyth price with staleness + confidence checks.
     *      Returns 0 on any failure (used in getUnderlyingPrice fallback path).
     */
    function _fetchPythPrice(AssetConfig memory cfg) internal view returns (uint256) {
        if (cfg.pythPriceId == bytes32(0)) return 0;

        try pyth.getPriceNoOlderThan(cfg.pythPriceId, cfg.maxPriceAge) returns (
            PythStructs.Price memory p
        ) {
            if (p.price <= 0) return 0;

            uint256 priceRaw = PythUtils.convertToUint(p.price, p.expo, uint8(INTERNAL_PRICE_DECIMALS));
            uint256 confidence = PythUtils.convertToUint(int64(p.conf), p.expo, uint8(INTERNAL_PRICE_DECIMALS));

            // Confidence ratio check
            if (priceRaw == 0) return 0;
            uint256 confRatio = (confidence * BPS) / priceRaw;
            if (confRatio > cfg.maxConfidenceRatio) return 0;

            return priceRaw;
        } catch {
            return 0;
        }
    }

    // ================================================================
    // Internal: fallback price
    // ================================================================

    function _fetchFallbackPrice(address bToken) internal view returns (uint256) {
        FallbackPrice memory fb = fallbackPrices[bToken];
        if (fb.price == 0) return 0;
        if (maxFallbackAge > 0 && block.timestamp > fb.timestamp + maxFallbackAge) return 0;
        return uint256(fb.price);
    }

    // ================================================================
    // Internal: helpers
    // ================================================================

    function _setAssetConfig(address bToken, AssetConfig calldata cfg) internal {
        if (
            bToken == address(0) ||
            cfg.underlying == address(0) ||
            cfg.baseUnit == 0 ||
            cfg.maxPriceAge == 0
        ) revert OracleInvalidConfiguration();

        if (cfg.maxConfidenceRatio > uint16(BPS)) revert OracleInvalidConfiguration();

        assetConfigs[bToken] = cfg;
        emit AssetConfigUpdated(bToken, cfg);
    }
}
