// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./BToken.sol";
import "./ErrorReporter.sol";
import "./PriceOracle.sol";
import "./BlotrollerInterface.sol";
import "./BlotrollerStorage.sol";
import "./Unitroller.sol";
import "./AccessController.sol";

/**
 * @title BlockStreet's Blotroller Contract
 * @author BlockStreet
 */
contract Blotroller is BlotrollerStorage, BlotrollerInterface, BlotrollerErrorReporter, ExponentialNoError {
    /// @notice Emitted when an admin supports a market
    event MarketListed(BToken bToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(BToken bToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(BToken bToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(uint oldCloseFactorMantissa, uint newCloseFactorMantissa);

    /// @notice Emitted when a collateral factor (liquidation threshold) is changed by admin
    event NewCollateralFactor(BToken bToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);

    /// @notice Emitted when a market's borrow factor (borrow line) is changed
    event NewBorrowFactor(BToken bToken, uint oldBorrowFactorMantissa, uint newBorrowFactorMantissa);

    /// @notice Emitted when the CF keeper (fast borrowFactor de-risk role) is changed
    event NewCfKeeper(address oldCfKeeper, address newCfKeeper);

    /// @notice Emitted when the liquidation threshold max single-step reduction is changed
    event NewLiquidationThresholdMaxReduction(uint oldMantissa, uint newMantissa);

    /// @notice Emitted when the keeper global borrow haircut changes
    event NewKeeperHaircut(uint oldMantissa, uint newMantissa);

    /// @notice Emitted when the guardian global borrow haircut changes
    event NewGuardianHaircut(uint oldMantissa, uint newMantissa);

    /// @notice Emitted when the risk keeper address changes
    event NewRiskKeeper(address oldRiskKeeper, address newRiskKeeper);

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused globally
    event ActionPaused(string action, bool pauseState);

    /// @notice Emitted when an action is paused on a market
    event ActionPaused(BToken bToken, string action, bool pauseState);


    /// @notice Emitted when borrow cap for a bToken is changed
    event NewBorrowCap(BToken indexed bToken, uint newBorrowCap);

    /// @notice Emitted when borrow cap guardian is changed
    event NewBorrowCapGuardian(address oldBorrowCapGuardian, address newBorrowCapGuardian);

    /// @notice Emitted when the access controller is changed
    event NewAccessController(address oldAccessController, address newAccessController);

    // closeFactorMantissa must be strictly greater than this value
    uint internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa must not exceed this value
    uint internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // No collateralFactorMantissa may exceed this value
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    constructor() {
        admin = msg.sender;
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account) external view returns (BToken[] memory) {
        BToken[] memory assetsIn = accountAssets[account];

        return assetsIn;
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param bToken The bToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(address account, BToken bToken) external view returns (bool) {
        return markets[address(bToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param bTokens The list of addresses of the bToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(address[] memory bTokens) override public returns (uint[] memory) {
        uint len = bTokens.length;

        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            BToken bToken = BToken(bTokens[i]);

            results[i] = uint(addToMarketInternal(bToken, msg.sender));
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param bToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(BToken bToken, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(bToken)];

        if (!marketToJoin.isListed) {
            // market is not listed, cannot join
            return Error.MARKET_NOT_LISTED;
        }

        if (marketToJoin.accountMembership[borrower] == true) {
            // already joined
            return Error.NO_ERROR;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(bToken);

        emit MarketEntered(bToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param bTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(address bTokenAddress) override external returns (uint) {
        BToken bToken = BToken(bTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the bToken */
        (uint oErr, uint tokensHeld, uint amountOwed, ) = bToken.getAccountSnapshot(msg.sender);
        require(oErr == 0, "exitMarket: getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint allowed = redeemAllowedInternal(bTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[address(bToken)];

        /* Return true if the sender is not already ‘in’ the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        /* Set bToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete bToken from the account’s list of assets */
        // load into memory for faster iteration
        BToken[] memory userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == bToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        BToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();

        emit MarketExited(bToken, msg.sender);

        return uint(Error.NO_ERROR);
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param bToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(address bToken, address minter, uint mintAmount) override external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintGuardianPaused[bToken], "mint is paused");

        // Shh - currently unused
        mintAmount;

        if (!markets[bToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Access gate: address(0) means the gate is disabled and anyone may mint.
        address _accessController = accessController;
        if (_accessController != address(0) && !IAccessController(_accessController).isAllowedToMint(minter)) {
            return uint(Error.REJECTION);
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param bToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(address bToken, address minter, uint actualMintAmount, uint mintTokens) override external {
        // Shh - currently unused
        bToken;
        minter;
        actualMintAmount;
        mintTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param bToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of bTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(address bToken, address redeemer, uint redeemTokens) override external returns (uint) {
        uint allowed = redeemAllowedInternal(bToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }



        return uint(Error.NO_ERROR);
    }

    function redeemAllowedInternal(address bToken, address redeemer, uint redeemTokens) internal view returns (uint) {
        if (!markets[bToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[bToken].accountMembership[redeemer]) {
            return uint(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        if (separationModeEnabled) {
            // Get token type being redeemed
            TokenType redeemTokenType = tokenTypes[bToken];
            
            (Error err, , uint shortfallA, , uint shortfallB) =
                getHypotheticalAccountLiquidityInternalSeparated(redeemer, BToken(bToken), redeemTokens, 0, RiskMode.BORROW);

            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            // Withdrawing collateral is checked on the line that collateral secures:
            // Type A collateral supports Type B borrowing -> line A (shortfallA)
            // Type B collateral supports Type A borrowing -> line B (shortfallB)
            if (redeemTokenType == TokenType.TYPE_A) {
                if (shortfallA > 0) {
                    return uint(Error.INSUFFICIENT_LIQUIDITY);
                }
            } else if (redeemTokenType == TokenType.TYPE_B) {
                if (shortfallB > 0) {
                    return uint(Error.INSUFFICIENT_LIQUIDITY);
                }
            }
            // UNCLASSIFIED collateral is counted on neither line, so withdrawing it cannot
            // open a shortfall on either -- freely redeemable.
        } else {
            // Original logic for non-separation mode
            (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, BToken(bToken), redeemTokens, 0, RiskMode.BORROW);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }
            if (shortfall > 0) {
                return uint(Error.INSUFFICIENT_LIQUIDITY);
            }
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param bToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(address bToken, address redeemer, uint redeemAmount, uint redeemTokens) override external {
        // Shh - currently unused
        bToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        if (redeemTokens == 0 && redeemAmount > 0) {
            revert("redeemTokens zero");
        }
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param bToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(address bToken, address borrower, uint borrowAmount) override external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!borrowGuardianPaused[bToken], "borrow is paused");

        if (!markets[bToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Access gate: address(0) means the gate is disabled and anyone may borrow.
        address _accessController = accessController;
        if (_accessController != address(0) && !IAccessController(_accessController).isAllowedToBorrow(borrower)) {
            return uint(Error.REJECTION);
        }

        if (!markets[bToken].accountMembership[borrower]) {
            // only bTokens may call borrowAllowed if borrower not in market
            require(msg.sender == bToken, "sender must be bToken");

            // attempt to add borrower to the market
            Error err = addToMarketInternal(BToken(msg.sender), borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            // it should be impossible to break the important invariant
            assert(markets[bToken].accountMembership[borrower]);
        }

        if (oracle.getUnderlyingPrice(BToken(bToken)) == 0) {
            return uint(Error.PRICE_ERROR);
        }


        uint borrowCap = borrowCaps[bToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint totalBorrows = BToken(bToken).totalBorrows();
            uint nextTotalBorrows = add_(totalBorrows, borrowAmount);
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }

        // Check liquidity based on separation mode
        if (separationModeEnabled) {
            // Get token type being borrowed
            TokenType borrowTokenType = tokenTypes[bToken];
            
            // An unclassified market belongs to neither line, so nothing can secure a debt
            // taken out in it.
            if (borrowTokenType == TokenType.UNCLASSIFIED) {
                return uint(Error.REJECTION);
            }
            
            (Error err, uint liquidityA, uint shortfallA, uint liquidityB, uint shortfallB) =
                getHypotheticalAccountLiquidityInternalSeparated(borrower, BToken(bToken), 0, borrowAmount, RiskMode.BORROW);
            
            if (err != Error.NO_ERROR) {
                return uint(err);
            }
            
            // Type A tokens can only be borrowed with Type B collateral
            // Type B tokens can only be borrowed with Type A collateral
            if (borrowTokenType == TokenType.TYPE_A) {
                if (shortfallB > 0) {
                    return uint(Error.INSUFFICIENT_LIQUIDITY);
                }
            } else if (borrowTokenType == TokenType.TYPE_B) {
                if (shortfallA > 0) {
                    return uint(Error.INSUFFICIENT_LIQUIDITY);
                }
            }
        } else {
            // Original logic for non-separation mode
            (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, BToken(bToken), 0, borrowAmount, RiskMode.BORROW);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }
            if (shortfall > 0) {
                return uint(Error.INSUFFICIENT_LIQUIDITY);
            }
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit logs.
     * @param bToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    function borrowVerify(address bToken, address borrower, uint borrowAmount) override external {
        // Shh - currently unused
        bToken;
        borrower;
        borrowAmount;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param bToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which would borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(
        address bToken,
        address payer,
        address borrower,
        uint repayAmount) override external returns (uint) {
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!markets[bToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }



        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates repayBorrow and reverts on rejection. May emit logs.
     * @param bToken Asset being repaid
     * @param payer The address repaying the borrow
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function repayBorrowVerify(
        address bToken,
        address payer,
        address borrower,
        uint actualRepayAmount,
        uint borrowerIndex) override external {
        // Shh - currently unused
        bToken;
        payer;
        borrower;
        actualRepayAmount;
        borrowerIndex;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param bTokenBorrowed Asset which was borrowed by the borrower
     * @param bTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(
        address bTokenBorrowed,
        address bTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) override external returns (uint) {
        if (!markets[bTokenBorrowed].isListed || !markets[bTokenCollateral].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Liquidator whitelist (spec §7.1): when an access controller is set and its
        // liquidator gate is enabled, only whitelisted liquidators may liquidate.
        // address(0) controller or a disabled gate => anyone may liquidate.
        address _accessController = accessController;
        if (_accessController != address(0) && !IAccessController(_accessController).isAllowedToLiquidate(liquidator)) {
            return uint(Error.REJECTION);
        }

        // Separation mode pairs every debt with collateral of the OPPOSITE type, and liquidation
        // is where that pairing has to be cashed in. Seizing same-type collateral would leave the
        // collateral actually securing this debt untouched, drain a healthy line to cover the
        // other one, and put two wrapped-stock legs into a single liquidation -- the case the
        // A/B split exists to rule out. Applies to deprecated markets too: winding a market down
        // does not make an unclosable liquidation closable.
        if (separationModeEnabled && tokenTypes[bTokenCollateral] == tokenTypes[bTokenBorrowed]) {
            return uint(Error.REJECTION);
        }

        uint borrowBalance = BToken(bTokenBorrowed).borrowBalanceStored(borrower);

        /* allow accounts to be liquidated if the market is deprecated */
        if (isDeprecated(BToken(bTokenBorrowed))) {
            require(borrowBalance >= repayAmount, "Can not repay more than the total borrow");
        } else {
            /* The borrower must have shortfall in order to be liquidatable */
            if (separationModeEnabled) {
                // In separation mode, check shortfall based on borrowed token type
                TokenType borrowedTokenType = tokenTypes[bTokenBorrowed];
                
                (Error err, uint liquidityA, uint shortfallA, uint liquidityB, uint shortfallB) =
                    getHypotheticalAccountLiquidityInternalSeparated(borrower, BToken(address(0)), 0, 0, RiskMode.LIQUIDATION);

                if (err != Error.NO_ERROR) {
                    return uint(err);
                }

                // Check shortfall for the appropriate type
                uint relevantShortfall = 0;
                if (borrowedTokenType == TokenType.TYPE_A) {
                    relevantShortfall = shortfallB; // Type A borrows require Type B collateral
                } else if (borrowedTokenType == TokenType.TYPE_B) {
                    relevantShortfall = shortfallA; // Type B borrows require Type A collateral
                } else {
                    // UNCLASSIFIED: not borrowable in separation mode, and there is no line
                    // whose shortfall would justify seizing collateral for it.
                    return uint(Error.REJECTION);
                }
                
                if (relevantShortfall == 0) {
                    return uint(Error.INSUFFICIENT_SHORTFALL);
                }
            } else {
                // Original logic for non-separation mode
                (Error err, , uint shortfall) = getAccountLiquidityInternal(borrower);
                if (err != Error.NO_ERROR) {
                    return uint(err);
                }

                if (shortfall == 0) {
                    return uint(Error.INSUFFICIENT_SHORTFALL);
                }
            }

            /* The liquidator may not repay more than what is allowed by the closeFactor */
            uint maxClose = mul_ScalarTruncate(Exp({mantissa: closeFactorMantissa}), borrowBalance);
            if (repayAmount > maxClose) {
                return uint(Error.TOO_MUCH_REPAY);
            }
        }
        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
     * @param bTokenBorrowed Asset which was borrowed by the borrower
     * @param bTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function liquidateBorrowVerify(
        address bTokenBorrowed,
        address bTokenCollateral,
        address liquidator,
        address borrower,
        uint actualRepayAmount,
        uint seizeTokens) override external {
        // Shh - currently unused
        bTokenBorrowed;
        bTokenCollateral;
        liquidator;
        borrower;
        actualRepayAmount;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param bTokenCollateral Asset which was used as collateral and will be seized
     * @param bTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address bTokenCollateral,
        address bTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) override external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPaused, "seize is paused");

        // Shh - currently unused
        seizeTokens;

        if (!markets[bTokenCollateral].isListed || !markets[bTokenBorrowed].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (BToken(bTokenCollateral).comptroller() != BToken(bTokenBorrowed).comptroller()) {
            return uint(Error.COMPTROLLER_MISMATCH);
        }

        // Same line pairing as liquidateBorrowAllowed -- enforced here too because seize is a
        // separate entry point into the comptroller.
        if (separationModeEnabled && tokenTypes[bTokenCollateral] == tokenTypes[bTokenBorrowed]) {
            return uint(Error.REJECTION);
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit logs.
     * @param bTokenCollateral Asset which was used as collateral and will be seized
     * @param bTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeVerify(
        address bTokenCollateral,
        address bTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) override external {
        // Shh - currently unused
        bTokenCollateral;
        bTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param bToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of bTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(address bToken, address src, address dst, uint transferTokens) override external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer is paused");

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint allowed = redeemAllowedInternal(bToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }



        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit logs.
     * @param bToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of bTokens to transfer
     */
    function transferVerify(address bToken, address src, address dst, uint transferTokens) override external {
        // Shh - currently unused
        bToken;
        src;
        dst;
        transferTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `bTokenBalance` is the number of bTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    /// @notice Which collateral line a liquidity computation should use.
    /// @dev BORROW reads borrowFactor (gates new borrows/redeems); LIQUIDATION reads
    ///      collateralFactor = liquidation threshold (gates shortfall/liquidation).
    enum RiskMode {
        BORROW,
        LIQUIDATION
    }

    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint bTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    /**
     * @dev Separate liquidity calculation results for A/B token separation mode
     */
    struct SeparatedLiquidityLocalVars {
        uint sumCollateralA;        // Type A collateral, secures Type B debt (line A)
        uint sumCollateralB;        // Type B collateral, secures Type A debt (line B)
        uint sumBorrowPlusEffectsA; // Type A debt + hypothetical effects charged to line B
        uint sumBorrowPlusEffectsB; // Type B debt + hypothetical effects charged to line A
    }

    /**
     * @notice Pick the collateral line for a market depending on the risk context.
     * @dev BORROW -> borrowFactor (gates new exposure); LIQUIDATION -> collateralFactor
     *      (liquidation threshold, gates shortfall). This single switch is what keeps
     *      "lowering borrowFactor only blocks new borrows, never touches existing positions".
     */
    function collateralLineMantissa(address asset, RiskMode mode) internal view returns (uint) {
        // LIQUIDATION line is never touched by the global haircut (fail-safe: the haircut
        // only restricts NEW borrows, it can never make an existing position liquidatable).
        if (mode == RiskMode.LIQUIDATION) {
            return markets[asset].collateralFactorMantissa;
        }
        // BORROW line, scaled down by the global borrow haircut (spec §10.2):
        //   effective borrowFactor = borrowFactor × (1 − globalBorrowHaircut)
        uint borrowFactor = markets[asset].borrowFactorMantissa;
        uint haircut = effectiveBorrowHaircutMantissa();
        if (haircut == 0) return borrowFactor;
        if (haircut >= 1e18) return 0;
        return borrowFactor * (1e18 - haircut) / 1e18;
    }

    /**
     * @notice The global borrow haircut currently in effect = max(keeperHaircut, guardianHaircut),
     *         capped at 1e18. Multiplies every collateral market's borrowFactor; never the
     *         liquidation threshold.
     */
    function effectiveBorrowHaircutMantissa() public view returns (uint) {
        uint h = keeperHaircutMantissa > guardianHaircutMantissa ? keeperHaircutMantissa : guardianHaircutMantissa;
        return h > 1e18 ? 1e18 : h;
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account) public view returns (uint, uint, uint) {
        if (separationModeEnabled) {
            return _collapsedSeparatedLiquidity(account, BToken(address(0)), 0, 0, RiskMode.LIQUIDATION);
        }
        // LIQUIDATION line: reports health "how far from being liquidatable".
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, BToken(address(0)), 0, 0, RiskMode.LIQUIDATION);

        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Answer the classic single-pool (liquidity, shortfall) question while separation
     *         mode is on, without ever being optimistic.
     * @dev The two lines are independent: A collateral secures B debt and vice versa. Netting
     *      them as one pool -- which is what the single-line calculation does -- lets spare
     *      headroom on one line hide a shortfall on the other, so an account the protocol will
     *      happily liquidate reads as healthy to every Lens/UI/bot consumer. Collapse instead:
     *      any shortfall surfaces, and the reported headroom is the tighter of the two lines.
     *      Callers that need to act per line must use getAccountLiquiditySeparated.
     */
    function _collapsedSeparatedLiquidity(
        address account,
        BToken bTokenModify,
        uint redeemTokens,
        uint borrowAmount,
        RiskMode mode
    ) internal view returns (uint, uint, uint) {
        (Error err, uint liquidityA, uint shortfallA, uint liquidityB, uint shortfallB) =
            getHypotheticalAccountLiquidityInternalSeparated(account, bTokenModify, redeemTokens, borrowAmount, mode);
        if (err != Error.NO_ERROR) {
            return (uint(err), 0, 0);
        }

        uint shortfall = add_(shortfallA, shortfallB);
        if (shortfall > 0) {
            return (uint(Error.NO_ERROR), 0, shortfall);
        }
        return (uint(Error.NO_ERROR), liquidityA < liquidityB ? liquidityA : liquidityB, 0);
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code,
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidityInternal(address account) internal view returns (Error, uint, uint) {
        // Only consumed by the liquidation path -> LIQUIDATION line (liquidation threshold).
        return getHypotheticalAccountLiquidityInternal(account, BToken(address(0)), 0, 0, RiskMode.LIQUIDATION);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param bTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address bTokenModify,
        uint redeemTokens,
        uint borrowAmount) public view returns (uint, uint, uint) {
        if (separationModeEnabled) {
            return _collapsedSeparatedLiquidity(account, BToken(bTokenModify), redeemTokens, borrowAmount, RiskMode.BORROW);
        }
        // Simulates a borrow/redeem -> BORROW line (borrow factor).
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, BToken(bTokenModify), redeemTokens, borrowAmount, RiskMode.BORROW);
        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param bTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral bToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        BToken bTokenModify,
        uint redeemTokens,
        uint borrowAmount,
        RiskMode mode) internal view returns (Error, uint, uint) {

        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint oErr;

        // For each asset the account is in
        BToken[] memory assets = accountAssets[account];
        for (uint i = 0; i < assets.length; i++) {
            BToken asset = assets[i];

            // Read the balances and exchange rate from the bToken
            (oErr, vars.bTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(account);
            if (oErr != 0) { // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }
            // An empty position contributes nothing whatever the price is, so skip the oracle
            // read. bTokenModify must never be skipped: it is empty on a first borrow, and the
            // hypothetical redeem/borrow is applied inside this same loop iteration.
            if (vars.bTokenBalance == 0 && vars.borrowBalance == 0 && asset != bTokenModify) {
                continue;
            }
            vars.collateralFactor = Exp({mantissa: collateralLineMantissa(address(asset), mode)});
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> ether (normalized price value)
            vars.tokensToDenom = mul_(mul_(vars.collateralFactor, vars.exchangeRate), vars.oraclePrice);

            // sumCollateral += tokensToDenom * bTokenBalance
            vars.sumCollateral = mul_ScalarTruncateAddUInt(vars.tokensToDenom, vars.bTokenBalance, vars.sumCollateral);

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);

            // Calculate effects of interacting with bTokenModify
            if (address(asset) == address(bTokenModify)) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
            }
        }

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (Error.NO_ERROR, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (Error.NO_ERROR, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    /**
     * @notice Helper function to process a single asset for separated liquidity calculation
     */
    function _processSeparatedAsset(
        BToken asset,
        address account,
        SeparatedLiquidityLocalVars memory sepVars,
        RiskMode mode
    ) internal view returns (Error) {
        (uint oErr, uint bTokenBalance, uint borrowBalance, uint exchangeRateMantissa) = asset.getAccountSnapshot(account);
        if (oErr != 0) {
            return Error.SNAPSHOT_ERROR;
        }

        // An empty position contributes zero to both lines whatever the price is, so skip
        // the oracle read entirely. Besides the gas, this keeps a dead price feed on a market
        // the account merely entered from bricking its whole liquidity calculation -- and with
        // it every redeem, borrow and LIQUIDATION on unrelated positions.
        if (bTokenBalance == 0 && borrowBalance == 0) {
            return Error.NO_ERROR;
        }

        uint oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
        if (oraclePriceMantissa == 0) {
            return Error.PRICE_ERROR;
        }

        uint collateralFactorMantissa = collateralLineMantissa(address(asset), mode);

        // Calculate collateral and borrow values
        uint collateralValue = mul_ScalarTruncate(
            mul_(mul_(Exp({mantissa: collateralFactorMantissa}), Exp({mantissa: exchangeRateMantissa})), Exp({mantissa: oraclePriceMantissa})),
            bTokenBalance
        );
        uint borrowValue = mul_ScalarTruncate(Exp({mantissa: oraclePriceMantissa}), borrowBalance);

        // Accumulate by token type.
        TokenType tokenType = tokenTypes[address(asset)];
        if (tokenType == TokenType.TYPE_A) {
            sepVars.sumCollateralA += collateralValue;
            sepVars.sumBorrowPlusEffectsA += borrowValue;
        } else if (tokenType == TokenType.TYPE_B) {
            sepVars.sumCollateralB += collateralValue;
            sepVars.sumBorrowPlusEffectsB += borrowValue;
        } else {
            // UNCLASSIFIED with a live position. _setSeparationMode refuses to turn the mode
            // on while any listed market is unclassified, and _setTokenType refuses to move a
            // non-empty market while it is on, so this is a backstop rather than a live path.
            // Be conservative in both directions: the collateral secures nothing, but the debt
            // must never go invisible, so charge it against both lines.
            sepVars.sumBorrowPlusEffectsA += borrowValue;
            sepVars.sumBorrowPlusEffectsB += borrowValue;
        }

        return Error.NO_ERROR;
    }

    /**
     * @notice Helper function to apply hypothetical changes to separated liquidity
     */
    function _applySeparatedEffects(
        BToken bTokenModify,
        address account,
        uint redeemTokens,
        uint borrowAmount,
        SeparatedLiquidityLocalVars memory sepVars,
        RiskMode mode
    ) internal view returns (Error) {
        if (address(bTokenModify) == address(0)) {
            return Error.NO_ERROR;
        }

        (, , , uint exchangeRateMantissa) = bTokenModify.getAccountSnapshot(account);
        uint oraclePriceMantissa = oracle.getUnderlyingPrice(bTokenModify);
        if (oraclePriceMantissa == 0) {
            return Error.PRICE_ERROR;
        }

        uint collateralFactorMantissa = collateralLineMantissa(address(bTokenModify), mode);
        TokenType tokenType = tokenTypes[address(bTokenModify)];

        // A redeem removes COLLATERAL, a borrow adds DEBT, and in separation mode those two
        // land on OPPOSITE risk lines:
        //   line A: shortfallA = sumBorrowPlusEffectsB - sumCollateralA  (A collateral backs B debt)
        //   line B: shortfallB = sumBorrowPlusEffectsA - sumCollateralB  (B collateral backs A debt)
        // Withdrawing TYPE_A collateral shrinks sumCollateralA, i.e. it must be charged to
        // line A -- which we express (Compound-style, avoiding an underflow clamp) by adding
        // the withdrawn value to sumBorrowPlusEffectsB. Borrowing TYPE_A grows sumBorrowPlusEffectsA
        // and stays on line B. Booking both into the same accumulator is what allowed a
        // borrower to redeem the collateral backing their debt.
        uint redeemValue = mul_ScalarTruncate(
            mul_(mul_(Exp({mantissa: collateralFactorMantissa}), Exp({mantissa: exchangeRateMantissa})), Exp({mantissa: oraclePriceMantissa})),
            redeemTokens
        );
        uint borrowValue = mul_ScalarTruncate(Exp({mantissa: oraclePriceMantissa}), borrowAmount);

        if (tokenType == TokenType.TYPE_A) {
            sepVars.sumBorrowPlusEffectsB += redeemValue; // less TYPE_A collateral -> line A
            sepVars.sumBorrowPlusEffectsA += borrowValue; // more TYPE_A debt      -> line B
        } else if (tokenType == TokenType.TYPE_B) {
            sepVars.sumBorrowPlusEffectsA += redeemValue; // less TYPE_B collateral -> line B
            sepVars.sumBorrowPlusEffectsB += borrowValue; // more TYPE_B debt       -> line A
        } else {
            // UNCLASSIFIED, mirroring _processSeparatedAsset: its collateral is counted on
            // neither line so a redeem costs nothing, but hypothetical debt must stay visible.
            sepVars.sumBorrowPlusEffectsA += borrowValue;
            sepVars.sumBorrowPlusEffectsB += borrowValue;
        }

        return Error.NO_ERROR;
    }

    /**
     * @notice Determine what the account liquidity would be with A/B separation mode
     * @param account The account to determine liquidity for
     * @param bTokenModify The market to hypothetically redeem/borrow in
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code,
                Type A liquidity,
                Type A shortfall,
                Type B liquidity,
                Type B shortfall)
     */
    function getHypotheticalAccountLiquidityInternalSeparated(
        address account,
        BToken bTokenModify,
        uint redeemTokens,
        uint borrowAmount,
        RiskMode mode) internal view returns (Error, uint, uint, uint, uint) {

        SeparatedLiquidityLocalVars memory sepVars;

        // Process each asset
        BToken[] memory assets = accountAssets[account];
        for (uint i = 0; i < assets.length; i++) {
            Error assetErr = _processSeparatedAsset(assets[i], account, sepVars, mode);
            if (assetErr != Error.NO_ERROR) {
                return (assetErr, 0, 0, 0, 0);
            }
        }

        // Apply hypothetical effects
        Error effectsErr = _applySeparatedEffects(bTokenModify, account, redeemTokens, borrowAmount, sepVars, mode);
        if (effectsErr != Error.NO_ERROR) {
            return (effectsErr, 0, 0, 0, 0);
        }

        // Calculate final results
        uint liquidityA = sepVars.sumCollateralA > sepVars.sumBorrowPlusEffectsB ? 
            sepVars.sumCollateralA - sepVars.sumBorrowPlusEffectsB : 0;
        uint shortfallA = sepVars.sumBorrowPlusEffectsB > sepVars.sumCollateralA ? 
            sepVars.sumBorrowPlusEffectsB - sepVars.sumCollateralA : 0;
        uint liquidityB = sepVars.sumCollateralB > sepVars.sumBorrowPlusEffectsA ? 
            sepVars.sumCollateralB - sepVars.sumBorrowPlusEffectsA : 0;
        uint shortfallB = sepVars.sumBorrowPlusEffectsA > sepVars.sumCollateralB ? 
            sepVars.sumBorrowPlusEffectsA - sepVars.sumCollateralB : 0;

        return (Error.NO_ERROR, liquidityA, shortfallA, liquidityB, shortfallB);
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in bToken.liquidateBorrowFresh)
     * @param bTokenBorrowed The address of the borrowed bToken
     * @param bTokenCollateral The address of the collateral bToken
     * @param actualRepayAmount The amount of bTokenBorrowed underlying to convert into bTokenCollateral tokens
     * @return (errorCode, number of bTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(address bTokenBorrowed, address bTokenCollateral, uint actualRepayAmount) override external view returns (uint, uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(BToken(bTokenBorrowed));
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(BToken(bTokenCollateral));
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa = BToken(bTokenCollateral).exchangeRateStored(); // Note: reverts on error
        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mul_(Exp({mantissa: liquidationIncentiveMantissa}), Exp({mantissa: priceBorrowedMantissa}));
        denominator = mul_(Exp({mantissa: priceCollateralMantissa}), Exp({mantissa: exchangeRateMantissa}));
        ratio = div_(numerator, denominator);

        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    /*** Admin Functions ***/

    /**
      * @notice Sets a new price oracle for the comptroller
      * @dev Admin function to set a new price oracle
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setPriceOracle(PriceOracle newOracle) public returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK);
        }

        // Track the old oracle for the comptroller
        PriceOracle oldOracle = oracle;

        // Set comptroller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the closeFactor used when liquidating borrows
      * @dev Admin function to set closeFactor
      * @param newCloseFactorMantissa New close factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure
      */
    function _setCloseFactor(uint newCloseFactorMantissa) external returns (uint) {
        // Check caller is admin
    	require(msg.sender == admin, "only admin can set close factor");

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the collateralFactor for a market
      * @dev Admin function to set per-market collateralFactor
      * @param bToken The market to set the factor on
      * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setCollateralFactor(BToken bToken, uint newCollateralFactorMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }

        // Verify market is listed
        Market storage market = markets[address(bToken)];
        if (!market.isListed) {
            return fail(Error.MARKET_NOT_LISTED, FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS);
        }

        Exp memory newCollateralFactorExp = Exp({mantissa: newCollateralFactorMantissa});

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        // Two-line invariant: the liquidation threshold may never drop below the borrow line.
        if (newCollateralFactorMantissa < market.borrowFactorMantissa) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;

        // Step limit: lowering the liquidation threshold makes existing positions more liquidatable,
        // so cap how far it can move in a single change to avoid pushing borderline users into
        // shortfall all at once. 0 = disabled.
        if (liquidationThresholdMaxReductionMantissa != 0 && newCollateralFactorMantissa < oldCollateralFactorMantissa) {
            if (oldCollateralFactorMantissa - newCollateralFactorMantissa > liquidationThresholdMaxReductionMantissa) {
                return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
            }
        }

        // If collateral factor != 0, fail if price == 0
        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(bToken) == 0) {
            return fail(Error.PRICE_ERROR, FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE);
        }

        // Set market's collateral factor (liquidation threshold) to new value
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(bToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the borrowFactor (borrow line) for a market.
      * @dev Asymmetric access:
      *      - admin (expected to be a Timelock) may set any value <= the liquidation threshold;
      *        raising borrowFactor re-enables leverage and is therefore gated by the admin/timelock.
      *      - cfKeeper may ONLY lower borrowFactor, immediately and without timelock — a fast
      *        de-risk path that can never make an existing position liquidatable (borrowFactor is
      *        not used by the liquidation path).
      * @param bToken The market to set the borrow factor on
      * @param newBorrowFactorMantissa The new borrow factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure
      */
    function _setBorrowFactor(BToken bToken, uint newBorrowFactorMantissa) external returns (uint) {
        Market storage market = markets[address(bToken)];
        if (!market.isListed) {
            return fail(Error.MARKET_NOT_LISTED, FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS);
        }

        uint oldBorrowFactorMantissa = market.borrowFactorMantissa;

        bool isAdmin = msg.sender == admin;
        bool isKeeperLowering = msg.sender == cfKeeper && newBorrowFactorMantissa < oldBorrowFactorMantissa;
        if (!isAdmin && !isKeeperLowering) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }

        // Two-line invariant: borrowFactor <= liquidationThreshold (collateralFactor).
        if (newBorrowFactorMantissa > market.collateralFactorMantissa) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        market.borrowFactorMantissa = newBorrowFactorMantissa;
        emit NewBorrowFactor(bToken, oldBorrowFactorMantissa, newBorrowFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the CF keeper allowed to lower borrowFactor without timelock.
      * @dev Admin only. Set to address(0) to disable the fast de-risk role.
      */
    function _setCfKeeper(address newCfKeeper) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }
        address oldCfKeeper = cfKeeper;
        cfKeeper = newCfKeeper;
        emit NewCfKeeper(oldCfKeeper, newCfKeeper);
        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the max single-step reduction of any market's liquidation threshold.
      * @dev Admin only. 0 = unlimited (disabled).
      */
    function _setLiquidationThresholdMaxReduction(uint newMantissa) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }
        uint oldMantissa = liquidationThresholdMaxReductionMantissa;
        liquidationThresholdMaxReductionMantissa = newMantissa;
        emit NewLiquidationThresholdMaxReduction(oldMantissa, newMantissa);
        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the RISK_KEEPER allowed to RAISE the keeper haircut without timelock.
      * @dev Admin only. Set to address(0) to disable the fast keeper-tighten path.
      */
    function _setRiskKeeper(address newRiskKeeper) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PENDING_ADMIN_OWNER_CHECK);
        }
        address old = riskKeeper;
        riskKeeper = newRiskKeeper;
        emit NewRiskKeeper(old, newRiskKeeper);
        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the keeper global borrow haircut (spec §10.2).
      * @dev Asymmetric: admin may set any value; riskKeeper may only RAISE it (immediate
      *      de-risk). Lowering (relaxing) is admin-only (= timelock). Value is a 1e18 mantissa,
      *      capped at 1e18. Only restricts new borrows — never touches the liquidation line.
      */
    function _setKeeperHaircut(uint newHaircutMantissa) external returns (uint) {
        if (newHaircutMantissa > 1e18) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }
        bool isAdmin = msg.sender == admin;
        bool isKeeperRaising = msg.sender == riskKeeper && newHaircutMantissa > keeperHaircutMantissa;
        if (!isAdmin && !isKeeperRaising) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PENDING_ADMIN_OWNER_CHECK);
        }
        uint old = keeperHaircutMantissa;
        keeperHaircutMantissa = newHaircutMantissa;
        emit NewKeeperHaircut(old, newHaircutMantissa);
        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the guardian global borrow haircut — manual emergency lever (spec §10.2).
      * @dev Asymmetric: the pause guardian may only RAISE it (e.g. to 1e18 = halt all new borrows);
      *      lowering (lifting the emergency) is admin-only. 1e18 mantissa, capped at 1e18.
      */
    function _setGuardianHaircut(uint newHaircutMantissa) external returns (uint) {
        if (newHaircutMantissa > 1e18) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }
        bool isAdmin = msg.sender == admin;
        bool isGuardianRaising = msg.sender == pauseGuardian && newHaircutMantissa > guardianHaircutMantissa;
        if (!isAdmin && !isGuardianRaising) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PENDING_ADMIN_OWNER_CHECK);
        }
        uint old = guardianHaircutMantissa;
        guardianHaircutMantissa = newHaircutMantissa;
        emit NewGuardianHaircut(old, newHaircutMantissa);
        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets liquidationIncentive
      * @dev Admin function to set liquidationIncentive
      * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK);
        }

        // Save current value for use in log
        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Add the market to the markets mapping and set it as listed
      * @dev Admin function to set isListed and add support for the market
      * @param bToken The address of the market (token) to list
      * @return uint 0=success, otherwise a failure. (See enum Error for details)
      */
    function _supportMarket(BToken bToken) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SUPPORT_MARKET_OWNER_CHECK);
        }

        if (markets[address(bToken)].isListed) {
            return fail(Error.MARKET_ALREADY_LISTED, FailureInfo.SUPPORT_MARKET_EXISTS);
        }

        bToken.isBToken(); // Sanity check to make sure its really a BToken

        Market storage newMarket = markets[address(bToken)];
        newMarket.isListed = true;
        newMarket.collateralFactorMantissa = 0; // liquidation threshold
        newMarket.borrowFactorMantissa = 0;     // borrow line (must be set before borrowing is possible)

        _addMarketInternal(address(bToken));

        emit MarketListed(bToken);

        return uint(Error.NO_ERROR);
    }

    function _addMarketInternal(address bToken) internal {
        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != BToken(bToken), "market already added");
        }
        allMarkets.push(BToken(bToken));
    }



    /**
      * @notice Set the given borrow caps for the given bToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
      * @dev Admin or borrowCapGuardian function to set the borrow caps. A borrow cap of 0 corresponds to unlimited borrowing.
      * @param bTokens The addresses of the markets (tokens) to change the borrow caps for
      * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
      */
    function _setMarketBorrowCaps(BToken[] calldata bTokens, uint[] calldata newBorrowCaps) external {
    	require(msg.sender == admin || msg.sender == borrowCapGuardian, "only admin or borrow cap guardian can set borrow caps");

        uint numMarkets = bTokens.length;
        uint numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "invalid input");

        for(uint i = 0; i < numMarkets; i++) {
            borrowCaps[address(bTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(bTokens[i], newBorrowCaps[i]);
        }
    }

    /**
     * @notice Admin function to change the Borrow Cap Guardian
     * @param newBorrowCapGuardian The address of the new Borrow Cap Guardian
     */
    function _setBorrowCapGuardian(address newBorrowCapGuardian) external {
        require(msg.sender == admin, "only admin can set borrow cap guardian");

        // Save current value for inclusion in log
        address oldBorrowCapGuardian = borrowCapGuardian;

        // Store borrowCapGuardian with value newBorrowCapGuardian
        borrowCapGuardian = newBorrowCapGuardian;

        // Emit NewBorrowCapGuardian(OldBorrowCapGuardian, NewBorrowCapGuardian)
        emit NewBorrowCapGuardian(oldBorrowCapGuardian, newBorrowCapGuardian);
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(address newPauseGuardian) public returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK);
        }

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;

        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);

        return uint(Error.NO_ERROR);
    }

    function _setMintPaused(BToken bToken, bool state) public returns (bool) {
        require(markets[address(bToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        mintGuardianPaused[address(bToken)] = state;
        emit ActionPaused(bToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(BToken bToken, bool state) public returns (bool) {
        require(markets[address(bToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        borrowGuardianPaused[address(bToken)] = state;
        emit ActionPaused(bToken, "Borrow", state);
        return state;
    }

    function _setTransferPaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    /**
     * @notice Sets the external access controller used to gate mint (deposit) and borrow.
     * @dev Admin-only.
     *      - Pass address(0) to DISABLE the gate entirely — any address can mint/borrow.
     *        This is the initial/default state, preserving legacy behavior.
     *      - Pass a non-zero address to ENABLE the gate. On every mint/borrow the
     *        Blotroller will call isAllowedToMint / isAllowedToBorrow on the controller
     *        and revert if it returns false.
     *      The controller is expected to implement IAccessController.
     */
    function _setAccessController(address newAccessController) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_ACCESS_CONTROLLER_OWNER_CHECK);
        }

        address old = accessController;
        accessController = newAccessController;
        emit NewAccessController(old, newAccessController);

        return uint(Error.NO_ERROR);
    }

    function _become(Unitroller unitroller) public {
        require(msg.sender == unitroller.admin(), "only unitroller admin can change brains");
        require(unitroller._acceptImplementation() == 0, "change not authorized");
    }


    /**
     * @notice Checks caller is admin, or this contract is becoming the new implementation
     */
    function adminOrInitializing() internal view returns (bool) {
        return msg.sender == admin || msg.sender == comptrollerImplementation;
    }


    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() public view returns (BToken[] memory) {
        return allMarkets;
    }

    /**
     * @notice Returns true if the given bToken market has been deprecated
     * @dev All borrows in a deprecated bToken market can be immediately liquidated
     * @param bToken The market to check if deprecated
     */
    function isDeprecated(BToken bToken) public view returns (bool) {
        return
            markets[address(bToken)].collateralFactorMantissa == 0 &&
            borrowGuardianPaused[address(bToken)] == true &&
            bToken.reserveFactorMantissa() == 1e18
        ;
    }

    function getBlockNumber() virtual public view returns (uint) {
        return block.number;
    }

    /**
     * @notice Admin function to set token type for A/B classification
     * @param bToken The bToken to classify
     * @param tokenType The type to assign (UNCLASSIFIED, TYPE_A, or TYPE_B)
     * @return uint 0=success, otherwise a failure
     */
    function _setTokenType(BToken bToken, TokenType tokenType) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }

        // Verify market is listed
        if (!markets[address(bToken)].isListed) {
            return fail(Error.MARKET_NOT_LISTED, FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS);
        }

        // Store old type for event
        TokenType oldType = tokenTypes[address(bToken)];

        // A market's type decides which line its collateral and its debt sit on, so MOVING a
        // live market between lines rewrites both of them underneath existing positions: an
        // account can go from healthy to shortfall without a price moving or a token changing
        // hands. Such a move needs an empty market -- deprecate it, let it wind down, retype.
        //
        // Classifying an UNCLASSIFIED market is exempt, and must be: a market listed while the
        // mode is already on starts unclassified, and refusing to classify it once someone has
        // supplied would strand it permanently. The move is monotonically safe anyway -- its
        // collateral goes from counting on no line to counting on one, and its debt from being
        // charged to both lines to just one -- so no account can be pushed into shortfall.
        //
        // Outside separation mode the type has no effect at all, so anything goes.
        if (
            separationModeEnabled &&
            oldType != TokenType.UNCLASSIFIED &&
            oldType != tokenType &&
            (bToken.totalSupply() != 0 || bToken.totalBorrows() != 0)
        ) {
            return fail(Error.REJECTION, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        // Set new type
        tokenTypes[address(bToken)] = tokenType;

        // Emit event
        emit TokenTypeSet(address(bToken), oldType, tokenType);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Admin function to toggle A/B separation mode
     * @param enabled Whether to enable separation mode
     * @return uint 0=success, otherwise a failure
     */
    function _setSeparationMode(bool enabled) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK);
        }

        // Turning the mode ON is only safe once the classification it depends on actually
        // exists. With every market on one line the opposite line has no collateral at all,
        // which blocks every borrow, and -- since liquidation now requires opposite-type
        // collateral -- every liquidation too. Turning it OFF needs no checks: the single-pool
        // model is always a valid fallback.
        if (enabled) {
            uint countA = 0;
            uint countB = 0;
            for (uint i = 0; i < allMarkets.length; i++) {
                TokenType t = tokenTypes[address(allMarkets[i])];
                if (t == TokenType.TYPE_A) {
                    countA++;
                } else if (t == TokenType.TYPE_B) {
                    countB++;
                } else {
                    // A listed but unclassified market would sit on neither line.
                    return fail(Error.REJECTION, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
                }
            }
            if (countA == 0 || countB == 0) {
                return fail(Error.REJECTION, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
            }
        }

        // Store old mode for event
        bool oldMode = separationModeEnabled;

        // Set new mode
        separationModeEnabled = enabled;

        // Emit event
        emit SeparationModeToggled(oldMode, enabled);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Get separated account liquidity information (A/B types)
     * @param account The account to get liquidity for
     * @return (error code, A liquidity, A shortfall, B liquidity, B shortfall)
     */
    function getAccountLiquiditySeparated(address account) public view returns (uint, uint, uint, uint, uint) {
        if (!separationModeEnabled) {
            return (uint(Error.COMPTROLLER_MISMATCH), 0, 0, 0, 0); // Reuse error for disabled mode
        }
        
        // LIQUIDATION line: reports health.
        (Error err, uint liquidityA, uint shortfallA, uint liquidityB, uint shortfallB) =
            getHypotheticalAccountLiquidityInternalSeparated(account, BToken(address(0)), 0, 0, RiskMode.LIQUIDATION);

        return (uint(err), liquidityA, shortfallA, liquidityB, shortfallB);
    }

    /**
     * @notice Get hypothetical separated account liquidity (A/B types)
     * @param account The account to get liquidity for
     * @param bTokenModify The market to hypothetically modify
     * @param redeemTokens Number of tokens to hypothetically redeem
     * @param borrowAmount Amount to hypothetically borrow
     * @return (error code, A liquidity, A shortfall, B liquidity, B shortfall)
     */
    function getHypotheticalAccountLiquiditySeparated(
        address account,
        address bTokenModify,
        uint redeemTokens,
        uint borrowAmount
    ) public view returns (uint, uint, uint, uint, uint) {
        if (!separationModeEnabled) {
            return (uint(Error.COMPTROLLER_MISMATCH), 0, 0, 0, 0); // Reuse error for disabled mode
        }
        
        // Simulates a borrow/redeem -> BORROW line.
        (Error err, uint liquidityA, uint shortfallA, uint liquidityB, uint shortfallB) =
            getHypotheticalAccountLiquidityInternalSeparated(account, BToken(bTokenModify), redeemTokens, borrowAmount, RiskMode.BORROW);

        return (uint(err), liquidityA, shortfallA, liquidityB, shortfallB);
    }

}
