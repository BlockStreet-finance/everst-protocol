// SQLite persistence using the built-in node:sqlite (no native deps).
import { DatabaseSync } from "node:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { normId } from "./config.js";

export function openDb(dbPath) {
  mkdirSync(dirname(dbPath), { recursive: true });
  const db = new DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE IF NOT EXISTS feeds (
      feed_id  TEXT PRIMARY KEY,   -- lowercase, no 0x
      symbol   TEXT NOT NULL,
      grp      TEXT NOT NULL,      -- stock ticker
      session  TEXT NOT NULL,
      seq      INTEGER             -- display order
    );
    CREATE TABLE IF NOT EXISTS readings (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      ts            INTEGER NOT NULL,   -- poll wall-clock time (unix ms)
      feed_id       TEXT    NOT NULL,   -- lowercase, no 0x
      symbol        TEXT    NOT NULL,
      session       TEXT    NOT NULL,
      price         REAL,               -- scaled by expo
      price_raw     TEXT,               -- raw integer, as string (exact)
      conf          REAL,               -- scaled by expo
      conf_bps      REAL,               -- conf/price * 1e4
      expo          INTEGER,
      publish_time  INTEGER,            -- unix s, from Pyth
      prev_publish_time INTEGER,
      age_sec       INTEGER,            -- (ts/1000) - publish_time at poll
      ok            INTEGER NOT NULL    -- 1 if a price was returned, 0 if missing/invalid
    );
    CREATE INDEX IF NOT EXISTS idx_readings_feed_ts ON readings (feed_id, ts);
  `);
  return db;
}

/** Replace the feed catalog with the discovered set (keeps stable display order via seq). */
export function upsertFeeds(db, feeds) {
  const stmt = db.prepare(`
    INSERT INTO feeds (feed_id, symbol, grp, session, seq) VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(feed_id) DO UPDATE SET symbol = excluded.symbol, grp = excluded.grp,
                                       session = excluded.session, seq = excluded.seq
  `);
  db.exec("BEGIN");
  try {
    feeds.forEach((f, i) => stmt.run(normId(f.id), f.symbol, f.group, f.session, i));
    db.exec("COMMIT");
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }
}

/** Load the feed catalog from SQLite as [{ group, session, symbol, id }]. */
export function loadFeeds(db) {
  return db
    .prepare(`SELECT feed_id, symbol, grp, session FROM feeds ORDER BY seq, rowid`)
    .all()
    .map((r) => ({ group: r.grp, session: r.session, symbol: r.symbol, id: "0x" + r.feed_id }));
}

export function insertReadings(db, rows) {
  const stmt = db.prepare(`
    INSERT INTO readings
      (ts, feed_id, symbol, session, price, price_raw, conf, conf_bps, expo, publish_time, prev_publish_time, age_sec, ok)
    VALUES
      (?,  ?,       ?,      ?,       ?,     ?,         ?,    ?,        ?,    ?,            ?,                 ?,       ?)
  `);
  db.exec("BEGIN");
  try {
    for (const r of rows) {
      stmt.run(
        r.ts, r.feed_id, r.symbol, r.session,
        r.price, r.price_raw, r.conf, r.conf_bps, r.expo,
        r.publish_time, r.prev_publish_time, r.age_sec, r.ok ? 1 : 0
      );
    }
    db.exec("COMMIT");
  } catch (e) {
    db.exec("ROLLBACK");
    throw e;
  }
}

export function latestPerFeed(db, feedIds) {
  const out = {};
  const stmt = db.prepare(`SELECT * FROM readings WHERE feed_id = ? ORDER BY ts DESC LIMIT 1`);
  for (const id of feedIds) {
    out[id] = stmt.get(id) || null;
  }
  return out;
}

export function history(db, feedId, limit = 500) {
  const rows = db
    .prepare(`SELECT ts, price, conf_bps, age_sec, publish_time, ok FROM readings WHERE feed_id = ? ORDER BY ts DESC LIMIT ?`)
    .all(feedId, limit);
  return rows.reverse();
}

export function rowCount(db) {
  return db.prepare(`SELECT COUNT(*) AS n FROM readings`).get().n;
}
