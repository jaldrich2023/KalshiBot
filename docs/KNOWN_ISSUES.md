# Known issues and limitations

These are known, documented limitations of Kalshi Bot 2.29.0. They aren't treated as bugs. Issues fixed recently are listed at the end.

## Predictions

- **The bot's calls track Kalshi's price.** No signal tested so far has improved on Kalshi's price at the call on held-out windows, so the bot anchors on Kalshi's odds and its accuracy matches the market's. Signals keep being trialled after every window. See the User Manual, chapter 5.
- **Low-confidence calls lose often.** Calls at 55–60% are right about 58% of the time. That's correct calibration, not a fault. New installs skip calls under 60% (**Calls › Only ≥60% confident**).
- **"Use Kalshi odds" off is much less accurate.** With it off, the model uses price signals alone; the Strategy card shows a warning.
- **"Edge vs. Kalshi" needs disagreements to say anything.** Because the bot follows Kalshi's odds, the two usually call the same side, and only the windows where they disagree can show an edge. The card tests those with an exact test, so it reads "not yet distinguishable from chance" until there are enough of them: at least 6, all won by the same side, and more when they're split. The Brier comparison in the Performance tab needs at least 10 windows where the two probabilities differ.

## Prices and data

- **The BRTI estimate isn't the official index.** It's built from ten public exchange feeds, each corrected by its own measured offset from Kalshi's official targets, plus an overall calibration. It still differs from CF Benchmarks' value by a few dollars; the Current Window card shows the typical **Tracking error**. That matters only when a window finishes within about that much of its target.
- **Sources drop out.** Feeds can go stale or move off-market for a while. The composite drops them and uses the rest; dropped or silent streams reconnect automatically, with a growing wait for an exchange that keeps dropping the connection, and the source list shows how long each has been out. If every source is out at once, a one-off backup price is fetched; it's discarded if live prices return first.
- **History depends on public APIs.** The first rebuild downloads up to 180 days from Kalshi and Coinbase, retrying slow or failed requests. A malformed record is skipped, and anything still missing is fetched at the next catch-up. After that, the download is saved and only new windows are fetched. macOS can clear the saved copy (it's in Caches) to free space, which just means one full download again.
- **The Reversal Risk card's live check needs time.** It scores the card's figure once a window settles, so its bands are noisy until a few hundred minutes are logged. The refit uses minutes +3 to +12; earlier and in the final minutes, the fixed corrections apply. After a gap in the minute candles, volatility is measured over the unbroken minutes only, or from the live ticks until enough have built up.
- **Promotions are deliberately slow.** A context signal needs significant gains on three separate sets of at least 200 fresh windows, so even a genuinely useful one takes about a week to be promoted.
- **Rebuilt windows lack some data.** Windows rebuilt from history have no tick momentum, and no Kalshi odds where Kalshi has no price history.
- **Live windows are kept per call time.** A window called live at one call time (for example +3) keeps its live training example when you change **Call at**; it isn't replaced by a rebuilt one. Until you switch back, that window isn't used for training at the new call time.

## Calls and settlement

- **Waiting raises accuracy, not profit.** With **Wait** on, calls lock later and only once confident, so they're right far more often, but those contracts cost correspondingly more on Kalshi, and some windows get no call at all. Calls that waited also lock at different minutes, so they aren't comparable minute for minute with calls made without waiting.
- **Close calls reverse often, and can't be told apart in advance.** A call locked within 0.5σ of the target loses about 40% of the time; the Prediction card flags it. Nothing tested (distance, target crosses, momentum, Kalshi's drop since the call) warned of a reversal better than Kalshi's live price, which the Reversal Risk card already uses.
- **A call that can't lock on time is skipped.** If fetching fresh data delays the call past the allowed time, the window gets no call rather than a late one, and the Activity tab says so.
- **Windows that never settle are marked void.** If Kalshi reports no Yes or No result (for example a voided market), or none within 24 hours of the close, the window is marked void and left out of accuracy and training.
- **The repeated hour when clocks fall back.** On the first Sunday of November, 1:00–2:00 AM Eastern happens twice. If Kalshi has no market matching a window's exact close in that hour, the bot skips that window instead of reusing the earlier one.

## Trading

- **Kalshi Bot never places orders.** Every trade is yours to make on Kalshi.
- **Estimates use the top of the book.** Profit and loss figures assume you trade at the best bid or ask, with Kalshi's taker fee charged once per order as Kalshi does. Large stakes can move the price. When one side of Kalshi's book is empty, there's no quote for it, and no estimate or advice that needs it.
- **Exits don't add profit.** Exit alerts and the stop-loss line cap a window's loss, but in a backtest they never improved the expected result over holding, once fees were paid. Use them to limit losses.
- **Stop-loss and take-profit lines are estimates.** They convert a contract price into a Bitcoin price using the bot's odds, plus the current gap between those odds and Kalshi's price. Kalshi's actual price at that level can differ.

## App

- **Sleeping misses windows.** With **Keep Mac awake** off, the Mac can sleep while the bot runs, and windows during sleep are missed (they're still learned from history later).
- **Clear All Data and Erase Everything can't be undone.** Erase Everything also removes every setting and the saved market download, then relaunches the app; if the relaunch fails, it says so and asks you to reopen it.
  Both offer to copy the log to the clipboard as CSV first; paste it somewhere to keep it. **Reset Model, Keep Data** resets only the model.
- **Some crashes can't be recorded.** A stack overflow on a background thread ends the app before a crash file can be written; macOS still records it in its own crash reports.

## Fixed recently

Fixed in 2.27.1 (see the [CHANGELOG](../CHANGELOG.md) for everything):

- Changing **Call at** used to delete live training examples for good.
- A reset during a settlement check could crash, and a retrain still running could undo a reset.
- Calls could lock up to half a minute late, and position costs overstated Kalshi's fee by rounding it up per contract.
- "Edge vs. Kalshi" could claim a significant edge from as few as 2 windows, and accuracy's margin could show ±0 or pass 100%.
- An empty side of Kalshi's order book showed an old quote.
- Running the unit tests quit a running copy of the bot, and reopening the window restarted a bot you'd stopped.
- The dashboard re-laid itself out several times a frame, and its cards collapsed to no width without a market.
- Check for Updates… said "up to date" when a release you'd dismissed was newer.
