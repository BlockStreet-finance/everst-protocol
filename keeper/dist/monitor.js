import { AlertLevel, sendAlert } from "./alerter.js";
/**
 * Checks whether the on-chain Pyth price for each feed is still fresh.
 * Alerts if the price is older than maxAgeSec.
 */
export async function checkFreshness(pythContract, feeds, maxAgeSec) {
    const now = Math.floor(Date.now() / 1000);
    for (const feed of feeds) {
        try {
            const price = await pythContract.getPriceUnsafe(feed.pythPriceId);
            const publishTime = Number(price.publishTime);
            const age = now - publishTime;
            if (age > maxAgeSec) {
                sendAlert({
                    level: AlertLevel.WARN,
                    feed: feed.bTokenAddress,
                    message: `Price stale: age=${age}s, max=${maxAgeSec}s, publishTime=${publishTime}`,
                    timestamp: new Date(),
                });
            }
        }
        catch (err) {
            sendAlert({
                level: AlertLevel.ERROR,
                feed: feed.bTokenAddress,
                message: `Failed to read on-chain price: ${err}`,
                timestamp: new Date(),
            });
        }
    }
}
