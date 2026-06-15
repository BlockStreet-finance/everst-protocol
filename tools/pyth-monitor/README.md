# pyth-monitor

Local monitor for the Pyth feeds that drive BlockStreet's session-aware pricing
(stock-risk-control-spec §3). It samples each feed from Hermes on an interval,
stores every sample in SQLite, and serves a live dashboard so you can watch how
the feeds behave across market sessions.

**Zero npm dependencies** — uses Node ≥ 22.5 built-ins only (`fetch`, `node:http`,
`node:sqlite`). No `npm install`, no native build.

## Run

```bash
cd tools/pyth-monitor
npm start              # = node --experimental-sqlite index.js
# open http://localhost:8787
```

Override anything via env vars:

```bash
PORT=9000 POLL_INTERVAL_SEC=10 FRESHNESS_SEC=120 DB_PATH=./data/pyth.db npm start
```

| env | default | meaning |
|-----|---------|---------|
| `PORT` | `8787` | dashboard / API port |
| `POLL_INTERVAL_SEC` | `20` | how often to sample Hermes |
| `FRESHNESS_SEC` | `90` | a feed within this age counts as "fresh" → its session is live |
| `HERMES_URL` | `https://hermes.pyth.network` | Hermes endpoint |
| `DB_PATH` | `./data/pyth.db` | SQLite file (gitignored) |

## What it shows

**Feeds table** — for every configured feed: price, confidence, conf in bps
(spec §3.1 ③ confidence check), expo, publish time, age, and `fresh / stale /
missing`. Equity feeds only update inside their own session, so the fresh one
tells you which session is live.

**Derived cards** (the spec §3 view for COIN):
- **Active session** — freshest equity feed (regular / pre / post / overnight).
- **COINX (24/7 proxy)** — the always-on tokenized-COIN price used as the
  closed-market fallback.
- **Proxy basis** — COINX vs the live equity price, in bps. This is the
  basis/de-peg risk that §7 liquidation guardrails must cover.
- **COINX/COIN redemption (RR)** — peg monitor.
- **COIN priceable?** — `NO` only when no equity feed *and* COINX are fresh
  (the genuine "no price" failsafe branch).

**History chart** — pick a feed to see its price over the samples collected so
far (let it run to build up history).

## Feeds tracked

Configured in `config.js` (extend with TSLA / AAPL / … as needed):

| symbol | session | feed id |
|--------|---------|---------|
| `Equity.US.COIN/USD` | regular | `0xfee33f2a…860860245` |
| `Equity.US.COIN/USD.PRE` | pre-market | `0x8bdee6bc…0bd3517c` |
| `Equity.US.COIN/USD.POST` | post-market | `0x5c3bd92f…b9559cd4` |
| `Equity.US.COIN/USD.ON` | overnight (Blue Ocean ATS) | `0x42ded7a3…5fe9d6b6` |
| `Crypto.COINX/USD` | 24/7 proxy | `0x641435d5…02cab33f` |
| `Crypto.COINX/COIN.RR` | redemption rate | `0xb663e208…0af08549` |

## API

- `GET /api/meta` — feeds, config, row count, last-poll status
- `GET /api/latest` — latest reading per feed + the derived COIN view
- `GET /api/history?id=<feedId>&limit=N` — time series for one feed

## Notes

- Feed data is **chain-agnostic** (it comes from Hermes). On-chain Pyth values on
  Base only reflect what the keeper has pushed; BSC testnet uses MockPyth and has
  no real session data. This tool intentionally reads Hermes so you see the true
  feed behavior. On-chain comparison can be added later.
- `node:sqlite` is still experimental in Node 22, so you'll see one
  `ExperimentalWarning` on startup — harmless.
