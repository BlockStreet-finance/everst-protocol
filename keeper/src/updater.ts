import { HermesClient } from "@pythnetwork/hermes-client";
import type { ethers } from "ethers";
import type { FeedConfig } from "./config.js";
import { AlertLevel, sendAlert } from "./alerter.js";

// Minimal Pyth ABI for updatePriceFeeds + getUpdateFee
const PYTH_ABI = [
  "function updatePriceFeeds(bytes[] calldata updateData) external payable",
  "function getUpdateFee(bytes[] calldata updateData) external view returns (uint256)",
  "function getPriceUnsafe(bytes32 id) external view returns (tuple(int64 price, uint64 conf, int32 expo, uint256 publishTime))",
];

export { PYTH_ABI };

/**
 * Fetches the latest VAAs from Hermes and submits updatePriceFeeds
 * only when price deviates beyond threshold or on-chain data is too stale.
 */
export async function updatePriceFeeds(
  hermesClient: HermesClient,
  pythContract: ethers.Contract,
  feeds: FeedConfig[],
  priceDeviationBps: number,
  maxStalenessSec: number,
  dryRun = false,
): Promise<boolean> {
  const priceIds = feeds.map((f) => f.pythPriceId);

  // Fetch latest price updates from Hermes
  const updates = await hermesClient.getLatestPriceUpdates(priceIds);

  if (!updates?.binary?.data?.length) {
    sendAlert({
      level: AlertLevel.WARN,
      feed: "all",
      message: "No price update data returned from Hermes",
      timestamp: new Date(),
    });
    return false;
  }

  // Build a map of Hermes prices by id for deviation comparison
  const hermesPriceMap = new Map<string, number>();
  if (updates.parsed) {
    for (const p of updates.parsed) {
      const price = Number(p.price.price) * 10 ** Number(p.price.expo);
      hermesPriceMap.set(p.id, price);
    }
  }

  // Check each feed: deviation or staleness triggers update
  const now = Math.floor(Date.now() / 1000);
  let needsUpdate = false;
  let reason = "";

  for (const feed of feeds) {
    const hermesPrice = hermesPriceMap.get(feed.pythPriceId.replace(/^0x/, ""));
    try {
      const onChain = await pythContract.getPriceUnsafe(feed.pythPriceId);
      const onChainPrice = Number(onChain.price) * 10 ** Number(onChain.expo);
      const publishTime = Number(onChain.publishTime);
      const ageSec = now - publishTime;

      // Force update if on-chain price is too stale
      if (ageSec > maxStalenessSec) {
        needsUpdate = true;
        reason = `stale (age=${ageSec}s > ${maxStalenessSec}s)`;
        break;
      }

      // Check price deviation
      if (hermesPrice && onChainPrice > 0) {
        const deviationBps = Math.abs(hermesPrice - onChainPrice) / onChainPrice * 10000;
        if (deviationBps >= priceDeviationBps) {
          needsUpdate = true;
          reason = `deviation ${deviationBps.toFixed(1)}bps >= ${priceDeviationBps}bps ($${onChainPrice.toFixed(2)} → $${hermesPrice.toFixed(2)})`;
          break;
        }
      }
    } catch {
      // Can't read on-chain price, need to update
      needsUpdate = true;
      reason = "on-chain read failed";
      break;
    }
  }

  // Log Hermes prices every tick
  for (const [id, price] of hermesPriceMap) {
    console.log(`  [Hermes] id=${id.slice(0, 10)}… price=$${price.toFixed(4)}`);
  }

  if (!needsUpdate) {
    console.log(`  [Skip] No update needed`);
    return false;
  }

  console.log(`  [Trigger] ${reason}`);

  // Prepare update data as bytes[] (guard against double 0x prefix)
  const updateData = updates.binary.data.map((d: string) =>
    d.startsWith("0x") ? d : `0x${d}`
  );

  // Get the required fee
  const fee = await pythContract.getUpdateFee(updateData);
  console.log(`  [Fee] updateFee=${fee.toString()} wei`);

  if (dryRun) {
    console.log(`  [DRY RUN] Would submit ${updateData.length} VAA(s) to updatePriceFeeds`);
    return true;
  }

  // Submit the transaction
  const tx = await pythContract.updatePriceFeeds(updateData, { value: fee });
  const receipt = await tx.wait();

  sendAlert({
    level: AlertLevel.INFO,
    feed: "all",
    message: `Price feeds updated (${reason}): tx=${receipt.hash}`,
    timestamp: new Date(),
  });

  return true;
}
