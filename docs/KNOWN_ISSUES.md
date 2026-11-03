# Known issues and limitations

These are known, documented limitations of Kalshi Bot 2.14. They aren't treated as bugs.

## Predictions

- **The bot doesn't beat Kalshi's price.** Every signal tested so far adds nothing on held-out windows beyond Kalshi's price at the call, so the bot usually follows Kalshi's odds and its accuracy matches the market's. See the User Manual, chapter 5.
- **Low-confidence calls lose often.** Calls at 55–60% are right about 58% of the time. That's correct calibration, not a fault. Use **Calls › Only ≥60% confident** to skip them.
- **"Use Kalshi odds" off is much less accurate.** With it off, the model uses price signals alone.

## Prices and data

- **The BRTI estimate isn't the official index.** It's built from eight public exchange feeds and corrected by a calibration learned from Kalshi's targets. It can differ from CF Benchmarks' official value by a few dollars, which matters only when a window finishes very close to its target.
- **Sources drop out.** Feeds can go stale or move off-market for a while; the composite drops them automatically and uses the rest.
- **History depends on public APIs.** Rebuilding training history needs Kalshi's and Coinbase's public endpoints. If they're slow or limit requests, the rebuild takes longer.
- **Rebuilt windows lack some data.** Windows rebuilt from history have no tick momentum, and no Kalshi odds where Kalshi has no price history.

## Trading

- **Kalshi Bot never places orders.** Every trade is yours to make on Kalshi.
- **Estimates use the top of the book.** Profit and loss figures assume you trade at the best bid or ask, with Kalshi's taker fee. Large stakes can move the price.
- **Stop-loss and take-profit lines are estimates.** They convert a contract price into a Bitcoin price using the bot's odds, plus the current gap between those odds and Kalshi's price. Kalshi's actual price at that level can differ.

## App

- **The Mac stays awake while the bot runs.** Click **Stop** to let it sleep.
- **Reset deletes everything except settings,** and can't be undone. Copy the CSV first if you want a record.
