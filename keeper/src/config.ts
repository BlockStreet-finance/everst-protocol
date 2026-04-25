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

function requireEnv(name: string): string {
  const val = process.env[name];
  if (!val) throw new Error(`Missing required env var: ${name}`);
  return val;
}

export function loadConfig(): KeeperConfig {
  const bTokens = requireEnv("BTOKEN_ADDRESSES").split(",").map((s) => s.trim());
  const priceIds = requireEnv("PYTH_PRICE_IDS").split(",").map((s) => s.trim());

  if (bTokens.length !== priceIds.length) {
    throw new Error("BTOKEN_ADDRESSES and PYTH_PRICE_IDS must have equal length");
  }

  const feeds: FeedConfig[] = bTokens.map((bTokenAddress, i) => ({
    bTokenAddress,
    pythPriceId: priceIds[i],
  }));

  return {
    rpcUrl: requireEnv("RPC_URL"),
    keeperPrivateKey: requireEnv("KEEPER_PRIVATE_KEY"),
    pythAddress: requireEnv("PYTH_ADDRESS"),
    hermesUrl: process.env["HERMES_URL"] || "https://hermes.pyth.network",
    feeds,
    updateIntervalMs: (parseInt(process.env["UPDATE_INTERVAL_SEC"] || "30", 10)) * 1000,
    maxPriceAgeSec: parseInt(process.env["MAX_PRICE_AGE_SEC"] || "3600", 10),
    priceDeviationBps: parseInt(process.env["PRICE_DEVIATION_BPS"] || "50", 10),
    maxStalenessBeforeForceUpdateSec: parseInt(process.env["MAX_STALENESS_BEFORE_FORCE_UPDATE_SEC"] || "1800", 10),
    marketHoursOnly: process.env["MARKET_HOURS_ONLY"] === "true" || process.env["MARKET_HOURS_ONLY"] === "1",
    dryRun: process.env["DRY_RUN"] === "true" || process.env["DRY_RUN"] === "1",
  };
}
