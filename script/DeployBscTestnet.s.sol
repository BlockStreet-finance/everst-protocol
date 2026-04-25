// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import "../src/Unitroller.sol";
import "../src/Blotroller.sol";
import "../src/BErc20Delegator.sol";
import "../src/BErc20Delegate.sol";
import "../src/BlockStreetPriceOracle.sol";
import "../src/JumpRateModel.sol";
import "../src/MockERC20.sol";
import "../src/AccessController.sol";
import "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/**
 * @title DeployBscTestnet — BSC Testnet full deployment
 * @notice Fully-mocked deployment (MockPyth + MockUSDC + MockWtCOIN) so you
 *         can exercise every flow (supply / borrow / repay / liquidate) with
 *         prices you control end-to-end. Both mock tokens use 18 decimals to
 *         align with deploy.json's 2e26 initialExchangeRate.
 *
 * Markets:
 *   - bUSDC   (CF 80%, reserve 10%)   — stable leg
 *   - bwtCOIN (CF 50%, reserve 20%)   — volatile leg
 *
 * Interest rate note:
 *   JumpRateModel.blocksPerYear = 2102400 assumes 15s blocks. BSC is ~3s, so
 *   effective APY is ~5x faster. Good for testing, wrong for mainnet.
 *
 * Usage:
 *   forge script script/DeployBscTestnet.s.sol:DeployBscTestnetScript \
 *       --rpc-url https://data-seed-prebsc-1-s1.binance.org:8545/ \
 *       --account blockstreet-everst \
 *       --sender 0x62bdd47787ff9ac1eb0f62ba800db821ed0323e1 \
 *       --broadcast --legacy -vvvv
 */
contract DeployBscTestnetScript is Script {
    using stdJson for string;

    // ================================================================
    // Deployed contracts
    // ================================================================
    MockPyth                 public mockPyth;
    MockERC20                public mockUSDC;
    MockERC20                public mockWtCOIN;

    Unitroller               public unitroller;
    Blotroller               public blotroller;
    BlockStreetPriceOracle   public priceOracle;
    JumpRateModel            public interestRateModel;
    BErc20Delegate           public bErc20Delegate;
    BErc20Delegator          public bUSDC;
    BErc20Delegator          public bwtCOIN;
    AccessController         public accessController;

    // ================================================================
    // Pyth price IDs (official IDs; works fine with MockPyth too)
    // ================================================================
    bytes32 constant USDC_USD_PRICE_ID =
        0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
    bytes32 constant COIN_USD_PRICE_ID =
        0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245;

    // Mock prices — all expo=-8 so 1e8 = $1
    int64  constant MOCK_USDC_PRICE  = 100_000_000;       // $1.0000
    uint64 constant MOCK_USDC_CONF   = 100_000;           // 0.1% conf
    int64  constant MOCK_COIN_PRICE  = 25_000_000_000;    // $250
    uint64 constant MOCK_COIN_CONF   = 50_000_000;        // 0.2% conf
    int32  constant MOCK_EXPO        = -8;

    function run() external {
        require(block.chainid == 97, "This script is for BSC Testnet (97) only");

        string memory configFile = vm.readFile("config/deploy.json");

        vm.startBroadcast();

        console.log("=== BlockStreet Protocol - BSC Testnet Deployment ===");
        console.log("Deployer:", msg.sender);

        // ----------------------------------------------------------
        // 1. Mocks (Pyth + two ERC20s)
        // ----------------------------------------------------------
        console.log("\n--- Mock Dependencies ---");

        mockPyth = new MockPyth(3600, 1); // validTimePeriod=1h, fee=1 wei
        console.log("MockPyth:     ", address(mockPyth));

        // 18 decimals to match config's 2e26 initialExchangeRate
        mockUSDC   = new MockERC20("Mock USDC",          "USDC",   18, 10_000_000 ether);
        mockWtCOIN = new MockERC20("Mock Wrapped COIN",  "wtCOIN", 18,  1_000_000 ether);
        console.log("MockUSDC:     ", address(mockUSDC));
        console.log("MockWtCOIN:   ", address(mockWtCOIN));

        _seedMockPrices();
        console.log("MockPyth seeded: USDC=$1, COIN=$250");

        // ----------------------------------------------------------
        // 2. Core
        // ----------------------------------------------------------
        console.log("\n--- Core Contracts ---");

        interestRateModel = new JumpRateModel(
            configFile.readUint(".interestRateModel.baseRatePerYear"),
            configFile.readUint(".interestRateModel.multiplierPerYear"),
            configFile.readUint(".interestRateModel.jumpMultiplierPerYear"),
            configFile.readUint(".interestRateModel.kink")
        );
        console.log("JumpRateModel:", address(interestRateModel));

        unitroller = new Unitroller();
        blotroller = new Blotroller();
        unitroller._setPendingImplementation(address(blotroller));
        blotroller._become(unitroller);
        console.log("Unitroller:   ", address(unitroller));
        console.log("Blotroller:   ", address(blotroller));

        bErc20Delegate = new BErc20Delegate();
        console.log("BErc20Delegate:", address(bErc20Delegate));

        // ----------------------------------------------------------
        // 3. Oracle
        // ----------------------------------------------------------
        console.log("\n--- Oracle ---");

        priceOracle = new BlockStreetPriceOracle(IPyth(address(mockPyth)), 14400);
        console.log("BlockStreetPriceOracle:", address(priceOracle));

        // ----------------------------------------------------------
        // 4. Protocol init
        // ----------------------------------------------------------
        console.log("\n--- Protocol Init ---");

        Blotroller comptroller = Blotroller(payable(address(unitroller)));
        comptroller._setPriceOracle(PriceOracle(address(priceOracle)));
        comptroller._setCloseFactor(configFile.readUint(".protocol.closeFactor"));
        comptroller._setLiquidationIncentive(configFile.readUint(".protocol.liquidationIncentive"));
        comptroller._setPauseGuardian(msg.sender);
        comptroller._setBorrowCapGuardian(msg.sender);

        accessController = new AccessController();
        accessController.setAllowed(msg.sender, true);
        require(comptroller._setAccessController(address(accessController)) == 0, "set AC failed");
        console.log("AccessController:", address(accessController));
        console.log("Protocol parameters set");

        // ----------------------------------------------------------
        // 5. Markets: bUSDC + bwtCOIN
        // ----------------------------------------------------------
        console.log("\n--- Markets ---");

        bUSDC = new BErc20Delegator(
            address(mockUSDC),
            BlotrollerInterface(address(unitroller)),
            InterestRateModel(address(interestRateModel)),
            configFile.readUint(".markets.USDC.initialExchangeRate"),
            configFile.readString(".markets.USDC.name"),
            configFile.readString(".markets.USDC.symbol"),
            uint8(configFile.readUint(".markets.USDC.decimals")),
            payable(msg.sender),
            address(bErc20Delegate),
            ""
        );
        console.log("bUSDC:        ", address(bUSDC));

        bwtCOIN = new BErc20Delegator(
            address(mockWtCOIN),
            BlotrollerInterface(address(unitroller)),
            InterestRateModel(address(interestRateModel)),
            configFile.readUint(".markets.wtCOIN.initialExchangeRate"),
            configFile.readString(".markets.wtCOIN.name"),
            configFile.readString(".markets.wtCOIN.symbol"),
            uint8(configFile.readUint(".markets.wtCOIN.decimals")),
            payable(msg.sender),
            address(bErc20Delegate),
            ""
        );
        console.log("bwtCOIN:      ", address(bwtCOIN));

        // ----------------------------------------------------------
        // 6. Oracle asset configs (must precede collateralFactor)
        // ----------------------------------------------------------
        console.log("\n--- Oracle Config ---");

        address[] memory bTokens = new address[](2);
        BlockStreetPriceOracle.AssetConfig[] memory configs =
            new BlockStreetPriceOracle.AssetConfig[](2);

        bTokens[0] = address(bUSDC);
        configs[0] = BlockStreetPriceOracle.AssetConfig({
            underlying:         address(mockUSDC),
            baseUnit:           1e18,
            pythPriceId:        USDC_USD_PRICE_ID,
            maxPriceAge:        3600,
            maxConfidenceRatio: 100 // 1%
        });

        bTokens[1] = address(bwtCOIN);
        configs[1] = BlockStreetPriceOracle.AssetConfig({
            underlying:         address(mockWtCOIN),
            baseUnit:           1e18,
            pythPriceId:        COIN_USD_PRICE_ID,
            maxPriceAge:        3600,
            maxConfidenceRatio: 200 // 2%
        });

        priceOracle.setAssetConfigs(bTokens, configs);
        console.log("Oracle: bUSDC + bwtCOIN configured");

        // ----------------------------------------------------------
        // 7. Market setup: support + CF + borrow cap + reserve factor
        // ----------------------------------------------------------
        console.log("\n--- Market Setup ---");

        _setupMarket(
            comptroller,
            BToken(address(bUSDC)),
            bUSDC,
            configFile.readUint(".markets.USDC.collateralFactor"),
            configFile.readUint(".markets.USDC.borrowCap"),
            configFile.readUint(".markets.USDC.reserveFactor")
        );
        _setupMarket(
            comptroller,
            BToken(address(bwtCOIN)),
            bwtCOIN,
            configFile.readUint(".markets.wtCOIN.collateralFactor"),
            configFile.readUint(".markets.wtCOIN.borrowCap"),
            configFile.readUint(".markets.wtCOIN.reserveFactor")
        );
        console.log("Markets fully configured");

        vm.stopBroadcast();

        // ----------------------------------------------------------
        // 8. Summary + persist addresses
        // ----------------------------------------------------------
        console.log("\n=== Deployment Summary (BSC Testnet, chainId=97) ===");
        console.log("MockPyth:            ", address(mockPyth));
        console.log("MockUSDC:            ", address(mockUSDC));
        console.log("MockWtCOIN:          ", address(mockWtCOIN));
        console.log("Unitroller:          ", address(unitroller));
        console.log("Blotroller:          ", address(blotroller));
        console.log("PriceOracle:         ", address(priceOracle));
        console.log("InterestRateModel:   ", address(interestRateModel));
        console.log("BErc20Delegate:      ", address(bErc20Delegate));
        console.log("bUSDC:               ", address(bUSDC));
        console.log("bwtCOIN:             ", address(bwtCOIN));
        console.log("AccessController:    ", address(accessController));

        string memory json = "{}";
        vm.serializeAddress(json, "mockPyth",          address(mockPyth));
        vm.serializeAddress(json, "mockUSDC",          address(mockUSDC));
        vm.serializeAddress(json, "mockWtCOIN",        address(mockWtCOIN));
        vm.serializeAddress(json, "unitroller",        address(unitroller));
        vm.serializeAddress(json, "blotroller",        address(blotroller));
        vm.serializeAddress(json, "priceOracle",       address(priceOracle));
        vm.serializeAddress(json, "interestRateModel", address(interestRateModel));
        vm.serializeAddress(json, "bErc20Delegate",    address(bErc20Delegate));
        vm.serializeAddress(json, "bUSDC",             address(bUSDC));
        vm.serializeAddress(json, "bwtCOIN",           address(bwtCOIN));
        json = vm.serializeAddress(json, "accessController", address(accessController));

        try vm.writeJson(json, "deployments/bsc_testnet-latest.json") {
            console.log("\nAddresses saved to deployments/bsc_testnet-latest.json");
        } catch {
            console.log("\nFailed to save addresses file");
        }
    }

    // =================================================================
    // helpers
    // =================================================================

    function _seedMockPrices() internal {
        bytes[] memory upd = new bytes[](2);
        upd[0] = mockPyth.createPriceFeedUpdateData(
            USDC_USD_PRICE_ID,
            MOCK_USDC_PRICE, MOCK_USDC_CONF, MOCK_EXPO,
            MOCK_USDC_PRICE, MOCK_USDC_CONF,
            uint64(block.timestamp),
            uint64(block.timestamp - 1)
        );
        upd[1] = mockPyth.createPriceFeedUpdateData(
            COIN_USD_PRICE_ID,
            MOCK_COIN_PRICE, MOCK_COIN_CONF, MOCK_EXPO,
            MOCK_COIN_PRICE, MOCK_COIN_CONF,
            uint64(block.timestamp),
            uint64(block.timestamp - 1)
        );
        // fee = 1 wei per update, 2 updates -> 2 wei
        mockPyth.updatePriceFeeds{value: 2}(upd);
    }

    function _setupMarket(
        Blotroller comptroller,
        BToken bToken,
        BErc20Delegator delegator,
        uint collateralFactor,
        uint borrowCap,
        uint reserveFactor
    ) internal {
        comptroller._supportMarket(bToken);
        comptroller._setCollateralFactor(bToken, collateralFactor);

        BToken[] memory capTokens = new BToken[](1);
        uint[]   memory caps      = new uint[](1);
        capTokens[0] = bToken;
        caps[0]      = borrowCap;
        comptroller._setMarketBorrowCaps(capTokens, caps);

        delegator._setReserveFactor{gas: 500000}(reserveFactor);
    }
}
