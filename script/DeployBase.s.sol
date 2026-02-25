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
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";

contract DeployBaseScript is Script {
    using stdJson for string;

    // Deployment configuration
    struct Config {
        uint256 closeFactor;
        uint256 liquidationIncentive;
        uint256 maxAssets;
        address admin;
        address pauseGuardian;
        address borrowCapGuardian;
        InterestRateConfig interestRate;
        MarketConfig wtCOINMarket;
        // External contracts
        address pythAddress;
        bytes32 coinUsdPriceId;
    }

    struct InterestRateConfig {
        uint256 baseRatePerYear;
        uint256 multiplierPerYear;
        uint256 jumpMultiplierPerYear;
        uint256 kink;
    }

    struct MarketConfig {
        string name;
        string symbol;
        uint8 decimals;
        address underlying;
        uint256 collateralFactor;
        uint256 reserveFactor;
        uint256 borrowCap;
        uint256 initialExchangeRate;
    }

    // Deployed contracts
    Unitroller public unitroller;
    Blotroller public blotroller;
    BlockStreetPriceOracle public priceOracle;
    JumpRateModel public interestRateModel;
    BErc20Delegate public bErc20Delegate;
    BErc20Delegator public bwtCOIN;

    Config public config;
    string public network;

    function run() external {
        _loadConfig();

        vm.startBroadcast();

        console.log("=== BlockStreet Protocol Deployment (Base) ===");
        console.log("Network:", network);
        console.log("Deployer:", msg.sender);
        console.log("Admin:", config.admin);

        _deployCore();
        _deployOracle();
        _initializeProtocol();
        _deployMarkets();
        _setupMarkets();
        _configureOracle();
        _transferOwnership();

        vm.stopBroadcast();

        _saveDeploymentAddresses();
        _logDeployment();
    }

    // ================================================================
    // Configuration
    // ================================================================

    function _loadConfig() internal {
        if (block.chainid == 8453) {
            network = "base_mainnet";
        } else if (block.chainid == 84532) {
            network = "base_sepolia";
        } else {
            revert("Unsupported network: expected Base Mainnet (8453) or Base Sepolia (84532)");
        }

        string memory configFile = vm.readFile("config/deploy.json");

        // Protocol config
        config.closeFactor = configFile.readUint(".protocol.closeFactor");
        config.liquidationIncentive = configFile.readUint(".protocol.liquidationIncentive");
        config.maxAssets = configFile.readUint(".protocol.maxAssets");

        // Governance config — env vars override JSON, deployer as final fallback
        address jsonAdmin = configFile.readAddress(".governance.admin");
        address jsonPauseGuardian = configFile.readAddress(".governance.pauseGuardian");
        address jsonBorrowCapGuardian = configFile.readAddress(".governance.borrowCapGuardian");

        config.admin = vm.envOr("ADMIN_ADDRESS", jsonAdmin != address(0) ? jsonAdmin : msg.sender);
        config.pauseGuardian = vm.envOr("PAUSE_GUARDIAN", jsonPauseGuardian != address(0) ? jsonPauseGuardian : config.admin);
        config.borrowCapGuardian = vm.envOr("BORROW_CAP_GUARDIAN", jsonBorrowCapGuardian != address(0) ? jsonBorrowCapGuardian : config.admin);

        // Interest rate model
        string memory irPath = ".interestRateModel";
        config.interestRate.baseRatePerYear = configFile.readUint(string.concat(irPath, ".baseRatePerYear"));
        config.interestRate.multiplierPerYear = configFile.readUint(string.concat(irPath, ".multiplierPerYear"));
        config.interestRate.jumpMultiplierPerYear = configFile.readUint(string.concat(irPath, ".jumpMultiplierPerYear"));
        config.interestRate.kink = configFile.readUint(string.concat(irPath, ".kink"));

        // External contracts
        string memory extPath = string.concat(".externalContracts.", network);
        config.pythAddress = configFile.readAddress(string.concat(extPath, ".pyth"));
        config.coinUsdPriceId = configFile.readBytes32(string.concat(extPath, ".pythPriceIds.COIN_USD"));

        // Market config: wtCOIN
        _loadMarketConfig("wtCOIN", config.wtCOINMarket);
    }

    function _loadMarketConfig(string memory market, MarketConfig storage marketConfig) internal {
        string memory configFile = vm.readFile("config/deploy.json");
        string memory basePath = string.concat(".markets.", market);

        marketConfig.name = configFile.readString(string.concat(basePath, ".name"));
        marketConfig.symbol = configFile.readString(string.concat(basePath, ".symbol"));
        marketConfig.decimals = uint8(configFile.readUint(string.concat(basePath, ".decimals")));

        string memory underlyingPath = string.concat(basePath, ".underlying.", network);
        marketConfig.underlying = configFile.readAddress(underlyingPath);

        marketConfig.collateralFactor = configFile.readUint(string.concat(basePath, ".collateralFactor"));
        marketConfig.reserveFactor = configFile.readUint(string.concat(basePath, ".reserveFactor"));
        marketConfig.borrowCap = configFile.readUint(string.concat(basePath, ".borrowCap"));
        marketConfig.initialExchangeRate = configFile.readUint(string.concat(basePath, ".initialExchangeRate"));
    }

    // ================================================================
    // Core deployment
    // ================================================================

    function _deployCore() internal {
        console.log("\n=== Deploying Core Contracts ===");

        unitroller = new Unitroller();
        console.log("Unitroller deployed:", address(unitroller));

        blotroller = new Blotroller();
        console.log("Blotroller deployed:", address(blotroller));

        interestRateModel = new JumpRateModel(
            config.interestRate.baseRatePerYear,
            config.interestRate.multiplierPerYear,
            config.interestRate.jumpMultiplierPerYear,
            config.interestRate.kink
        );
        console.log("JumpRateModel deployed:", address(interestRateModel));

        bErc20Delegate = new BErc20Delegate();
        console.log("BErc20Delegate deployed:", address(bErc20Delegate));

        // Wire proxy → implementation
        unitroller._setPendingImplementation(address(blotroller));
        blotroller._become(unitroller);
        console.log("Blotroller implementation set");
    }

    // ================================================================
    // Oracle deployment (BlockStreetPriceOracle — pure Pyth)
    // ================================================================

    function _deployOracle() internal {
        console.log("\n=== Deploying BlockStreetPriceOracle ===");

        uint32 maxFallbackAge = 14400; // 4 hours
        priceOracle = new BlockStreetPriceOracle(IPyth(config.pythAddress), maxFallbackAge);
        console.log("BlockStreetPriceOracle deployed:", address(priceOracle));
        console.log("  Pyth contract:", config.pythAddress);
        console.log("  maxFallbackAge:", maxFallbackAge);
    }

    // ================================================================
    // Protocol initialization
    // ================================================================

    function _initializeProtocol() internal {
        console.log("\n=== Initializing Protocol ===");

        Blotroller comptroller = Blotroller(payable(address(unitroller)));

        comptroller._setPriceOracle(PriceOracle(address(priceOracle)));
        console.log("Price oracle set");

        comptroller._setCloseFactor(config.closeFactor);
        console.log("Close factor set to:", config.closeFactor / 1e16, "%");

        comptroller._setLiquidationIncentive(config.liquidationIncentive);
        console.log("Liquidation incentive set to:", (config.liquidationIncentive - 1e18) / 1e16, "%");

        comptroller._setPauseGuardian(config.pauseGuardian);
        console.log("Pause guardian set");

        comptroller._setBorrowCapGuardian(config.borrowCapGuardian);
        console.log("Borrow cap guardian set");
    }

    // ================================================================
    // Market deployment
    // ================================================================

    function _deployMarkets() internal {
        console.log("\n=== Deploying Markets ===");

        bwtCOIN = new BErc20Delegator(
            config.wtCOINMarket.underlying,
            BlotrollerInterface(address(unitroller)),
            InterestRateModel(address(interestRateModel)),
            config.wtCOINMarket.initialExchangeRate,
            config.wtCOINMarket.name,
            config.wtCOINMarket.symbol,
            config.wtCOINMarket.decimals,
            payable(msg.sender),
            address(bErc20Delegate),
            ""
        );
        console.log("bwtCOIN deployed:", address(bwtCOIN));
        console.log("  underlying (wtCOIN):", config.wtCOINMarket.underlying);
    }

    // ================================================================
    // Market setup
    // ================================================================

    function _setupMarkets() internal {
        console.log("\n=== Setting Up Markets ===");

        Blotroller comptroller = Blotroller(payable(address(unitroller)));

        comptroller._supportMarket(BToken(address(bwtCOIN)));
        console.log("wtCOIN market supported");

        comptroller._setCollateralFactor(BToken(address(bwtCOIN)), config.wtCOINMarket.collateralFactor);
        console.log("wtCOIN collateral factor:", config.wtCOINMarket.collateralFactor / 1e16, "%");

        BToken[] memory bTokens = new BToken[](1);
        uint[] memory borrowCaps = new uint[](1);
        bTokens[0] = BToken(address(bwtCOIN));
        borrowCaps[0] = config.wtCOINMarket.borrowCap;
        comptroller._setMarketBorrowCaps(bTokens, borrowCaps);
        console.log("Borrow cap set");

        bwtCOIN._setReserveFactor{gas: 500000}(config.wtCOINMarket.reserveFactor);
        console.log("Reserve factor set");
    }

    // ================================================================
    // Oracle configuration — bind bwtCOIN to Pyth COIN/USD feed
    // ================================================================

    function _configureOracle() internal {
        console.log("\n=== Configuring Oracle ===");

        address[] memory bTokens = new address[](1);
        BlockStreetPriceOracle.AssetConfig[] memory configs = new BlockStreetPriceOracle.AssetConfig[](1);

        bTokens[0] = address(bwtCOIN);
        configs[0] = BlockStreetPriceOracle.AssetConfig({
            underlying: config.wtCOINMarket.underlying,  // wtCOIN
            baseUnit: 1e18,                               // 18 decimals
            pythPriceId: config.coinUsdPriceId,           // COIN/USD
            maxPriceAge: 3600,                            // 1 hour
            maxConfidenceRatio: 200                       // 2%
        });

        priceOracle.setAssetConfigs(bTokens, configs);
        console.log("Oracle configured: bwtCOIN -> COIN/USD Pyth feed");
    }

    // ================================================================
    // Ownership transfer
    // ================================================================

    function _transferOwnership() internal {
        console.log("\n=== Transferring Ownership ===");

        if (config.admin != msg.sender) {
            // Oracle ownership
            priceOracle.transferOwnership(config.admin);
            console.log("Oracle ownership transferred to:", config.admin);

            // Unitroller admin
            unitroller._setPendingAdmin(payable(config.admin));
            console.log("Unitroller admin transfer initiated to:", config.admin);

            // Market admin
            bwtCOIN._setPendingAdmin(payable(config.admin));
            console.log("bwtCOIN admin transfer initiated");

            console.log("IMPORTANT: New admin must call _acceptAdmin() on Unitroller and bwtCOIN");
        }
    }

    // ================================================================
    // Deployment output
    // ================================================================

    function _saveDeploymentAddresses() internal {
        console.log("\n=== Saving Deployment Addresses ===");
        console.log("Network:", network);
        console.log("Chain ID:", block.chainid);

        string memory addressesJson = "{}";

        // Core contracts
        vm.serializeAddress(addressesJson, "unitroller", address(unitroller));
        vm.serializeAddress(addressesJson, "blotroller", address(blotroller));
        vm.serializeAddress(addressesJson, "priceOracle", address(priceOracle));
        vm.serializeAddress(addressesJson, "interestRateModel", address(interestRateModel));
        vm.serializeAddress(addressesJson, "bErc20Delegate", address(bErc20Delegate));

        // Market contracts
        addressesJson = vm.serializeAddress(addressesJson, "bwtCOIN", address(bwtCOIN));

        console.log("Serialized JSON length:", bytes(addressesJson).length);

        string memory fileName = string.concat("deployments/", network, "-latest.json");
        console.log("Attempting to write to:", fileName);

        try vm.writeJson(addressesJson, fileName) {
            console.log("Addresses saved successfully to:", fileName);
        } catch Error(string memory reason) {
            console.log("Failed to save addresses:", reason);
        } catch {
            console.log("Failed to save addresses: Unknown error");
        }
    }

    function _logDeployment() internal view {
        console.log("\n=== Deployment Summary ===");
        console.log("Network:", network);
        console.log("Unitroller:", address(unitroller));
        console.log("Blotroller:", address(blotroller));
        console.log("PriceOracle:", address(priceOracle));
        console.log("InterestRateModel:", address(interestRateModel));
        console.log("BErc20Delegate:", address(bErc20Delegate));
        console.log("bwtCOIN:", address(bwtCOIN));
        console.log("Admin:", config.admin);

        console.log("\n=== Next Steps ===");
        console.log("1. Verify contracts on BaseScan");
        console.log("2. Accept admin role from Safe multisig");
        console.log("3. Start Keeper service to push Pyth price updates");
        console.log("4. Test: cast call <bwtCOIN> 'getUnderlyingPrice(address)' <bwtCOIN>");
    }
}
