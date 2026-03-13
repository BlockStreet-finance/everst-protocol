/**
 * US Stock Market Schedule
 *
 * Keeper uses this to decide:
 *   - When to push price updates (only during/around market hours)
 *   - What staleness threshold to use for alerts
 *
 * On-chain maxPriceAge is set to 72h as a safety backstop.
 * The actual freshness policy lives here.
 */

// All times in Eastern Time (America/New_York)
const MARKET_OPEN_MINS = 9 * 60 + 30; // 9:30 AM ET
const MARKET_CLOSE_MINS = 16 * 60; // 4:00 PM ET

/** US stock market holidays for 2026 (dates in MM-DD format) */
const HOLIDAYS_2026 = [
  "01-01", // New Year's Day
  "01-19", // MLK Day
  "02-16", // Presidents' Day
  "04-03", // Good Friday
  "05-25", // Memorial Day
  "06-19", // Juneteenth
  "07-03", // Independence Day (observed)
  "09-07", // Labor Day
  "11-26", // Thanksgiving
  "12-25", // Christmas
];

export enum MarketState {
  OPEN = "OPEN",               // Regular trading hours
  OVERNIGHT = "OVERNIGHT",     // Mon-Thu after close -> next day open
  WEEKEND = "WEEKEND",         // Fri close -> Mon open
  HOLIDAY = "HOLIDAY",         // Holiday(s), may extend weekend
}

export interface MarketStatus {
  state: MarketState;
  /** Max acceptable price age (seconds) for alerting in this state */
  maxStaleSec: number;
  /** Whether keeper should actively push price updates */
  shouldUpdate: boolean;
}

/** Staleness thresholds per market state */
const STALE_THRESHOLDS: Record<MarketState, number> = {
  [MarketState.OPEN]: 600,           // 10 min — market is live
  [MarketState.OVERNIGHT]: 17 * 3600, // 17 hours
  [MarketState.WEEKEND]: 66 * 3600,   // 65.5h rounded up
  [MarketState.HOLIDAY]: 90 * 3600,   // 89.5h rounded up
};

function toET(date: Date): Date {
  return new Date(date.toLocaleString("en-US", { timeZone: "America/New_York" }));
}

function getMMDD(et: Date): string {
  const mm = String(et.getMonth() + 1).padStart(2, "0");
  const dd = String(et.getDate()).padStart(2, "0");
  return `${mm}-${dd}`;
}

function isHoliday(et: Date): boolean {
  return HOLIDAYS_2026.includes(getMMDD(et));
}

function isWeekend(et: Date): boolean {
  const day = et.getDay();
  return day === 0 || day === 6;
}

function isWithinTradingHours(et: Date): boolean {
  const mins = et.getHours() * 60 + et.getMinutes();
  return mins >= MARKET_OPEN_MINS && mins < MARKET_CLOSE_MINS;
}

/**
 * Determine current US stock market state and appropriate staleness threshold.
 */
export function getMarketStatus(now: Date = new Date()): MarketStatus {
  const et = toET(now);

  // Check holiday first (could be a weekday)
  if (isHoliday(et)) {
    // Check if previous day was also closed (weekend or holiday) -> extended holiday
    const yesterday = new Date(et);
    yesterday.setDate(yesterday.getDate() - 1);
    const extendedClosure = isHoliday(yesterday) || isWeekend(yesterday);

    return {
      state: MarketState.HOLIDAY,
      maxStaleSec: extendedClosure ? STALE_THRESHOLDS[MarketState.HOLIDAY] : STALE_THRESHOLDS[MarketState.WEEKEND],
      shouldUpdate: false,
    };
  }

  // Weekend
  if (isWeekend(et)) {
    return {
      state: MarketState.WEEKEND,
      maxStaleSec: STALE_THRESHOLDS[MarketState.WEEKEND],
      shouldUpdate: false,
    };
  }

  // Weekday — check if within trading hours
  if (isWithinTradingHours(et)) {
    return {
      state: MarketState.OPEN,
      maxStaleSec: STALE_THRESHOLDS[MarketState.OPEN],
      shouldUpdate: true,
    };
  }

  // Weekday but outside trading hours
  // Check if tomorrow is a holiday or weekend -> use longer threshold
  const tomorrow = new Date(et);
  tomorrow.setDate(tomorrow.getDate() + 1);
  if (isWeekend(tomorrow) || isHoliday(tomorrow)) {
    return {
      state: MarketState.OVERNIGHT,
      maxStaleSec: STALE_THRESHOLDS[MarketState.WEEKEND],
      shouldUpdate: false,
    };
  }

  return {
    state: MarketState.OVERNIGHT,
    maxStaleSec: STALE_THRESHOLDS[MarketState.OVERNIGHT],
    shouldUpdate: false,
  };
}
