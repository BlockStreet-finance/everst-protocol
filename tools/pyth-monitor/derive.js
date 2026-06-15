// Derives the spec §3 view per stock: which session is live, the xStock 24/7 proxy
// basis, the redemption rate, and whether the stock is effectively unpriced.
import { CONFIG, normId } from "./config.js";

const EQUITY_SESSIONS = ["regular", "pre", "post", "overnight"];

function deriveGroup(group, groupFeeds, latestByFeedId, nowSec) {
  const bySession = {};
  for (const f of groupFeeds) {
    const row = latestByFeedId[normId(f.id)];
    bySession[f.session] = row
      ? { ...row, ageNow: row.publish_time ? nowSec - row.publish_time : null }
      : null;
  }

  const isFresh = (r) => r && r.ok && r.ageNow != null && r.ageNow <= CONFIG.freshnessSec;

  // Active equity session = the freshest equity feed currently within the freshness window.
  let active = null;
  for (const s of EQUITY_SESSIONS) {
    const r = bySession[s];
    if (isFresh(r) && (!active || r.ageNow < active.ageNow)) {
      active = { session: s, ...r };
    }
  }

  const proxy = bySession["24/7"];   // xStock 24/7 feed (may be absent for some stocks)
  const rr = bySession["rr"];
  const regular = bySession["regular"];
  const hasProxy = Object.prototype.hasOwnProperty.call(bySession, "24/7");

  // Basis of the 24/7 proxy vs the live equity price (or vs last-known regular if market is dark).
  let basisBps = null;
  let basisRef = null;
  const ref = active || (regular && regular.ok ? { session: "regular(last)", ...regular } : null);
  if (proxy && proxy.ok && ref && ref.price) {
    basisBps = ((proxy.price - ref.price) / ref.price) * 1e4;
    basisRef = ref.session;
  }

  const priceable = isFresh(active) || isFresh(proxy);

  return {
    group,
    activeSession: active ? active.session : null,
    activePrice: active ? active.price : null,
    hasProxy,
    proxyPrice: proxy && proxy.ok ? proxy.price : null,
    proxyFresh: isFresh(proxy),
    rr: rr && rr.ok ? rr.price : null,
    basisBps,
    basisRef,
    priceable,
  };
}

export function deriveAll(feeds, latestByFeedId, nowSec) {
  const groups = [...new Set(feeds.map((f) => f.group))];
  return groups.map((g) =>
    deriveGroup(g, feeds.filter((f) => f.group === g), latestByFeedId, nowSec)
  );
}

export const freshnessSec = CONFIG.freshnessSec;
