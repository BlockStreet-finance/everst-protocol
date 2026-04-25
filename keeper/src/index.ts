import { ethers } from "ethers";
import { HermesClient } from "@pythnetwork/hermes-client";
import { loadConfig } from "./config.js";
import { updatePriceFeeds, PYTH_ABI } from "./updater.js";
import { checkFreshness } from "./monitor.js";
import { AlertLevel, sendAlert } from "./alerter.js";
import { getMarketStatus, MarketState } from "./market-hours.js";

async function main() {
  const config = loadConfig();

  console.log("=== BlockStreet Pyth Keeper ===");
  console.log(`RPC: ${config.rpcUrl}`);
  console.log(`Pyth: ${config.pythAddress}`);
  console.log(`Feeds: ${config.feeds.length}`);
  console.log(`Interval: ${config.updateIntervalMs / 1000}s`);
  console.log(`Deviation threshold: ${config.priceDeviationBps}bps (${config.priceDeviationBps / 100}%)`);
  console.log(`Force update staleness: ${config.maxStalenessBeforeForceUpdateSec}s`);
  console.log(`Market hours only: ${config.marketHoursOnly}`);
  console.log(`Dry run: ${config.dryRun}`);
  console.log("");

  const provider = new ethers.JsonRpcProvider(config.rpcUrl);
  const wallet = new ethers.Wallet(config.keeperPrivateKey, provider);

  console.log(`Keeper wallet: ${wallet.address}`);

  const pythContract = new ethers.Contract(config.pythAddress, PYTH_ABI, wallet);
  const hermesClient = new HermesClient(config.hermesUrl);

  // Main loop
  async function tick() {
    try {
      const status = getMarketStatus();
      const et = new Date().toLocaleString("en-US", { timeZone: "America/New_York" });

      console.log(`\n[${et} ET] Market: ${status.state} | staleness threshold: ${Math.round(status.maxStaleSec / 3600)}h | update: ${status.shouldUpdate}`);

      if (config.marketHoursOnly && !status.shouldUpdate) {
        console.log(`  [Skip] Market ${status.state}, not pushing updates`);
        // Still check freshness with dynamic threshold
        await checkFreshness(pythContract, config.feeds, status.maxStaleSec);
        return;
      }

      // Push latest Pyth VAAs to on-chain
      await updatePriceFeeds(
        hermesClient,
        pythContract,
        config.feeds,
        config.priceDeviationBps,
        config.maxStalenessBeforeForceUpdateSec,
        config.dryRun,
      );

      // Check price freshness with market-state-aware threshold
      await checkFreshness(pythContract, config.feeds, status.maxStaleSec);
    } catch (err) {
      sendAlert({
        level: AlertLevel.ERROR,
        feed: "main-loop",
        message: `Unhandled error in tick: ${err}`,
        timestamp: new Date(),
      });
    }
  }

  // Run immediately, then schedule next tick after completion (serial, no overlap)
  async function loop() {
    await tick();
    setTimeout(loop, config.updateIntervalMs);
  }

  await loop();
  console.log("Keeper running. Press Ctrl+C to stop.");
}

main().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
