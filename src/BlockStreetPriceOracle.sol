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
 * @title BlockStreetPriceOracle
 * @author BlockStreet
 * @notice Pure-Pyth, session-aware price oracle for tokenized US-equity markets
 *         (stock-risk-control-spec §3). Replaces the Chainlink+Pyth BloPriceOracle.
 *
 * @dev Price selection per asset, on every call (spec §3 three tiers, strategy B):
 *   1. EQUITY  — among the per-session equity feeds (regular/PRE/POST/ON), pick the
 *                freshest one that passes validity. Each feed only updates inside its
 *                own session, so "freshest valid" == "whichever session is live".
 *                No session keeper needed.
 *   2. PROXY   — if no equity feed is valid (true market close), fall back to the
 *                24/7 tokenized xStock feed, but only if its redemption-rate (RR) gate
 *                passes. The result is flagged as a proxy so the liquidation path can
 *                apply extra guardrails (§7). Some stocks have no xStock -> no tier 2.
 *   3. NONE    — nothing valid -> return 0 (NEVER revert). The Blotroller reads 0 as
 *                "no price" and blocks price-dependent ops while leaving repay / no-debt
 *                redeem untouched (spec §3.1, invariants #2/#3).
 *
 * Validity (spec §3.1): publishTime age <= maxPriceAge, price > 0, and conf/price within
 * maxConfBps. RR gate (optional): redemption rate within [rrLowerMantissa, rrUpperMantissa].
 *
 * Returned scale matches the Compound/Blotroller convention: price * 1e(36 - underlyingDecimals).
 */
contract BlockStreetPriceOracle is PriceOracle, Ownable {
    /// @notice Common internal precision: all Pyth prices are normalized to 18 decimals
    ///         before comparison/scaling.
    uint8 private constant INTERNAL_DECIMALS = 18;
    uint256 private constant ONE = 1e18;

    /// @notice The Pyth on-chain contract.
    IPyth public immutable pyth;

    /// @notice Price source tier of the last selection (for observability / liquidation guardrails).
    enum Tier { NONE, EQUITY, PROXY }

    /// @notice Per-market price configuration.
    struct AssetConfig {
        // 10^underlyingDecimals — used to scale into the Blotroller's 1e(36-decimals) format.
        uint256 baseUnit;
        // Session-split equity feeds (regular/PRE/POST/ON), any order. Freshest valid wins.
        bytes32[] equityFeeds;
        // 24/7 tokenized xStock fallback feed, or bytes32(0) if the stock has none.
        bytes32 proxyFeed;
        // Redemption-rate feed gating the proxy, or bytes32(0) to skip the RR gate.
        bytes32 rrFeed;
        // Max staleness (seconds) for any feed to count as valid.
        uint256 maxPriceAge;
        // Max confidence/price ratio in bps (e.g. 50 = 0.5%). 0 disables the conf check.
        uint256 maxConfBps;
        // Accepted RR band, as 1e18 mantissas (e.g. 0.98e18 .. 1.02e18). Used only if rrFeed set.
        uint256 rrLowerMantissa;
        uint256 rrUpperMantissa;
    }

    mapping(address => AssetConfig) internal configs;

    event MarketOracleConfigUpdated(address indexed bToken, AssetConfig config);

    error OracleInvalidConfiguration();

    constructor(IPyth pythContract) Ownable(msg.sender) {
        pyth = pythContract;
    }

    // ----------------------------------------------------------------------
    // PriceOracle interface
    // ----------------------------------------------------------------------

    /// @inheritdoc PriceOracle
    /// @return price scaled by 1e(36 - underlyingDecimals), or 0 if no valid price ("no price").
    function getUnderlyingPrice(BToken bToken) external view override returns (uint256) {
        (uint256 price18, , ) = _selectPrice(address(bToken));
        if (price18 == 0) return 0;
        return OZMath.mulDiv(price18, ONE, configs[address(bToken)].baseUnit);
    }

    // ----------------------------------------------------------------------
    // Extended views (for liquidation guardrails / observability)
    // ----------------------------------------------------------------------

    /// @notice Full price selection result for a market.
    /// @return scaledPrice price in Blotroller format (0 if none), isProxy whether tier-2
    ///         proxy was used (liquidation should apply de-peg guardrails), tier the source tier.
    function getPriceDetails(address bToken)
        external
        view
        returns (uint256 scaledPrice, bool isProxy, Tier tier)
    {
        uint256 price18;
        (price18, isProxy, tier) = _selectPrice(bToken);
        scaledPrice = price18 == 0 ? 0 : OZMath.mulDiv(price18, ONE, configs[bToken].baseUnit);
    }

    /// @notice Whether the current price for a market comes from the xStock proxy (tier 2).
    function isProxyPrice(address bToken) external view returns (bool) {
        (, bool isProxy, ) = _selectPrice(bToken);
        return isProxy;
    }

    function getConfig(address bToken) external view returns (AssetConfig memory) {
        return configs[bToken];
    }

    // ----------------------------------------------------------------------
    // Selection logic
    // ----------------------------------------------------------------------

    function _selectPrice(address bToken)
        internal
        view
        returns (uint256 price18, bool isProxy, Tier tier)
    {
        AssetConfig storage cfg = configs[bToken];
        if (cfg.baseUnit == 0) return (0, false, Tier.NONE); // unconfigured -> no price (not a revert)

        // Tier 1: freshest valid equity session feed.
        uint256 bestPrice;
        uint256 bestTime;
        bool found;
        bytes32[] storage feeds = cfg.equityFeeds;
        for (uint256 i = 0; i < feeds.length; i++) {
            (bool ok, uint256 p18, uint256 publishTime) = _readValid(feeds[i], cfg.maxPriceAge, cfg.maxConfBps);
            if (ok && (!found || publishTime > bestTime)) {
                found = true;
                bestTime = publishTime;
                bestPrice = p18;
            }
        }
        if (found) return (bestPrice, false, Tier.EQUITY);

        // Tier 2: 24/7 xStock proxy, gated by the redemption rate.
        if (cfg.proxyFeed != bytes32(0)) {
            (bool ok, uint256 p18, ) = _readValid(cfg.proxyFeed, cfg.maxPriceAge, cfg.maxConfBps);
            if (ok && _rrOk(cfg)) return (p18, true, Tier.PROXY);
        }

        // Tier 3: no valid price.
        return (0, false, Tier.NONE);
    }

    /// @dev Reads a feed and applies the §3.1 validity checks. Never reverts.
    function _readValid(bytes32 feedId, uint256 maxPriceAge, uint256 maxConfBps)
        internal
        view
        returns (bool ok, uint256 price18, uint256 publishTime)
    {
        if (feedId == bytes32(0)) return (false, 0, 0);
        try pyth.getPriceUnsafe(feedId) returns (PythStructs.Price memory p) {
            if (p.price <= 0) return (false, 0, 0);
            if (block.timestamp > p.publishTime && block.timestamp - p.publishTime > maxPriceAge) {
                return (false, 0, 0);
            }
            uint256 px = PythUtils.convertToUint(p.price, p.expo, INTERNAL_DECIMALS);
            if (px == 0) return (false, 0, 0);
            if (maxConfBps != 0) {
                uint256 conf = PythUtils.convertToUint(int64(p.conf), p.expo, INTERNAL_DECIMALS);
                if ((conf * 10_000) / px > maxConfBps) return (false, 0, 0);
            }
            return (true, px, p.publishTime);
        } catch {
            return (false, 0, 0);
        }
    }

    /// @dev Redemption-rate gate for the proxy. True if no RR feed is configured.
    function _rrOk(AssetConfig storage cfg) internal view returns (bool) {
        if (cfg.rrFeed == bytes32(0)) return true;
        try pyth.getPriceUnsafe(cfg.rrFeed) returns (PythStructs.Price memory p) {
            if (p.price <= 0) return false;
            if (block.timestamp > p.publishTime && block.timestamp - p.publishTime > cfg.maxPriceAge) {
                return false;
            }
            uint256 rr = PythUtils.convertToUint(p.price, p.expo, INTERNAL_DECIMALS);
            return rr >= cfg.rrLowerMantissa && rr <= cfg.rrUpperMantissa;
        } catch {
            return false;
        }
    }

    // ----------------------------------------------------------------------
    // Admin
    // ----------------------------------------------------------------------

    function setAssetConfig(address bToken, AssetConfig calldata config) external onlyOwner {
        _setAssetConfig(bToken, config);
    }

    function setAssetConfigs(address[] calldata bTokens, AssetConfig[] calldata cfgs) external onlyOwner {
        if (bTokens.length != cfgs.length) revert OracleInvalidConfiguration();
        for (uint256 i = 0; i < bTokens.length; i++) {
            _setAssetConfig(bTokens[i], cfgs[i]);
        }
    }

    function _setAssetConfig(address bToken, AssetConfig calldata config) internal {
        if (
            bToken == address(0) ||
            config.baseUnit == 0 ||
            config.maxPriceAge == 0 ||
            (config.equityFeeds.length == 0 && config.proxyFeed == bytes32(0))
        ) {
            revert OracleInvalidConfiguration();
        }
        // If an RR gate is set, the band must be sane.
        if (config.rrFeed != bytes32(0) && config.rrLowerMantissa > config.rrUpperMantissa) {
            revert OracleInvalidConfiguration();
        }
        configs[bToken] = config;
        emit MarketOracleConfigUpdated(bToken, config);
    }
}
