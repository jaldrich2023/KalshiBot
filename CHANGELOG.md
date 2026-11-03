# Changelog

All notable changes to Kalshi Bot are documented here. The project follows
[Semantic Versioning](https://semver.org): MAJOR for incompatible changes, MINOR for
new features, PATCH for fixes. Set the version in the target's `MARKETING_VERSION`
build setting; the build number is `CURRENT_PROJECT_VERSION`.

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
