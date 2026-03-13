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
import "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/**
 * @title DeployBaseSepolia — Full testnet deployment with MockPyth + MockERC20
 * @notice Deploys the entire BlockStreet protocol on Base Sepolia with mock dependencies
 *         so the deployment flow can be validated end-to-end before mainnet.
 *
 * Usage:
 *   forge script script/DeployBaseSepolia.s.sol:DeployBaseSepoliaScript \
 *       --rpc-url https://sepolia.base.org \
 *       --private-key $PRIVATE_KEY \
 *       --broadcast -vvvv
 */
contract DeployBaseSepoliaScript is Script {
    using stdJson for string;

    // ================================================================
    // Deployed contracts
    // ================================================================

    MockPyth public mockPyth;
    MockERC20 public mockWtCOIN;

    Unitroller public unitroller;
    Blotroller public blotroller;
    BlockStreetPriceOracle public priceOracle;
    JumpRateModel public interestRateModel;
    BErc20Delegate public bErc20Delegate;
    BErc20Delegator public bwtCOIN;

    // ================================================================
    // Constants (matching deploy.json & mainnet config)
    // ================================================================

    bytes32 constant COIN_USD_PRICE_ID = 0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245;

    // COIN mock price: $250, expo = -8  →  price = 25000000000
    int64 constant MOCK_COIN_PRICE = 25_000_000_000;
    uint64 constant MOCK_COIN_CONF = 50_000_000; // ~0.2% confidence
    int32 constant MOCK_COIN_EXPO = -8;

    function run() external {
        require(block.chainid == 84532, "This script is for Base Sepolia (84532) only");

        string memory configFile = vm.readFile("config/deploy.json");

        vm.startBroadcast();

        console.log("=== BlockStreet Protocol - Base Sepolia Testnet Deployment ===");
        console.log("Deployer:", msg.sender);

        // ----------------------------------------------------------
        // 1. Deploy mock dependencies
        // ----------------------------------------------------------
        console.log("\n--- Mock Dependencies ---");

        mockPyth = new MockPyth(3600, 1); // validTimePeriod=1h, fee=1wei
        console.log("MockPyth deployed:", address(mockPyth));

        mockWtCOIN = new MockERC20("Mock Wrapped COIN", "wtCOIN", 18, 1_000_000 ether);
        console.log("MockWtCOIN deployed:", address(mockWtCOIN));

        // Feed an initial price into MockPyth
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = mockPyth.createPriceFeedUpdateData(
            COIN_USD_PRICE_ID,
            MOCK_COIN_PRICE,
            MOCK_COIN_CONF,
            MOCK_COIN_EXPO,
            MOCK_COIN_PRICE,
            MOCK_COIN_CONF,
            uint64(block.timestamp),
            uint64(block.timestamp - 1)
        );
        mockPyth.updatePriceFeeds{value: 1}(updateData);
        console.log("MockPyth price fed: COIN/USD = $250");

        // ----------------------------------------------------------
        // 2. Deploy core contracts
        // ----------------------------------------------------------
        console.log("\n--- Core Contracts ---");

        interestRateModel = new JumpRateModel(
            configFile.readUint(".interestRateModel.baseRatePerYear"),
            configFile.readUint(".interestRateModel.multiplierPerYear"),
            configFile.readUint(".interestRateModel.jumpMultiplierPerYear"),
            configFile.readUint(".interestRateModel.kink")
        );
        console.log("JumpRateModel deployed:", address(interestRateModel));

        unitroller = new Unitroller();
        console.log("Unitroller deployed:", address(unitroller));

        blotroller = new Blotroller();
        console.log("Blotroller deployed:", address(blotroller));

        unitroller._setPendingImplementation(address(blotroller));
        blotroller._become(unitroller);
        console.log("Blotroller wired to Unitroller");

        bErc20Delegate = new BErc20Delegate();
        console.log("BErc20Delegate deployed:", address(bErc20Delegate));

        // ----------------------------------------------------------
        // 3. Deploy oracle
        // ----------------------------------------------------------
        console.log("\n--- Oracle ---");

        uint32 maxFallbackAge = 14400; // 4h
        priceOracle = new BlockStreetPriceOracle(IPyth(address(mockPyth)), maxFallbackAge);
        console.log("BlockStreetPriceOracle deployed:", address(priceOracle));

        // ----------------------------------------------------------
        // 4. Initialize protocol
        // ----------------------------------------------------------
        console.log("\n--- Protocol Init ---");

        Blotroller comptroller = Blotroller(payable(address(unitroller)));

        comptroller._setPriceOracle(PriceOracle(address(priceOracle)));
        comptroller._setCloseFactor(configFile.readUint(".protocol.closeFactor"));
        comptroller._setLiquidationIncentive(configFile.readUint(".protocol.liquidationIncentive"));
        comptroller._setPauseGuardian(msg.sender);
        comptroller._setBorrowCapGuardian(msg.sender);
        console.log("Protocol parameters set");

        // ----------------------------------------------------------
        // 5. Deploy bwtCOIN market
        // ----------------------------------------------------------
        console.log("\n--- Market: bwtCOIN ---");

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
        console.log("bwtCOIN deployed:", address(bwtCOIN));

        // ----------------------------------------------------------
        // 6. Configure oracle BEFORE market setup (collateralFactor needs price)
        // ----------------------------------------------------------
        console.log("\n--- Oracle Config ---");

        address[] memory bTokens = new address[](1);
        BlockStreetPriceOracle.AssetConfig[] memory configs = new BlockStreetPriceOracle.AssetConfig[](1);

        bTokens[0] = address(bwtCOIN);
        configs[0] = BlockStreetPriceOracle.AssetConfig({
            underlying: address(mockWtCOIN),
            baseUnit: 1e18,
            pythPriceId: COIN_USD_PRICE_ID,
            maxPriceAge: 3600,
            maxConfidenceRatio: 200 // 2%
        });
        priceOracle.setAssetConfigs(bTokens, configs);
        console.log("Oracle: bwtCOIN -> COIN/USD configured");

        // ----------------------------------------------------------
        // 7. Setup market (support + collateral factor + borrow cap + reserve)
        // ----------------------------------------------------------
        console.log("\n--- Market Setup ---");

        comptroller._supportMarket(BToken(address(bwtCOIN)));
        comptroller._setCollateralFactor(
            BToken(address(bwtCOIN)),
            configFile.readUint(".markets.wtCOIN.collateralFactor")
        );

        BToken[] memory capTokens = new BToken[](1);
        uint[] memory borrowCaps = new uint[](1);
        capTokens[0] = BToken(address(bwtCOIN));
        borrowCaps[0] = configFile.readUint(".markets.wtCOIN.borrowCap");
        comptroller._setMarketBorrowCaps(capTokens, borrowCaps);

        bwtCOIN._setReserveFactor{gas: 500000}(configFile.readUint(".markets.wtCOIN.reserveFactor"));
        console.log("Market fully configured");

        vm.stopBroadcast();

        // ----------------------------------------------------------
        // 8. Summary
        // ----------------------------------------------------------
        console.log("\n=== Deployment Summary (Base Sepolia) ===");
        console.log("MockPyth:            ", address(mockPyth));
        console.log("MockWtCOIN:          ", address(mockWtCOIN));
        console.log("Unitroller:          ", address(unitroller));
        console.log("Blotroller:          ", address(blotroller));
        console.log("PriceOracle:         ", address(priceOracle));
        console.log("InterestRateModel:   ", address(interestRateModel));
        console.log("BErc20Delegate:      ", address(bErc20Delegate));
        console.log("bwtCOIN:             ", address(bwtCOIN));

        // Save addresses
        string memory json = "{}";
        vm.serializeAddress(json, "mockPyth", address(mockPyth));
        vm.serializeAddress(json, "mockWtCOIN", address(mockWtCOIN));
        vm.serializeAddress(json, "unitroller", address(unitroller));
        vm.serializeAddress(json, "blotroller", address(blotroller));
        vm.serializeAddress(json, "priceOracle", address(priceOracle));
        vm.serializeAddress(json, "interestRateModel", address(interestRateModel));
        vm.serializeAddress(json, "bErc20Delegate", address(bErc20Delegate));
        json = vm.serializeAddress(json, "bwtCOIN", address(bwtCOIN));

        try vm.writeJson(json, "deployments/base_sepolia-latest.json") {
            console.log("\nAddresses saved to deployments/base_sepolia-latest.json");
        } catch {
            console.log("\nFailed to save addresses file");
        }
    }
}
