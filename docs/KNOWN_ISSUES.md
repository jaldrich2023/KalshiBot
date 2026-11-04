# Known issues and limitations

These are known, documented limitations of Kalshi Bot 2.24.1. They aren't treated as bugs.

## Predictions

- **The bot's calls track Kalshi's price.** No signal tested so far has improved on Kalshi's price at the call on held-out windows, so the bot anchors on Kalshi's odds and its accuracy matches the market's. Signals keep being trialled after every window. See the User Manual, chapter 5.
- **Low-confidence calls lose often.** Calls at 55–60% are right about 58% of the time. That's correct calibration, not a fault. New installs skip calls under 60% (**Calls › Only ≥60% confident**).
- **"Use Kalshi odds" off is much less accurate.** With it off, the model uses price signals alone; the Strategy card shows a warning.

## Prices and data

- **The BRTI estimate isn't the official index.** It's built from ten public exchange feeds, each corrected by its own measured offset from Kalshi's official targets, plus an overall calibration. It still differs from CF Benchmarks' value by a few dollars; the Current Window card shows the typical **Tracking error**. That matters only when a window finishes within about that much of its target.
- **Sources drop out.** Feeds can go stale or move off-market for a while. The composite drops them and uses the rest; dropped or silent streams reconnect automatically, and the source list shows how long each has been out.
- **History depends on public APIs.** The first rebuild downloads up to 180 days from Kalshi and Coinbase, retrying slow or failed requests. After that, the download is saved and only new windows are fetched. macOS can clear the saved copy (it's in Caches) to free space, which just means one full download again.
- **The Reversal Risk card's live check needs time.** It scores the card's figure once a window settles, so its bands are noisy until a few hundred minutes are logged. The refit uses minutes +3 to +12; earlier and in the final minutes, the fixed corrections apply.
- **Promotions are deliberately slow.** A context signal needs significant gains on three separate sets of at least 200 fresh windows, so even a genuinely useful one takes about a week to be promoted.
- **Rebuilt windows lack some data.** Windows rebuilt from history have no tick momentum, and no Kalshi odds where Kalshi has no price history.

## Trading

- **Kalshi Bot never places orders.** Every trade is yours to make on Kalshi.
- **Estimates use the top of the book.** Profit and loss figures assume you trade at the best bid or ask, with Kalshi's taker fee. Large stakes can move the price.
- **Stop-loss and take-profit lines are estimates.** They convert a contract price into a Bitcoin price using the bot's odds, plus the current gap between those odds and Kalshi's price. Kalshi's actual price at that level can differ.

## App

- **Sleeping misses windows.** With **Keep Mac awake** off, the Mac can sleep while the bot runs, and windows during sleep are missed (they're still learned from history later).
- **Clear All Data and Erase Everything can't be undone.** Erase Everything also removes every setting and the saved market download.
  Both offer to copy the log to the clipboard as CSV first; paste it somewhere to keep it. **Reset Model, Keep Data** resets only the model.
