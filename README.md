# BlockStreet Protocol

A decentralized lending protocol for tokenized real-world assets (stocks, ETFs) built on Base.

## Deployed Contracts

### Base Mainnet

| Contract | Address |
|----------|---------|
| Unitroller (Proxy) | [`0x9c2c94E1a47EFdF1Ce35DFb0b3768D45C3CfF83E`](https://basescan.org/address/0x9c2c94E1a47EFdF1Ce35DFb0b3768D45C3CfF83E) |
| Blotroller (Impl) | [`0x0e666458927C2f0a5f1b4bD9bA648976755b840c`](https://basescan.org/address/0x0e666458927C2f0a5f1b4bD9bA648976755b840c) |
| BlockStreetPriceOracle | [`0xd037322B15E718cbF10C1f7d952a08c77031A574`](https://basescan.org/address/0xd037322B15E718cbF10C1f7d952a08c77031A574) |
| JumpRateModel | [`0x474FB2F826af89653B0Dfbd251bc521AFca1A19f`](https://basescan.org/address/0x474FB2F826af89653B0Dfbd251bc521AFca1A19f) |
| BErc20Delegate (Impl) | [`0x11df8c6B779dc24D867fD743162360C95BA83107`](https://basescan.org/address/0x11df8c6B779dc24D867fD743162360C95BA83107) |
| bwtCOIN | [`0x9F719F632c203ef1705e6aBB855AC86F04cE0D37`](https://basescan.org/address/0x9F719F632c203ef1705e6aBB855AC86F04cE0D37) |

**Markets:**

| Market | Underlying | Collateral Factor | Reserve Factor | Borrow Cap |
|--------|-----------|-------------------|----------------|------------|
| bwtCOIN | [wtCOIN](https://basescan.org/address/0x5cDa0E1CA4ce2af96315f7F8963C85399c172204) `0x5cDa0E1CA4ce2af96315f7F8963C85399c172204` | 50% | 20% | 100K |

**Protocol Parameters:**

| Parameter | Value |
|-----------|-------|
| Close Factor | 50% |
| Liquidation Incentive | 108% |
| Admin | `0x62bdd47787ff9ac1eb0f62ba800db821ed0323e1` |

**Oracle:**

| Item | Value |
|------|-------|
| Price source | Pyth Network (pure Pyth, no Chainlink) |
| Pyth contract (Base) | `0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a` |
| COIN/USD Price ID | `0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245` |
| On-chain maxPriceAge | 72h (safety backstop; keeper controls actual freshness) |
| Confidence ratio threshold | 2% |
| Admin fallback maxAge | 4h |

**Interest Rate Model:**

| Parameter | Value |
|-----------|-------|
| Base Rate | 2% APY |
| Multiplier | 20% APY |
| Jump Multiplier | 200% APY |
| Kink | 80% utilization |

### Base Sepolia (Testnet)

| Contract | Address |
|----------|---------|
| MockPyth | `0x9c2c94E1a47EFdF1Ce35DFb0b3768D45C3CfF83E` |
| MockWtCOIN | `0x0e666458927C2f0a5f1b4bD9bA648976755b840c` |
| Unitroller | `0x97FCa6ad362bC5de29a4Dc39CE305812e762F4cB` |
| Blotroller | `0x2517730f43051D6beE7194a2a9bdD11bdc59AacE` |
| PriceOracle | `0x96A2668856a2C6E6dfE2c322BF64b1579b52B7e3` |
| InterestRateModel | `0x11df8c6B779dc24D867fD743162360C95BA83107` |
| BErc20Delegate | `0x2b3c39ed4F252B591f01e7437A15a9f11e23f48c` |
| bwtCOIN | `0x7706fD8245E400c71109B23a286272608bB5afa4` |

### BSC Testnet (Legacy)

```
Core Contracts:
  Unitroller: 0x5a66463Bc17ecefA01920bea61980d1b4Fe0E5a5
  Blotroller: 0x96f6d18bA601D21E7A2816762f61b178b8D1d91f
  Price Oracle: 0x96ca588c9A216B2561cA56f0E4215a6A05DA2fd0
  Interest Rate Model: 0x55Fc55e6177F8d16689BA121B6aFeF3cC9eC2a63
  BErc20 Delegate: 0xBD0392Bd4992fE2D6a880fF24008579267a22E26

Market Contracts:
  bUSDC: 0x1fa8b126D273e571499cc62f56B609D9882822a9
  bTSLA: 0x9b8A426277f9F12c44dA6BDB6c93a7E66c96F3eD

Test Tokens:
  Mock USDC: 0x64544969ed7EBf5f083679233325356EbE738930
  Mock TSLA: 0x57F61DA3b7FC9df62857b979aA76A16417BeF396
```

## Development

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Deploy

**Base Mainnet:**
```bash
forge script script/DeployBase.s.sol:DeployBaseScript \
    --rpc-url https://mainnet.base.org \
    --account <keystore-name> \
    --sender <deployer-address> \
    --broadcast -vvvv
```

**Base Sepolia (with mocks):**
```bash
forge script script/DeployBaseSepolia.s.sol:DeployBaseSepoliaScript \
    --rpc-url https://sepolia.base.org \
    --account <keystore-name> \
    --sender <deployer-address> \
    --broadcast -vvvv
```

**BSC (legacy):**
```bash
./script/deploy.sh testnet [--verify]
```

### Configuration

Edit `config/deploy.json` to customize deployment parameters.

### Keeper

The Pyth price keeper pushes VAAs on-chain and monitors price freshness with US stock market schedule awareness.

```bash
cd keeper
cp .env.example .env
# Edit .env with your config
npm install
npm start
```
