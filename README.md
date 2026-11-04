<p align="center"><img src="docs/images/app-icon.png" width="128" alt="Kalshi Bot icon"></p>

<h1 align="center">Kalshi Bot</h1>

<p align="center">
A macOS app that calls every Kalshi 15-minute Bitcoin Up/Down window, shows the live odds and the evidence behind each call, and keeps an honest scorecard against Kalshi's own price.
</p>

<p align="center">
<a href="docs/Kalshi-Bot-Brochure.pdf"><b>Brochure (PDF)</b></a> ·
<a href="docs/Kalshi-Bot-User-Manual.pdf"><b>User Manual (PDF)</b></a> ·
<a href="docs/USER_MANUAL.md">Manual (Markdown)</a> ·
<a href="CHANGELOG.md">Changelog</a> ·
<a href="docs/KNOWN_ISSUES.md">Known issues</a> ·
<a href="https://github.com/jaldrich2023/KalshiBot/releases">Releases</a>
</p>

<p align="center">
<a href="https://github.com/jaldrich2023/KalshiBot/releases/latest"><img src="https://img.shields.io/github/v/release/jaldrich2023/KalshiBot?label=release&color=2ea44f" alt="Latest release"></a>
<a href="LICENSE"><img src="https://img.shields.io/github/license/jaldrich2023/KalshiBot?color=blue" alt="MIT License"></a>
<img src="https://img.shields.io/badge/macOS-27.2%2B-black?logo=apple" alt="macOS 27.2 or later">
<img src="https://img.shields.io/badge/Apple%20silicon-arm64-555" alt="Apple silicon">
<img src="https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white" alt="Swift and SwiftUI">
</p>

<p align="center"><a href="https://github.com/jaldrich2023/KalshiBot/releases/latest"><b>⬇︎ Download the latest version</b></a> · <a href="docs/INSTALL.md">Install guide</a></p>

<p align="center"><b>Current version: 2.27.0 (Build 48)</b> · macOS 27.2 or later</p>

![The dashboard during a live window](docs/images/01-dashboard.jpg)

> **Not financial advice.** Kalshi Bot gives statistical estimates for information and education only. Every call is a probability, not a certainty: a 70% call is expected to miss about 3 times in 10, and past accuracy doesn't guarantee future results, and event contracts carry a real risk of loss. See the [disclaimer](DISCLAIMER.md).

## What it does

Kalshi's **KXBTC15M** markets ask one question every 15 minutes: will Bitcoin's settlement price, the CF Benchmarks BRTI 60-second average at the close, finish at or above the price at the open? Kalshi Bot follows every window:

- **Calls each window.** It makes a call (Up or Down, with a probability) at a minute you choose, from +3 to +12 minutes after the open. The call is locked and logged, then scored when Kalshi settles it.
- **Shows the live picture.** It builds its own BRTI estimate from ten exchange feeds, each corrected by its measured offset from the official index, and shows the typical tracking error. It also shows Kalshi's live Yes/No prices, and draws the 60-second average on a chart. The chart also marks the target, the window's actual high and low, a projected close, and your stop-loss and take-profit levels.
- **Estimates the risk of a reversal.** It gives the calibrated chance that the side now ahead loses (shown next to Kalshi's own figure), how strong the momentum is, and how likely the price is to break the window's high or low. The corrections refit from history, and a live check shows how often its figures came true.
- **Recommends trades for your style.** Conservative, Neutral and Aggressive set the required edge, the price range, the entry cutoff and the exits. It suggests entries only on the side it called. You can set your own stop-loss and take-profit percentages, and a stake for profit and loss estimates.
- **Keeps score honestly.** It reports accuracy with margins of error, Brier scores, and paired comparisons with Kalshi's favorite on the same windows. It shows how many correct calls it needs to reach 70%. Results are broken down by day, hour, week and month.
- **Trains itself and checks its work.** It learns from up to 180 days of public Kalshi and Coinbase history, saved on disk so later launches fetch only what's new, plus every live window. Learned weights are used only when they beat Kalshi's own odds in most of four walk-forward blocks of windows they weren't trained on, by more than chance. The other indicators are re-tested after every window and promoted only after significant wins on three separate sets of fresh windows, with the bar raised for testing several signals at once.
- **Explains every number.** Rest the pointer on any figure, setting or button for a popover with what it means, how it's calculated and how to read it.
- **Runs unattended.** It keeps the Mac awake while it runs (optional), reconnects dropped or silent price streams on its own, and can reset just the model, clear the data after copying the log, or erase everything including settings and the saved download.

### What to expect

Kalshi Bot's calls are calibrated: when it says 70%, the called side wins about 70% of the time. Across more than 6,000 past windows, calls at 55–60% won 58%, calls at 70–80% won 77%, and calls at 80–90% won 87%. Live, it has called every window on time and been right on about 68% of them, in line with its stated confidence.

You choose the trade-off between how many calls you get and how often they're right. Calling later in the window, or counting only confident calls, raises the hit rate: calls of 70% or more at +9 minutes were right 88% of the time.

Every signal is held to the same standard: it has to improve predictions on windows it wasn't trained on before it counts. Kalshi's own price sets that bar. Fifteen technical indicators, order-book, trade-flow, funding and volatility data haven't cleared it yet, so for now the bot anchors on Kalshi's odds and tells you exactly why. The trials run after every window, so a signal that starts to help is picked up automatically.

## Screenshots

| | |
| --- | --- |
| ![Indicators](docs/images/02-indicators.jpg) | ![Performance](docs/images/03-performance.jpg) |
| **Indicators.** Every signal, its value at the call and now, its weight, and why it is or isn't moving the call. | **Performance.** Day, hour, week and month, against Kalshi; hover any item for details. |
| ![Prediction log](docs/images/04-prediction-log.jpg) | ![Price chart](docs/images/07-price-chart.jpg) |
| **Prediction log.** Every call and result; hover a row for why it won or lost. | **60-second average chart.** Target, actual high and low, projection, stop-loss and take-profit. |

## Requirements

- macOS 27.2 or later
- Xcode 27.2 or later to build from source
- An internet connection. Kalshi Bot reads public market data and needs **no account and no API keys**. It never places orders.

## Installing the app

Each [release](https://github.com/jaldrich2023/KalshiBot/releases) includes a ready-to-run copy, `KalshiBot-<version>-macOS.zip`, for Apple silicon Macs on macOS 27.2 or later.

> **Not a signed developer build.** The download is only ad-hoc signed: it isn't signed with an Apple Developer ID or notarized by Apple, so macOS blocks it the first time. Approve it once in **System Settings › Privacy & Security › Open Anyway**. Step-by-step instructions, including a Terminal alternative and how to verify the download's checksum, are in **[docs/INSTALL.md](docs/INSTALL.md)**.

## Building

1. Clone the repository and open `KalshiBot.xcodeproj` in Xcode.
2. Select the **KalshiBot** scheme and **My Mac**, then choose **Product › Run** (⌘R).
3. On first launch it downloads Kalshi's market history and rebuilds the past windows for training. This takes a few minutes the first time; progress shows in the Model card. The download is saved, so later launches take seconds.

The install notice needs an ingest key, which isn't in the repository. To send it from your own build, copy `config/ITTConfig.example.plist` to `KalshiBot/Resources/ITTConfig.plist` (gitignored) and paste the key into `ITTAPIKey`. Without it, builds work normally and send nothing.

Run the tests with **Product › Test** (⌘U). The suite uses Swift Testing. One long network research test (`KalshiFlowProbe`) is disabled by default; enable it to run it on demand.

## Project layout

| Path | Contents |
| --- | --- |
| `KalshiBot/Engine/` | `BotEngine` (the app's state and the window loop), `Predictor` (features and the market-anchored model), `ModelTrainer` (fitting, holdout tests, promotion trials), `ReversalRisk` (calibrated flip and breakout odds), `StrategyAdvisor` (styles, advice, exit plans), indicators, candle patterns and the close projection |
| `KalshiBot/Services/` | `LivePriceFeed` (WebSocket and REST exchange feeds, per-exchange offsets and the composite price), `MarketClients` (Kalshi, Coinbase history and the exchange clients) and `HistoryCache` (the saved market download) |
| `KalshiBot/Models/` | SwiftData records (`PredictionRecord`, `TrainingExample`), accuracy and performance statistics, call explanations and the app version |
| `KalshiBot/Views/` | The SwiftUI interface: dashboard cards, charts, the indicator guide, performance, the log and About |
| `KalshiBotTests/` | Unit tests (Swift Testing) |
| `docs/` | The user manual, brochure, known issues, screenshots and the scripts that build the PDFs |

## Documentation

- [User Manual](docs/USER_MANUAL.md) ([PDF](docs/Kalshi-Bot-User-Manual.pdf))
- [Brochure](docs/Kalshi-Bot-Brochure.pdf)
- [Installing the app](docs/INSTALL.md)
- [Known issues](docs/KNOWN_ISSUES.md)
- [Changelog](CHANGELOG.md)
- [Releases](https://github.com/jaldrich2023/KalshiBot/releases)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
- [Disclaimer](DISCLAIMER.md)

To rebuild the PDFs after editing the docs, run `docs/tools/make_pdfs.sh`. It regenerates the manual's HTML from `docs/USER_MANUAL.md` and prints both documents with WebKit, with no browser needed.

## Privacy

Kalshi Bot sends an anonymous install notice to I'm The Team, LLC (`www.imtheteam.com`) once per installation, and again after each update and about once a month: a random install id generated on your Mac, the app version and build, the macOS version, the Mac model (for example `Mac16,10`), the locale and the time zone (for example `America/Chicago`). The app never looks up its own location; the server derives an approximate one (country, region, city) from the IP address of the connection that delivers the notice. It contains no personal data — no name, account, serial number, prediction log or trading data, and the app doesn't send its IP address itself. The reply may name a newer release, which the app offers as a dismissible notice; it never downloads or installs anything by itself. Turn it off in **Kalshi Bot › Settings…** (⌘,).

**Crash and bug reports.** Reporting is **off by default**. Turn it on in **Kalshi Bot › Settings…** (⌘,) with **Send crash and bug reports**, and off the same way. When it's on and Kalshi Bot crashes, the next launch sends an anonymous report to I'm The Team, LLC: the crash type and message, the stack trace, a fingerprint that groups repeats, the last 300 lines of the app's own log with API keys, tokens, passwords and e-mail addresses masked, the app and macOS versions, the Mac model, the locale, the random install id and the bot's non-personal settings (call time, threshold, trading style and similar — not your stake). While it's off, a crash leaves only a local file, and the next launch asks once — **Send**, **Don't Send** or **Always Send**. **Help › Report a Problem…** sends a bug report or feedback you write yourself (with an optional contact e-mail and, if you leave it checked, recent logs; **Preview…** shows exactly what will be sent); it works whether or not automatic reports are on. Paths under your home folder are shortened to `~` and your user name is removed; no documents, window titles or clipboard contents are included. Crash files wait in `~/Library/Containers/I-m-The-Team.KalshiBot/Data/Library/Application Support/crashes/` (at most 20). A report that can't be sent yet waits in the `outbox` folder beside it (at most 50) and is retried at the next launch and every 10 minutes, backing off up to 12 hours; the app's logs are in the `Logs` folder there too.

Everything else — the prediction log, history, model and settings — stays on your Mac.

## Contributing and security

Kalshi Bot is open source under the MIT License. Bug reports, feature requests and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Please report security problems privately, as described in [SECURITY.md](SECURITY.md). Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).

## License

Copyright © 2026 I'm The Team, LLC. Kalshi Bot is free and open-source software under the [MIT License](LICENSE): you may use, copy, modify and distribute it, provided the copyright notice and license are included. It comes with no warranty.

Please also read the [disclaimer](DISCLAIMER.md): Kalshi Bot isn't financial advice. Kalshi, CF Benchmarks, BRTI and the exchange names are trademarks of their respective owners, and Kalshi Bot isn't affiliated with, endorsed by or sponsored by any of them.
