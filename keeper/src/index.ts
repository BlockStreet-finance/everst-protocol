import { ethers } from "ethers";
import { HermesClient } from "@pythnetwork/hermes-client";
import { loadConfig } from "./config.js";
import { updatePriceFeeds, PYTH_ABI } from "./updater.js";
import { checkFreshness } from "./monitor.js";
import { AlertLevel, sendAlert } from "./alerter.js";

/**
 * Check if US stock market is currently open.
 * Regular hours: Mon-Fri, 9:30 AM – 4:00 PM Eastern Time.
 */
function isUSMarketOpen(): boolean {
  const now = new Date();
  const et = new Date(now.toLocaleString("en-US", { timeZone: "America/New_York" }));
  const day = et.getDay(); // 0=Sun, 6=Sat
  if (day === 0 || day === 6) return false;
  const mins = et.getHours() * 60 + et.getMinutes();
  return mins >= 9 * 60 + 30 && mins < 16 * 60;
}

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
      if (config.marketHoursOnly && !isUSMarketOpen()) {
        const et = new Date().toLocaleString("en-US", { timeZone: "America/New_York" });
        console.log(`  [Market closed] ${et} ET — skipping`);
        return;
      }

      // 1. Push latest Pyth VAAs to on-chain Pyth contract
      await updatePriceFeeds(hermesClient, pythContract, config.feeds, config.priceDeviationBps, config.maxStalenessBeforeForceUpdateSec, config.dryRun);

      // 2. Check price freshness
      await checkFreshness(pythContract, config.feeds, config.maxPriceAgeSec);
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
