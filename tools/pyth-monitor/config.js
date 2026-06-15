// Configuration for the Pyth feed monitor.
// You only list the stock TICKERS you care about. At startup the app loops over
// them, discovers the matching Pyth feed ids from Hermes, and stores the catalog
// in SQLite — no hand-copied feed ids. Stocks that lack a given feed (e.g. MSFT
// has no xStock proxy) simply won't be found and are skipped automatically.

const env = process.env;

/** Stock tickers to monitor. Override with TICKERS="COIN,TSLA,...".
 *  SPCX (SpaceX, IPO'd 2026-06-12) is included as a placeholder — Pyth has no feed
 *  for it yet, so discovery finds nothing and skips it. It will appear automatically
 *  once Pyth publishes a feed and the app is restarted. */
export const TICKERS = (env.TICKERS || "COIN,TSLA,MSTR,MSFT,ORCL,SPCX")
  .split(",").map((s) => s.trim().toUpperCase()).filter(Boolean);

/**
 * The per-stock feed template. For each ticker T we look for these exact Pyth
 * symbols; whichever exist get recorded with the given session label.
 *   regular/pre/post/overnight -> session-split equity feeds
 *   24/7                        -> tokenized xStock crypto proxy
 *   rr                          -> xStock<->stock redemption rate (peg monitor)
 */
export const SESSION_TEMPLATES = [
  { session: "regular",   symbol: (t) => `Equity.US.${t}/USD` },
  { session: "pre",       symbol: (t) => `Equity.US.${t}/USD.PRE` },
  { session: "post",      symbol: (t) => `Equity.US.${t}/USD.POST` },
  { session: "overnight", symbol: (t) => `Equity.US.${t}/USD.ON` },
  { session: "24/7",      symbol: (t) => `Crypto.${t}X/USD` },
  { session: "rr",        symbol: (t) => `Crypto.${t}X/${t}.RR` },
];

export const CONFIG = {
  hermesUrl: env.HERMES_URL || "https://hermes.pyth.network",
  port: Number(env.PORT || 8787),
  pollIntervalSec: Number(env.POLL_INTERVAL_SEC || 20),
  dbPath: env.DB_PATH || "./data/pyth.db",
  // A feed is considered "fresh" (i.e. its session is active) if its on-chain-style
  // age is within this many seconds. Equity feeds only update inside their session,
  // so this is what tells us which session is live.
  freshnessSec: Number(env.FRESHNESS_SEC || 90),
};

/** Normalize a feed id to lowercase, no 0x prefix (Hermes returns ids that way). */
export function normId(id) {
  return id.toLowerCase().replace(/^0x/, "");
}
