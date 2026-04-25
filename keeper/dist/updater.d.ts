import { HermesClient } from "@pythnetwork/hermes-client";
import type { ethers } from "ethers";
import type { FeedConfig } from "./config.js";
declare const PYTH_ABI: string[];
export { PYTH_ABI };
/**
 * Fetches the latest VAAs from Hermes and submits updatePriceFeeds
 * only when price deviates beyond threshold or on-chain data is too stale.
 */
export declare function updatePriceFeeds(hermesClient: HermesClient, pythContract: ethers.Contract, feeds: FeedConfig[], priceDeviationBps: number, maxStalenessSec: number, dryRun?: boolean): Promise<boolean>;
