# Changelog

All notable changes to Kalshi Bot are documented here. The project follows
[Semantic Versioning](https://semver.org): MAJOR for incompatible changes, MINOR for
new features, PATCH for fixes. Set the version in the target's `MARKETING_VERSION`
build setting; the build number is `CURRENT_PROJECT_VERSION`.

## [2.24.0] — 2026-11-03 · Build 44

### Added
- **Popover tips on every field.** Rest the pointer on any figure, label, setting or
  button for a moment and a popover opens with its name and a fuller explanation: what it
  measures, how it's calculated, and how to read it. Tips cover the Current Window,
  Prediction, Reversal Risk, Accuracy, Model, Strategy and Candle Pattern cards, the chart
  summaries and Layers menus (which now describe every layer), the Indicators tab, the
  Performance summary and trends, and the toolbar. Only one tip is open at a time, it
  opens on the side away from the nearer screen edge, and any click, key press or scroll
  closes it. They replace the plain system tooltips. The Prediction Log and the
  Performance charts and tables keep their existing hover breakdowns.

## [2.23.0] — 2026-11-03 · Build 43

### Changed
- **Kalshi Bot is now free and open-source software under the MIT License**, copyright
  John Aldrich. It replaces the proprietary end user license agreement. The financial-risk,
  third-party data and trademark terms are kept in a new `DISCLAIMER.md`, and the About
  window shows both.
- The author is John Aldrich throughout the app (About window, copyright) and the docs.
- CONTRIBUTING and the pull request template now welcome pull requests.
- The app's bundle identifier is unchanged, so existing data and settings carry over.

## [2.22.1] — 2026-11-03 · Build 42

### Changed
- **The window has a fixed size: 2,400 × 1,600 points**, and isn't resizable. On a screen
  too small for that it shrinks to fit, so it never runs off the edge; anything that then
  doesn't fit scrolls inside the window.

## [2.22.0] — 2026-11-03 · Build 40

### Changed
- **Switching to learned weights now needs a real gain.** Besides winning at least 3 of
  the 4 walk-forward blocks, the learned weights' overall log-loss improvement over
  Kalshi's odds must be bigger than its 95% margin of error. Before, any improvement
  counted, and on Nov 3 a 0.0003 gain — almost certainly chance — switched the model.
- **Once on, learned weights stay on** unless they fall clearly behind: winning fewer
  than half the blocks, or doing significantly worse overall. A small dip no longer
  flips the model back and forth.
- A switch made under the old rule is re-judged under the new one at the next retrain.
- The "Switching to learned weights" panel shows the gain and its margin.

## [2.21.0] — 2026-11-03 · Build 39

### Added
- **Windows per indicator** on every Indicators card: how many settled windows have the
  signal (for live-only signals, how many live windows).
- **Promotion progress** on each context signal: its current streak of counted results,
  how many settled windows until its next result can count, and the fewest windows
  before it could be promoted (or, once promoted, demoted) if every result goes its way.
  Live-only signals show their progress toward the 500 live windows trials need.
- **"Switching to learned weights"** panel on the Indicators tab, listing the three
  conditions for predicting with learned weights instead of Kalshi's odds — enough
  history, winning most walk-forward blocks, and lower overall log-loss — with a ✓ or ○
  and the current numbers for each. There's no fixed window count; it's re-checked after
  every settled window.
- The model now records its walk-forward log-loss (learned vs. Kalshi's odds), the
  measure behind the "overall" condition.
- **Downloadable app** on the release page (`KalshiBot-2.21.0-macOS.zip`, Apple silicon,
  ad-hoc signed — not Developer ID signed or notarized), with install instructions in
  `docs/INSTALL.md`.

## [2.20.0] — 2026-11-03 · Build 38

### Added
- **"Calls like this"** on the Prediction card: how often past calls in the same 5-point
  confidence band and call minute were right, e.g. "Calls like this (70–75% at +3 min)
  won 77% of 1,448 past windows." Tallied from the saved history at each rebuild.
- **Presets** in the Strategy card: Standard (+3 min, ≥60%) and High hit rate (+9 min,
  ≥70%), which sets the call time and threshold together. High hit rate was right 88%
  of the time in 6,459 past windows versus 73%, calling about 71% of windows; it raises
  accuracy, not profit.

### Fixed
- A weighting test assumed the 25% cap could apply with three sources; with four or
  fewer, an equal share is already at or above the cap, so the average stays equal (as
  designed). The full suite, including the 2.17–2.19 trainer, combination and weighting
  tests, now passes (151 passed, 1 long research test skipped).
- Three Swift concurrency warnings: the call-time options and the confidence-band width
  are now nonisolated constants, since the history tally that reads them runs off the
  main actor.

## [2.19.2] — 2026-11-03 · Build 37

### Changed
- License, section 4 (in `LICENSE` and the About window): "Predictions are probabilistic
  and are frequently wrong" now reads "Predictions are probabilistic and will sometimes
  be wrong."

## [2.19.1] — 2026-11-03 · Build 36

### Changed
- Disclaimer wording in the About window, README, manual and brochure: "predictions are
  often wrong" is replaced by what the numbers mean — every call is a probability, so a
  70% call is expected to miss about 3 times in 10. The calls are calibrated, which the
  old wording misrepresented.
- The README's "What to expect", the brochure's calibration panel and the known issues
  describe Kalshi's price as the benchmark every signal must beat on unseen windows,
  rather than as something the bot fails at.

## [2.19.0] — 2026-11-03 · Build 35

### Added
- **Composite weighted by tracking steadiness.** Once each exchange's gap to the official
  index has been measured, exchanges whose gap is steady count more than ones whose gap
  wanders (weight 1 / (offset variance + $4²)), capped at 25% each. The source list shows
  each exchange's actual share.
- **Three combination signals**, trialled for promotion like the other context signals:
  momentum near the target, RSI near the target, and momentum when Kalshi is unsure.
  They're derived from stored signals, so the trials cover the full history. With nine
  signals on trial, the significance bar is z ≈ 2.77.

### Tested, not added
- Kalshi's bid–ask spread at the call (1¢ in 99.8% of 6,435 windows, so it can't tell
  windows apart), ask/bid asymmetry, volume in the first 3 minutes, and the last trade
  versus the mid: all slightly worse than Kalshi's mid on the newest 30% of windows.
- The previous window's result: the next window repeated it 49.5% of the time, and it
  didn't help on held-out windows.

## [2.18.0] — 2026-11-03 · Build 34

### Added
- **Erase Everything, Including Settings…** in the Model card's Reset Model menu. After
  a second confirmation it stops the bot and deletes everything the app has stored — the
  prediction log, training history, every setting, the price and Reversal Risk
  calibrations, the live check, call-time statistics and the saved market download —
  then relaunches as if newly installed. "Copy Log, Erase and Relaunch" keeps a CSV of
  the prediction log on the clipboard first.

## [2.17.1] — 2026-11-03 · Build 33

### Changed
- **The window fits the screen.** It's up to 2,400 points wide (was a fixed 1,819) and
  never taller than the screen's usable area, so it no longer runs off the bottom; anything
  that still doesn't fit scrolls inside the window.
- **Reversal Risk moved to the top row**, between Prediction and Accuracy; the top row has
  five equal columns.
- The 60s average chart now spans the full width and matches the candle chart's height.

## [2.17.0] — 2026-11-03 · Build 32

### Changed
- **Walk-forward model check.** Learned weights are now judged on four blocks covering
  the newest 40% of windows, each predicted by a model fitted only on the windows before
  it. They're used only if they beat Kalshi's odds in at least three of the four blocks
  and overall, instead of on a single 80/20 split that could flip by chance. The Model
  card shows how many blocks they won.
- **Promotion trials need fresh evidence.** A trial result counts toward a signal's
  promotion (or demotion) streak only when judged on at least 200 windows that settled
  since that signal's last counted result. Before, consecutive retrains judged almost the
  same windows, so "three wins in a row" was close to one test.
- **Multiple-testing correction.** Trial margins use a Bonferroni-adjusted z (≈2.64 for
  six signals instead of 1.96), so one of the six doesn't look significant by chance.

### Fixed
- Five Swift concurrency warnings in the chart labels (`ChartTag` was main-actor-isolated
  but used by the nonisolated label placement); each would be an error in Swift 6 mode.

## [2.16.0] — 2026-11-03 · Build 31

### Changed
- **Reversal Risk headline is now the actual chance the leading side loses.** It used
  to show that chance doubled, on a scale where 100% meant a coin flip, so a 37% chance
  read as "74.8% High". Levels are now Low under 15%, Moderate 15–35%, High from 35%,
  and the bar runs to 50% (a coin flip).
- The card shows **Kalshi's price for the same outcome** beside its own figure.
- The flip uncertainty includes the price's **tracking error** against the official
  index, so a few-dollar cushion is no longer treated as near-certain.

### Added
- **Automatic recalibration.** After each history rebuild (at most hourly), the card's
  corrections are refitted from the saved history: fitted on the older 80% of windows,
  scored on the newest 20%, and kept only where they score better. Three volatility
  weightings (the last hour equally, or a 30- or 15-minute half-life) and a blend with
  Kalshi's price are tried. On Nov 3 the card was already well calibrated (said ~10/20/
  30/43%, happened 8/22/32/44%) and matched Kalshi (Brier 0.1611 vs. 0.1615); blending
  didn't help, the breakout refit did, and a 30-minute half-life scored best.
- **Live check** on the card: its figure is logged every minute, scored when the window
  settles, and summarized as said → happened for each risk band.

## [2.15.2] — 2026-11-03 · Build 30

### Fixed
- Running the unit tests no longer starts the bot. The tests run inside the app, so a
  test run used to start a second bot on the same prediction log and training data.

## [2.15.1] — 2026-11-02 · Build 29

### Changed
- The license's third-party data section (in the app's About window and in `LICENSE`)
  now lists all ten data sources: Kalshi, Coinbase, Kraken, Bitstamp, Gemini, Crypto.com,
  Binance.US, Deribit, OKX and KuCoin.
- README, SECURITY, CONTRIBUTING, the bug-report form, the manual and the brochure
  updated for 2.15.

## [2.15.0] — 2026-11-02 · Build 28

### Added
- **Two more price sources:** OKX and KuCoin (BTC-USDC books with 10¢ spreads), for ten in
  all. Paxos, LMAX and Bullish are still unreachable from the US, Bybit blocks the US,
  and Gemini's USDC book is the same book as its USD one.
- **Per-exchange BRTI offsets.** At every window open, each exchange's 60-second average
  is compared with Kalshi's official target. Once three exchanges have been measured at
  six opens, each one's median gap is applied before averaging (unmeasured exchanges use
  the typical gap), and the overall calibration restarts on the corrected price. The
  composite no longer jumps when a source with a premium drops out or comes back.
- **Tracking error** in the Current Window card: how far the index estimate typically was
  from the official target at recent opens.
- **Saved market history.** Kalshi's settled windows and odds, and Coinbase's 1-minute
  candles, are saved in the app's Caches folder (`MarketHistory.v1.json`). Restarts,
  resets and call-time changes fetch only what's new. Call-time accuracy now uses every
  saved window.
- **Keep Mac awake** setting in the Strategy card (on by default). With it off, the Mac can
  sleep, but App Nap still can't slow the bot while the Mac is awake.
- **Reset Model, Keep Data**: resets the weights, promotions and trials and retrains on
  the data already collected, keeping the log and accuracy.

### Changed
- New installs skip calls under 60% confidence by default (**Calls › Only ≥60%
  confident**); existing settings are kept.
- The full reset is now **Copy Log, Then Clear All Data**: the prediction log is copied to
  the clipboard as CSV first. It also clears the exchange offsets and tracking error, but
  keeps the saved market download, so the rebuild takes seconds.
- History downloads try each request five times, and every request now also retries
  timeouts and dropped connections, not just server errors.
- The source list shows how long a dropped source has been out instead of 0%, and its
  tooltip gives the exchange's offset and how often its stream has reconnected.

### Fixed
- A price stream that stayed connected but went silent was never replaced, leaving that
  source stale until restart. A stream with no message for 30 seconds is now reconnected.
- The Strategy card warns while **Use Kalshi odds** is off, the setting behind calls that
  disagreed with the market for no good reason.

## [2.14.2] — 2026-11-02 · Build 27

### Fixed
- The Model card's accuracy goal reads "70%" rather than "70.0%".
- Performance charts no longer label their axes in units like "8.0E-15" when the bot
  matches Kalshi's price: per-window edges within floating-point error count as even.

### Added
- Debug builds accept `-screenshotTab N` to open on a given tab (0 Dashboard … 4 Activity),
  used to capture the documentation screenshots. Release builds ignore it.

## [2.14.1] — 2026-11-02 · Build 26

### Changed
- "Path to 70% accuracy" is now a section of the Model card instead of a separate card
  under Accuracy, so the dashboard's top row is back to four single cards.

## [2.14.0] — 2026-11-02 · Build 25

### Added
- "Path to 70% accuracy" card under Accuracy on the dashboard: the correct calls in a row
  needed to reach 70% (or, once there, the misses that can be absorbed), what each miss
  costs, and an outlook from the calls' average confidence — how many more calls it
  should take at that hit rate, or that 70% isn't the expected long-run rate.

## [2.13.0] — 2026-11-02 · Build 24

### Added
- Hover detail on the Performance tab, behaving like the prediction log: rest the pointer
  on an item and a popover opens at the pointer, away from the nearer screen edge, with
  the item highlighted. Hour bars, day × hour cells, best-times day cards and blocks, and
  day/week/month rows show windows, bot vs Kalshi accuracy, Brier edge ± margin, whether
  it's beyond the noise, windows settled Up, average confidence, and disagreements with
  Kalshi. The cumulative edge line shows the nearest window's call breakdown and what it
  added to the running edge.

## [2.12.2] — 2026-11-01 · Build 23

### Fixed
- The stop no longer jumps to "exit" on winning calls. The trailing stop switched on at
  any gain, so a sub-cent profit put it at roughly break-even — right at the price —
  and ordinary noise read as "Exit now" (in a replay, the stop jumped $30 onto the price
  30 seconds after a Down call started winning). It now starts trailing only after a
  gain of 10¢ a contract or a quarter of the most the contract could still gain.

## [2.12.1] — 2026-11-01 · Build 22

### Fixed
- The recommendation no longer contradicts the prediction: once the window's call is
  locked, entries are only suggested on the called side. When live fair value favors
  the other side, the card stands aside ("Stand aside — against the call") and explains
  why. Exit alerts are unchanged.

## [2.12.0] — 2026-11-01 · Build 21

### Added
- Custom take-profit: a switch in the Strategy card with a menu of +5% to +100% gain on
  the stake. When on, the chart's take-profit line sits where selling would return the
  entry price plus that gain, instead of the trading style's default. Gains above the
  ~98¢ maximum sale price are flagged as unreachable and draw no line.

## [2.11.1] — 2026-11-01 · Build 20

### Fixed
- The Strategy card no longer jitters: the style summary, the recommendation (headline,
  justification and figures), the position estimate and the factors list are each laid
  out at the size of their longest possible version (worst-case wording, widest digits),
  so second-by-second updates never move what's below them.

## [2.11.0] — 2026-11-01 · Build 19

### Added
- Stake and profit/loss: enter a dollar stake in the Strategy card's "Your position"
  section and see, every second, the contracts it buys on the call (after Kalshi's fee)
  and the result if sold now, if it settles each way, expected at settlement (Kalshi's
  current chance), and at the stop-loss and take-profit lines. The chart's stop and
  take-profit labels show the dollar amount too. Estimates only — no trades are placed.

## [2.10.0] — 2026-11-01 · Build 18

### Added
- Custom stop-loss: a switch in the Strategy card with a menu of 5–70% of the stake.
  When on, the chart's stop line sits where selling would return that much less than
  the entry price, instead of the trading style's default (30/50/70%). Saved across launches.

## [2.9.1] — 2026-11-01 · Build 17

### Fixed
- Every line stays inside its chart: the candle chart's scale now covers the window
  high/low and the trend line as well as the candles.
- Labels keep the lines and the "Now" dot visible: target, stop and take-profit labels
  sit just off their lines on the side away from the price; the centered high/low labels
  slide sideways out of the dot's way; any label that would still cover the dot moves to
  the other side of its line; and the Settlement/Now/Trend/Projected stack drops to the
  bottom-right when the price is in the top-right.

## [2.9.0] — 2026-11-01 · Build 16

### Added
- A "Layers" menu in each chart's corner switches every element on or off, line and
  label together, remembered per chart. 60-second chart: 60s average, Now, Target,
  Settlement minute, High/Low, Close range, Trend, Projection, Stop & take profit.
  Candle chart: Candles, Movement, Close, Target, Settlement minute, High/Low, Trend.
  "Show all" restores everything; the menu shows how many are hidden.

## [2.8.0] — 2026-11-01 · Build 15

### Changed
- The chart's exit lines now follow the bot's called position, priced from what selling
  would actually return: the called side's calibrated odds at each BTC price, adjusted
  to Kalshi's current pricing of that side, minus half the live spread and the fee.
  - Stop-loss: where selling returns (1 − 30/50/70%) of the price paid, by style.
  - Trailing stop: once the position has been in profit, the stop rises to keep
    60/50/30% of the best gain so far.
  - Take profit: where selling locks in 60/80/95% of the most it could return.
  - "Exit now" when the stop has already been passed. Labels show the entry price and
    what selling would return at each line.

## [2.7.0] — 2026-11-01 · Build 14

### Added
- Projected exit levels on the 60-second chart: dashed lines from now to the close at
  the BTC prices where the current trading style would take profit and exit for the
  favored side, found by inverting the calibrated settlement odds. They update every
  second and tighten toward the target as time runs out. (Entries depend on Kalshi's
  price falling out of line, not a BTC level, so they stay as alerts.)

## [2.6.3] — 2026-11-01 · Build 13

### Fixed
- The 60-second chart's window high and low are the highest and lowest "Now" price
  (the 60-second average it plots), and their breakout odds are measured from it.
  The faint 1-second price line is removed.

## [2.6.2] — 2026-10-31 · Build 12

### Changed
- Prediction log outcomes show a green up arrow for Up and a red down arrow for Down,
  matching the Call column.

## [2.6.1] — 2026-10-31 · Build 11

### Fixed
- Nothing is clipped, at the same pane widths and chart sizes:
  - The Strategy sidebar scrolls as a whole instead of cutting off content below its
    pinned height; long alert titles wrap.
  - The source list fits its quarter-width card: status shown as an icon (with a key and
    hover text), composite and index-estimate rows kept to the same columns.
  - "Best times to trade" day cards sit in a four-per-row grid of equal-width cards
    instead of a fixed-width row that ran off the edge.
  - Prediction log columns have minimum widths for their contents.
  - Accuracy card notes wrap instead of truncating.

## [2.6.0] — 2026-10-31 · Build 10

### Added
- The source list shows each source's weight in the composite (equal shares for Used
  sources, 0% otherwise), the composite price itself, and the index estimate
  (composite + BRTI calibration).

## [2.5.0] — 2026-10-31 · Build 9

### Added
- The Current Window card lists all eight price sources with each one's latest price,
  its gap from the combined price, and its status: Used, Trimmed (highest/lowest, left
  out of the average), Off-market, Stale or Waiting.

## [2.4.1] — 2026-10-31 · Build 8

### Changed
- The About window uses the plain system window background instead of the app's
  background image.

## [2.4.0] — 2026-10-31 · Build 7

### Added
- Call at any whole minute from +3 to +12 (never in the first or last three), each
  with its historical accuracy; history is rebuilt at the chosen time.
- "Confident calls only": choose All calls or ≥60–80% confidence. Windows below the
  threshold show "No call" and are left out of accuracy and performance (still logged
  and trained on); the Accuracy card shows how many were skipped.
- A clearer "Not financial advice" card in the About window.

### Changed
- The Call at, Calls and Use Kalshi odds settings moved from the toolbar into the
  Strategy card, under the trading style.

### Tested, not changed
- A slower recency half-life (30–180 days, or none) didn't improve held-out predictions
  over the current 14 days; all trail Kalshi's odds alone by ~0.05 Brier points, so
  the model keeps using Kalshi's odds.

## [2.3.0] — 2026-10-31 · Build 6

### Added
- Live-only promotion trials: a context indicator that exists only for windows the bot
  watched live (last-60s tick momentum) is now trialled on just those windows once
  there are 500 of them (~5 days), instead of never. Its card shows progress until then.

## [2.2.0] — 2026-10-31 · Build 5

### Added
- Each indicator card on the Indicators tab shows the model's current weight on it
  (updated after every retrain), "Not used" for context-only indicators, or "Off"
  when Kalshi's odds are turned off; hover for where the weight came from.

## [2.1.1] — 2026-10-31 · Build 4

### Fixed
- Accuracy updates as soon as a window settles: the bot polls the just-closed window
  every 2 seconds until Kalshi publishes the result (typically 5–20s after the close),
  and every tab redraws immediately instead of waiting for the next prediction.
- The model retrains right after each settlement; the Accuracy card shows when the
  last result landed and the Model card shows the retrain time to the second.

## [2.1.0] — 2026-10-31 · Build 3

### Added
- Momentum strength on the Reversal Risk card: the last 3 minutes' move against
  typical volatility (0–100%), its direction, and whether it's with or against the
  winning side. Context only — it didn't predict reversals in backtests.

### Changed
- Now, Trend and Projected (Close and Trend on the candle chart) stack under the
  settlement-average tag instead of following their price levels.
- Window high and low lines end at the current time and say when each was hit;
  breakout odds read as "chance of a new high/low". The 60-second chart shows the
  1-second price faintly so the high and low visibly touch it.
- The low label sits beneath its line.

### Fixed
- Window high and low include minutes before the app was running (backfilled from
  exchange 1-minute highs and lows at index level).

## [2.0.0] — 2026-10-31 · Build 2

### Changed (incompatible)
- Removed the MACD, signed-volume-flow and order-book indicators (and the briefly
  added Deribit futures signals): held-out tests showed they carried no information
  beyond Kalshi's price. They no longer appear in the model or the Indicators tab.
- Saved state from 1.0.0 is not carried over: the model, BRTI calibration and
  rebuilt training history are discarded and rebuilt on first launch.
- Reset now clears all data (predictions, training history, calibration, call-time
  statistics, alerts, activity) except settings, then retrains on Kalshi's full history.

### Added
- Selectable call time (+1/+3/+5/+8 min) with per-option historical accuracy.
- Live price feed from eight sources: Coinbase, Kraken and Bitstamp streamed;
  Gemini, Crypto.com, Binance.US, Deribit BTC/USDC and Kraken BTC/USDC polled.
- Training history extended to everything Kalshi has (~68 days today, up to 180).
- Strategy sidebar with entry/exit alerts and justifications, and Conservative /
  Neutral / Aggressive trading styles with reversal-risk and take-profit exits.
- Live Yes/No odds, buy/sell prices and the bot's live call on the Prediction card.
- Performance tab: day, hour, day × hour, week and month breakdowns against Kalshi,
  best times to trade, cumulative edge and emerging trends.
- Prediction log: confidence and Kalshi bid/ask columns, row hover highlight and a
  breakdown of why each call succeeded or failed.
- Window high/low lines with calibrated breakout odds; collision-free chart labels;
  movement and trend lines on the candle chart.
- Longest losing streak on the Accuracy card; Mac kept awake while the bot runs.

### Fixed
- Reversal risk and P(up) now measure from the current price with a backtested
  calibration (tails were understated; the 60s average lagged).
- Projected close uses the current price and 1-minute volatility, and its range
  narrows toward the close.
- Crash when two exchange quotes disagreed (NaN composite); charts reject invalid values.
- Source count showed "2 of 4": the outlier filter was too tight and the total was wrong.

## [1.0.0] — 2026-10-27

### Added
- Up/Down prediction for every Kalshi KXBTC15M window, locked 60 seconds after the open.
- Market-anchored model that starts from Kalshi's odds and only adopts learned
  adjustments that beat the market on held-out windows.
- 60 days of rebuilt training history with Kalshi's historical odds.
- BRTI price calibration against Kalshi's official targets.
- Dashboard: current window, prediction, accuracy (with margin of error and edge vs.
  Kalshi), model status, 60-second-average chart with trend projection, 1-minute
  candles, reversal risk, and candlestick pattern analysis.
- Indicators tab explaining each indicator's value at the call and now.
- Prediction log with CSV export, activity log, and model reset.
- About window with the end user license.
