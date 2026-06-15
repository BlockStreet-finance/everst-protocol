// Thin Hermes client (uses built-in fetch). Returns parsed prices for the given feed ids.
import { normId } from "./config.js";

export async function fetchLatest(hermesUrl, feedIds) {
  const params = new URLSearchParams();
  for (const id of feedIds) params.append("ids[]", id);
  params.append("parsed", "true");
  params.append("encoding", "hex");
  // Don't 404 the whole batch if one id is unknown.
  params.append("ignore_invalid_price_ids", "true");

  const url = `${hermesUrl}/v2/updates/price/latest?${params.toString()}`;
  const res = await fetch(url, { headers: { accept: "application/json" } });
  if (!res.ok) {
    throw new Error(`Hermes ${res.status} ${res.statusText}`);
  }
  const json = await res.json();

  // Index parsed entries by normalized id.
  const byId = new Map();
  for (const p of json.parsed || []) {
    byId.set(normId(p.id), p);
  }
  return byId;
}

/** scaled = rawInt * 10^expo, computed in float (display precision is fine here). */
export function scale(rawInt, expo) {
  return Number(rawInt) * Math.pow(10, expo);
}
