# Kalshi Bot — User Manual

Calls, live odds and an honest scorecard for Kalshi's 15-minute Bitcoin markets.

Version 2.14 · macOS 27.2 or later · © 2026 I'm The Team, LLC

![The dashboard during a live window](images/01-dashboard.jpg)

Kalshi Bot follows every Kalshi KXBTC15M window. It makes a call at the minute you choose, shows you the live market and the evidence behind the call, suggests entries and exits for your trading style, and scores every result against Kalshi's own price. This manual explains every card, chart and setting.

---

## Contents

## 1. Getting started

### Before you begin

> **Kalshi Bot isn't financial advice.** It gives statistical estimates for information and education only. Its predictions are often wrong, past accuracy doesn't guarantee future results, and event contracts carry a real risk of loss. You're responsible for your own trading decisions.

You need:

- a Mac running macOS 27.2 or later,
- an internet connection.

You don't need a Kalshi account or any API keys. Kalshi Bot reads only public market data, and it **never places orders**. Any trade you make, you make yourself on Kalshi.

### First launch

1. Open Kalshi Bot. It starts automatically, and the status pill at the top left of the toolbar turns to **Live**.
2. The **Model** card shows "Rebuilding past windows…". Kalshi Bot downloads up to 180 days of Kalshi market history and Coinbase 1-minute candles, then rebuilds each past window as it looked at the call. This takes about a minute.
3. When the current window reaches the call time (+3 minutes by default), the **Prediction** card locks a call: Up or Down, with a probability.
4. When the window closes and Kalshi settles it, the call is scored, the **Accuracy** card updates, and the model retrains.

While it's running, Kalshi Bot keeps your Mac from sleeping, so it doesn't miss a window. Click **Stop** in the toolbar to pause it; click **Start** to resume.

### The toolbar

| Item | What it does |
| --- | --- |
| Status pill | **Live** while the bot is running. |
| Tabs | Dashboard, Indicators, Performance, Prediction Log and Activity. |
| Copy CSV | Copies the whole prediction log to the clipboard as CSV, for a spreadsheet. |
| Start / Stop | Starts or pauses the bot. |

## 2. How the markets work

Each KXBTC15M market covers one 15-minute window, for example 5:00–5:15 PM Eastern. It asks a single question: **will Bitcoin settle at or above the target?**

- **The target** is the CF Benchmarks Bitcoin Real Time Index (BRTI), averaged over the 60 seconds before the window opens.
- **The settlement** is the same 60-second average over the last minute of the window.
- **Yes** pays $1 if it settles at or above the target ("Up"). **No** pays $1 if it settles below ("Down").
- A contract's price, between 1¢ and 99¢, is the market's probability. Yes at 62¢ means the market gives Up about a 62% chance.

Kalshi charges a taker fee on each trade, rounded up to the next cent: 7% × price × (1 − price) per contract. Kalshi Bot includes this fee, and half the bid/ask spread, in every edge and profit figure it shows.

Because both the target and the settlement are 60-second averages, the last minute matters a lot. Once the settlement minute starts, every second that passes locks in part of the answer. Kalshi Bot's odds take that into account.

## 3. The Dashboard

![The top row: current window, prediction, accuracy and model](images/06-top-row.jpg)

### Current Window

- **The price** is Kalshi Bot's estimate of the BRTI right now, with how far it is above or below the target.
- **Window, Closes in, Target, Kalshi Yes** show the window's times, the time left, the target price, and Kalshi's live Yes price.
- **Sources** lists the eight exchange feeds and each one's latest price, its gap to the estimate, and its weight. A ✓ means the source is in use. A source is dropped when its price is off-market (more than 0.05% from the median) or its feed has gone stale. With five or more sources, the highest and lowest are trimmed.
- **Composite** is the average of the sources in use. **Index est.** applies the **BRTI calibration**, a running correction learned by comparing past composites with Kalshi's published targets.
- The window's ticker is shown at the bottom, for example `KXBTC15M-26NOV021815-15`.

### Prediction

Before the call time, the card says "No prediction locked for this window" and shows the live view only. At the call time it locks:

- **The call:** a large **UP** or **DOWN**, with P(up) and the confidence (the probability of the side called).
- **Live:** Kalshi's Yes and No prices right now, as percentages, with the buy and sell prices in cents.
- **Bot now:** what the model would say from the current price. This is for information only; the locked call doesn't change.

### Accuracy

The scorecard for every settled call:

- **Accuracy**, with how many were correct and a 95% margin of error.
- **Expected correct:** how many the bot's own probabilities said should be right, with a 95% range. If the actual number is inside the range, the difference is ordinary luck.
- **Brier score:** the average squared error of the probabilities. Lower is better; 0.25 is a coin flip.
- **Kalshi favorite accuracy, Kalshi Brier score, Edge vs. Kalshi:** the same measures for Kalshi's own price on the same windows, and the difference with its margin of error.
- **When ≥65% confident:** accuracy on the more confident calls, for the bot and for Kalshi.
- **Streaks:** the current streak, the longest win streak and the longest losing streak.
- **By confidence:** accuracy in each confidence band. Well-calibrated calls are right about as often as their confidence says. For example, 55–60% calls should lose about 4 times in 10.

If **Calls** is set to confident calls only (see chapter 4), the card says how many low-confidence windows were skipped.

### Model

- **Trained on:** the windows the model learned from. **Live / rebuilt** splits them into windows the bot watched live and windows rebuilt from history.
- **Predicting with:** **Kalshi market** while learned adjustments haven't beaten Kalshi's own odds, or **Learned weights** once they have.
- **Holdout test:** the trained model and Kalshi's price, scored on the newest 20% of windows that the training never saw.
- **Path to 70% accuracy:** the number of correct calls in a row needed to bring overall accuracy to 70%, or, once it's there, how many misses in a row it can absorb. Each miss on the way adds about 2.3 more needed. The note underneath compares the goal with the calls' average confidence, which is where accuracy tends over time.
- **Reset Model…** asks for confirmation, then deletes all data and retrains from scratch. See chapter 10.

### The 60-second average chart

![The 60-second average chart, with stop-loss and take-profit](images/07-price-chart.jpg)

This chart follows the same 60-second average that Kalshi settles on, across the whole window.

- **Target:** the dashed line the window must finish at or above for Up.
- **High and Low:** the highest and lowest values the 60-second average has actually reached in this window, with the time and the chance of a new high or low before the close.
- **Now, Trend and Projected:** the current value, the trend over the last few minutes, and the projected close, with the likely close range shaded.
- **Settlement minute:** the shaded final minute.
- **Stop-loss and Take profit:** once a call is locked, these show where to exit the side that was called. Each label says what the contract would sell for at that price and your profit or loss at your stake. See chapter 4.

Use **Layers** at the top right to show or hide each element: the 60s average, Now, Target, Settlement minute, High/Low, Close range, Trend, Projection, and Stop & take profit. Labels are arranged so they don't overlap one another, the lines, or the Now dot.

### The 1-minute candles chart

The same window as 1-minute candles, with its own **Layers** menu. The **Candle pattern** card beside it names any recognized pattern in the latest candles, such as a hammer, an engulfing pattern, a doji or three white soldiers, and says whether it gives this window an edge. Patterns are informational only; they aren't model inputs.

### Reversal Risk

![The reversal risk card](images/09-reversal-risk.jpg)

- **The headline percentage** is the chance that the side currently ahead loses by the close: 0% means a sure thing, and 100% would be a coin flip. It's labeled **Low**, **Moderate** or **High**.
- **Chance of flipping, Currently, Cushion:** the flip chance for the side behind, how far the price is from the target, and that distance in units of expected movement (σ).
- **Momentum strength:** how strongly the price has moved over the last 3 minutes compared with normal, and whether it's moving with or against the side that's winning.
- **Breaks above window high, Breaks below window low:** the chance of a new high or low before the close.

These odds come from a random-walk model of the 60-second average, calibrated on past windows. Momentum, pullbacks, wicks, RSI and target crossings were all tested as early warnings. None of them added anything beyond these calibrated odds.

## 4. Trade recommendations

![The Strategy card](images/08-strategy.jpg)

The **Strategy** card on the right of the dashboard turns the call and Kalshi's prices into a suggestion. It never trades for you.

### Trading styles

Choose **Conservative**, **Neutral** or **Aggressive** at the top of the card:

| Setting | Conservative | Neutral | Aggressive |
| --- | --- | --- | --- |
| Minimum edge to enter (per contract, after fees) | 8¢ | 5¢ | 3¢ |
| Contract prices it will suggest | 25¢–75¢ | 10¢–90¢ | 1¢–99¢ |
| No new entries with less than | 5 min left | 2 min left | 1 min left |
| Exit when the side's chance of losing reaches | 25% | 35% | 50% |
| Default stop-loss (share of the price paid) | 30% | 50% | 70% |
| Take-profit (share of the most it could sell for) | 60% | 80% | 95% |
| Trailing stop keeps at least this share of the best gain | 60% | 50% | 30% |

### The recommendation

The headline is one of:

- **Buy Yes** or **Buy No**, when the side called is cheap enough compared with the bot's fair value to clear the style's edge, after the fee and half the spread. Entries are suggested only on the side the bot called.
- **Stand aside — no edge**, when the price is close to fair value. This is the usual case when the bot follows Kalshi's odds.
- **Stand aside — against the call**, when the only edge would be on the side the bot didn't call.

Underneath, the card shows the bot's fair value, Kalshi's Yes bid and ask, and the edge on each side.

### Call settings

| Setting | Choices | What it does |
| --- | --- | --- |
| Call at | +3 to +12 min | When each window's call locks. The menu shows how often calls at that minute were right in history. Later calls are right more often, but Kalshi's price has moved too. Changing it rebuilds the model's history at the new time. |
| Calls | All calls, or only ≥60%, 65%, 70%, 75% or 80% confident | Calls below the threshold are marked **No call** and left out of accuracy and performance. Every window is still logged and trained on. |
| Stop-loss | Style default, or Custom: 5%–70% | The share of the price paid that you're willing to lose before exiting. |
| Take profit | Style default, or Custom: 5%–100% | The gain on the price paid at which to sell. If the gain isn't possible at the current price, the card says it's unreachable and no line is drawn. |
| Use Kalshi odds | On or off | When on, the model starts from Kalshi's price and adjusts it only with signals that have proven themselves. **Leave this on.** With it off, the model uses price signals alone, which is much less accurate and can disagree with the market for no good reason. |

### Your position

Enter your **Stake** per window. Once a call is locked, the card shows:

- how many whole contracts the stake buys on the called side, at the ask, and what they cost,
- **If sold now:** the result of selling at the bid, after the fee,
- **If it settles Up / Down:** the result at settlement either way,
- **Expected at settlement:** the average of the two, weighted by the bot's probability,
- **At stop-loss** and **At take profit:** the result if you exit at those lines.

### Stop-loss and take-profit lines

Both lines are drawn on the 60-second average chart, in Bitcoin prices, so you can see how far the price has to move to reach them. They're based on the current market: the time left, volatility, and how far Kalshi's price has strayed from the bot's odds.

- **Stop-loss** limits your loss if the call is going wrong. After you've been in profit by at least 10¢ (or a quarter of the best gain), it becomes a **trailing stop**, which keeps at least the style's share of the best gain so far.
- **Take profit** locks in a gain when the call is going right.

### Entry and exit alerts

The **Entry & exit alerts** list shows each suggestion as it happens, with the time and the reason. For example: "If holding Yes: exit at 14¢. From the current price, Yes now loses 86% of the time…". Alerts that no longer apply are marked **No longer active**.

## 5. Indicators

![The Indicators tab](images/02-indicators.jpg)

The **Indicators** tab shows every signal the bot computes, each on its own card:

- **At call / Now:** the value when the call locked, and the value now.
- **Weight:** the signal's weight in the model. **Not used** means it isn't a model input.
- **Favors Up / Favors Down:** the direction the signal points.
- **Reading now:** what the value means in plain language.
- **Effect on prediction:** whether it's moving the call and why.

### Model inputs

**Spot vs. target**, **5m momentum**, **RSI(14)** and **Kalshi implied odds** are the only signals that can move the call. Each starts at zero weight and earns weight only by improving predictions on held-out windows. Kalshi's implied odds are the anchor: the call starts from Kalshi's price, and the others can shift it only once they've proven themselves.

### Context only

**Last-60s tick momentum**, **15m momentum**, **EMA 9/21 trend**, **Bollinger %B**, **Stochastic %K** and **VWAP(60) deviation** move closely with a model input, so counting them too would count the same information twice. After every retrain, each is re-tested on held-out windows; three significant wins in a row would promote it into the model. Tick momentum exists only in live windows, so it's tested on those alone, once 500 are available.

### What has been tested

Held-out tests (fit on older windows, scored on newer ones) found **no signal that predicts these windows beyond Kalshi's own price at the call**. This includes the 15 technical indicators; ADX and ±DI; order-book imbalance; Coinbase taker trade flow; the Deribit perpetual premium and funding rate; and DVOL. Kalshi's price was well calibrated across more than 6,000 windows. Calls at 55–60% won 58% of the time, at 60–65% they won 63%, and at 70–80% they won 77%.

That's why the bot usually follows Kalshi's odds. If you want a higher hit rate, take only the confident calls, with **Calls** set to ≥60% or higher. Low-confidence calls are close to coin flips, and they're priced that way.

## 6. Performance

![The Performance tab](images/03-performance.jpg)

The **Performance** tab compares the bot with Kalshi's price over time. All times are Eastern, Kalshi's clock. Green marks periods where the bot's probabilities were closer to the outcomes than Kalshi's; red marks periods where Kalshi's were closer.

- **Against Kalshi:** windows, bot accuracy, Kalshi favorite accuracy, and the **Brier edge** per window. That's Kalshi's squared error minus the bot's, in points. Positive means the bot was closer.
- **Best times to trade:** days of the week ranked by Brier edge, each with its 4-hour blocks ranked. Days or blocks with fewer than 30 windows are marked "few windows", because a handful of results can change their rank.
- **Emerging trends:** patterns forming in recent results, such as calls beating their confidence. Each is marked as an early sign or as confirmed.
- **Cumulative edge over Kalshi:** the running total of the per-window edge. Rising means the bot is pulling ahead, falling means it's falling behind, and flat means it's matching Kalshi.
- **Hour by hour and Day × hour:** the edge for each hour of the day, and for each hour on each day.
- **Day by day, Week by week, Month by month:** tables of every period, with **beyond noise** shown when the difference is bigger than its margin of error.

### Hover for details

Rest the pointer on any bar, heatmap cell, day card, time block or table row. After a moment, a popover opens at the pointer with that period's details: windows, accuracy for the bot and Kalshi, Brier edge with its margin, whether it's beyond the noise, how many windows settled Up, the bot's average confidence, and how often the bot and Kalshi disagreed. On the cumulative edge chart, the popover shows the nearest window's full call breakdown and what that window added to the running edge. Popovers open away from the nearer edge of the screen.

## 7. Prediction Log

![The Prediction Log](images/04-prediction-log.jpg)

Every window the bot has followed, newest first:

| Column | Meaning |
| --- | --- |
| Window | The window's start time. |
| Target | The window's target price. |
| Spot at call | The bot's BRTI estimate when the call locked. |
| P(up) | The bot's probability of Up. |
| Call | ↑ Up or ↓ Down. |
| Confidence | The probability of the side called. Faded when the call is below your Calls threshold. |
| Kalshi Yes | Kalshi's Yes price at the call, with the bid and ask. |
| Settled at | The settlement value. |
| Outcome | ↑ Up in green or ↓ Down in red. |
| Result | Correct, Wrong, Live (not settled yet), or No call. |

Rest the pointer on a row to highlight it. After a moment, a popover explains **why the call succeeded or failed**: where the price stood at the call, whether the lead held or reversed, how close the finish was, and which signals moved the call.

**Copy CSV** in the toolbar copies the whole log, including bid and ask, for a spreadsheet.

## 8. Activity

![The Activity log](images/05-activity.jpg)

A timestamped list of what the bot is doing: windows opening, calls locking, settlements, retraining results, history rebuilds and alerts. If something looks wrong, this is the first place to check, and the lines to include in a bug report.

## 9. How the model learns

- **Training data.** Every settled window is a training example: the live windows the bot watched, plus past windows rebuilt from Kalshi's history and Coinbase's 1-minute candles (up to 180 days). Recent windows count more than old ones.
- **Market-anchored.** The model starts from Kalshi's own odds. Learned weights adjust those odds only when the inputs carry information the price doesn't.
- **Held-out check.** After every settlement, the model retrains on the older 80% of windows and is scored on the newest 20%. Learned weights are used only if they beat Kalshi's odds on those unseen windows; otherwise the bot follows Kalshi.
- **Promotion trials.** Context-only signals are re-tested after each retrain, and three significant wins in a row would promote one into the model.
- **Updates right after the close.** Accuracy updates and the model retrains as soon as Kalshi settles a window, without waiting for the next call.

## 10. Your data

All data stays on your Mac, in Kalshi Bot's sandboxed container. Nothing is sent anywhere except the public market-data requests described in [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md).

**Reset Model…** in the Model card returns the model to its starting weights and permanently deletes:

- the prediction log and accuracy history,
- the training history,
- the price calibration,
- the call-time statistics,
- the alerts and the activity log.

Your settings are kept. The model then retrains from scratch on Kalshi's full market history, which takes about a minute. To keep a copy of your log, use **Copy CSV** first.

## 11. Troubleshooting

**The Prediction card says "No prediction locked for this window".** The call locks at the minute set in **Call at** (+3 by default). If the bot was started after that minute, it waits for the next window.

**The bot recommends a side that the market clearly disagrees with.** Check that **Use Kalshi odds** is on. With it off, the model uses price signals alone and can disagree with the market for no good reason.

**My 55–60% calls keep losing.** That's expected: a 57% call loses about 43% of the time. Set **Calls** to ≥60% or higher to skip low-confidence windows.

**Fewer than 8 sources are live.** A source is dropped when its feed goes stale or its price is more than 0.05% away from the others. The composite needs only a few sources, and dropped sources come back on their own.

**The Model card says learned adjustments haven't beaten Kalshi's odds.** That's the normal state. It means the bot is following Kalshi's price, which no tested signal has beaten.

**The charts say "Collecting 60s of prices…".** The 60-second average needs a minute of prices after launch or after a gap in the feeds.

**The Model card has said "Rebuilding past windows…" for a long time.** The history download depends on Kalshi's and Coinbase's public APIs, which can be slow or limit requests. Leave the app running; it retries.

## 12. Legal

Kalshi Bot is licensed, not sold, under the end user license agreement in [LICENSE](../LICENSE). Its source code is public to read, but reading it gives you no right to copy, modify or redistribute it.

Kalshi Bot isn't financial advice. Its predictions are probabilistic and often wrong, and event contracts and digital assets involve a substantial risk of loss.

Kalshi, CF Benchmarks, BRTI and the exchange names are trademarks of their respective owners. Kalshi Bot's BRTI estimate is an independent approximation, not the official index. I'm The Team, LLC isn't affiliated with, endorsed by or sponsored by any of them.
