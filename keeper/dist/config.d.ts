import "dotenv/config";
export interface FeedConfig {
    bTokenAddress: string;
    pythPriceId: string;
}
export interface KeeperConfig {
    rpcUrl: string;
    keeperPrivateKey: string;
    pythAddress: string;
    hermesUrl: string;
    feeds: FeedConfig[];
    updateIntervalMs: number;
    maxPriceAgeSec: number;
    priceDeviationBps: number;
    maxStalenessBeforeForceUpdateSec: number;
    marketHoursOnly: boolean;
    dryRun: boolean;
}
export declare function loadConfig(): KeeperConfig;
