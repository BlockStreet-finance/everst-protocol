import type { ethers } from "ethers";
import type { FeedConfig } from "./config.js";
/**
 * Checks whether the on-chain Pyth price for each feed is still fresh.
 * Alerts if the price is older than maxAgeSec.
 */
export declare function checkFreshness(pythContract: ethers.Contract, feeds: FeedConfig[], maxAgeSec: number): Promise<void>;
