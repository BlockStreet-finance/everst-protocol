// Pyth feed monitor: polls Hermes for the configured feeds, stores each sample in
// SQLite, and serves a live dashboard. Zero npm dependencies (Node >= 22.5 built-ins).
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { CONFIG, TICKERS, normId } from "./config.js";
import { openDb, upsertFeeds, loadFeeds, insertReadings, latestPerFeed, history, rowCount } from "./db.js";
import { discoverFeeds } from "./catalog.js";
import { fetchLatest, scale } from "./hermes.js";
import { deriveAll } from "./derive.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const db = openDb(CONFIG.dbPath);

// Feed catalog is discovered from Hermes at startup and persisted in SQLite.
// On a network failure we fall back to whatever catalog the DB already holds.
let FEEDS = [];
let FEED_IDS = [];

async function initFeeds() {
  try {
    const discovered = await discoverFeeds(CONFIG.hermesUrl, TICKERS);
    if (discovered.length) upsertFeeds(db, discovered);
    console.log(`discovered ${discovered.length} feeds across ${TICKERS.length} tickers: ${TICKERS.join(", ")}`);
  } catch (e) {
    console.error(`feed discovery failed (${e.message}); using catalog already in DB`);
  }
  FEEDS = loadFeeds(db);
  FEED_IDS = FEEDS.map((f) => normId(f.id));
  if (!FEEDS.length) {
    console.error("no feeds available (discovery failed and DB empty) — set TICKERS and check network");
    process.exit(1);
  }
}

let lastPoll = { at: null, ok: false, error: null, samples: 0 };

async function pollOnce() {
  const ts = Date.now();
  const nowSec = Math.floor(ts / 1000);
  try {
    const byId = await fetchLatest(CONFIG.hermesUrl, FEED_IDS);
    const rows = FEEDS.map((f) => {
      const id = normId(f.id);
      const p = byId.get(id);
      if (!p || !p.price) {
        return { ts, feed_id: id, symbol: f.symbol, session: f.session, ok: 0,
                 price: null, price_raw: null, conf: null, conf_bps: null, expo: null,
                 publish_time: null, prev_publish_time: null, age_sec: null };
      }
      const expo = p.price.expo;
      const price = scale(p.price.price, expo);
      const conf = scale(p.price.conf, expo);
      return {
        ts, feed_id: id, symbol: f.symbol, session: f.session, ok: 1,
        price, price_raw: String(p.price.price),
        conf, conf_bps: price ? (conf / price) * 1e4 : null,
        expo, publish_time: p.price.publish_time,
        prev_publish_time: p.metadata?.prev_publish_time ?? null,
        age_sec: nowSec - p.price.publish_time,
      };
    });
    insertReadings(db, rows);
    lastPoll = { at: ts, ok: true, error: null, samples: rows.length };
  } catch (e) {
    lastPoll = { at: ts, ok: false, error: String(e.message || e), samples: 0 };
    console.error(`[poll] ${new Date(ts).toISOString()} failed: ${lastPoll.error}`);
  }
}

function buildLatest() {
  const nowSec = Math.floor(Date.now() / 1000);
  const latest = latestPerFeed(db, FEED_IDS);
  const feeds = FEEDS.map((f) => {
    const id = normId(f.id);
    const r = latest[id];
    return {
      ...f,
      idShort: id.slice(0, 8),
      reading: r
        ? { ...r, ageNow: r.publish_time ? nowSec - r.publish_time : null,
            fresh: r.ok && r.publish_time != null && nowSec - r.publish_time <= CONFIG.freshnessSec }
        : null,
    };
  });
  return { nowSec, feeds, derived: deriveAll(FEEDS, latest, nowSec) };
}

function json(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { "content-type": "application/json", "content-length": Buffer.byteLength(body) });
  res.end(body);
}

const server = createServer(async (req, res) => {
  const u = new URL(req.url, `http://${req.headers.host}`);
  try {
    if (u.pathname === "/" || u.pathname === "/index.html") {
      const html = await readFile(join(__dirname, "public", "index.html"));
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      return res.end(html);
    }
    if (u.pathname === "/api/meta") {
      return json(res, 200, {
        feeds: FEEDS, tickers: TICKERS, hermesUrl: CONFIG.hermesUrl, pollIntervalSec: CONFIG.pollIntervalSec,
        freshnessSec: CONFIG.freshnessSec, dbPath: CONFIG.dbPath,
        rows: rowCount(db), lastPoll,
      });
    }
    if (u.pathname === "/api/latest") {
      return json(res, 200, buildLatest());
    }
    if (u.pathname === "/api/history") {
      const id = normId(u.searchParams.get("id") || "");
      const limit = Math.min(Number(u.searchParams.get("limit") || 500), 5000);
      if (!FEED_IDS.includes(id)) return json(res, 400, { error: "unknown feed id" });
      return json(res, 200, { id, rows: history(db, id, limit) });
    }
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("not found");
  } catch (e) {
    json(res, 500, { error: String(e.message || e) });
  }
});

await initFeeds();   // discover catalog -> SQLite -> load
await pollOnce();    // seed immediately so the dashboard isn't empty
setInterval(pollOnce, CONFIG.pollIntervalSec * 1000);

server.listen(CONFIG.port, () => {
  console.log(`pyth-monitor: polling ${FEEDS.length} feeds every ${CONFIG.pollIntervalSec}s -> ${CONFIG.dbPath}`);
  console.log(`dashboard:   http://localhost:${CONFIG.port}`);
});
