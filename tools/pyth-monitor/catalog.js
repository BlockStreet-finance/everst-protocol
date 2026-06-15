// Discovers Pyth feed ids for the configured tickers from the Hermes catalog,
// so feed ids never have to be hand-copied. For each ticker we build the set of
// expected symbols from the session template and keep whichever Hermes actually has.
import { SESSION_TEMPLATES, TICKERS } from "./config.js";

export async function discoverFeeds(hermesUrl, tickers = TICKERS) {
  const found = [];
  for (const t of tickers) {
    // expected exact symbol -> session label
    const expected = new Map(SESSION_TEMPLATES.map((st) => [st.symbol(t), st.session]));

    const url = `${hermesUrl}/v2/price_feeds?query=${encodeURIComponent(t)}`;
    const res = await fetch(url, { headers: { accept: "application/json" } });
    if (!res.ok) throw new Error(`Hermes catalog ${res.status} for ${t}`);
    const arr = await res.json();

    for (const f of arr) {
      const sym = f.attributes?.symbol;
      if (sym && expected.has(sym)) {
        found.push({ group: t, session: expected.get(sym), symbol: sym, id: "0x" + f.id });
      }
    }
  }
  // Keep template order within each ticker for stable display.
  const order = new Map(SESSION_TEMPLATES.map((st, i) => [st.session, i]));
  found.sort((a, b) =>
    a.group === b.group ? order.get(a.session) - order.get(b.session) : 0
  );
  return found;
}
