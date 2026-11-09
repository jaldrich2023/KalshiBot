# Contributing to Kalshi Bot

Thanks for your interest in Kalshi Bot.

Kalshi Bot is **open source** under the [MIT License](LICENSE). Contributions are welcome; by submitting one, you agree it's licensed under the same terms.

## What's welcome

- **Bug reports.** Open an issue with the **Bug report** template.
- **Feature requests.** Open an issue with the **Feature request** template. For new indicators or signals, see "Proposing a new signal" below.
- **Questions about how something works.** Check the [User Manual](docs/USER_MANUAL.md) and [Known issues](docs/KNOWN_ISSUES.md) first.
- **Pull requests.** Fixes and improvements are welcome. For anything large, such as a new signal or a change to how the model decides, please open an issue first so we can agree the approach before you put in the work.

**Security vulnerabilities** must not be reported in public issues. Follow [SECURITY.md](SECURITY.md) instead.

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).

## How to write a good bug report

Before you report, search the [existing issues](https://github.com/jaldrich2023/KalshiBot/issues) and [Known issues](docs/KNOWN_ISSUES.md). Your problem may already be known.

Include:

- **The Kalshi Bot version** (**Kalshi Bot › About Kalshi Bot**, for example "Version 2.30.0 · Build 52").
- **The macOS version** (Apple menu › About This Mac) and your Mac model.
- **Steps to reproduce:** what you did, what you expected, and what happened instead.
- **The window.** Give the window's ticker (shown under the Current Window card, for example `KXBTC15M-26NOV021815-15`) and the time, if the problem is about a particular call, price or settlement.
- **The Activity tab.** Copy the lines around the time of the problem.
- **Screenshots,** if they help.

## Proposing a new signal

Kalshi's price is very hard to beat at this horizon. Every indicator tested so far added nothing on held-out windows: momentum, RSI, MACD, Bollinger, stochastic, VWAP, EMA, ADX/DI, order-book imbalance, trade flow, the perpetual futures premium, funding, DVOL, Kalshi's bid–ask spread, volume and last trade, and the previous window's result. The user manual has the details. A useful proposal says how the signal would be computed from data available at the call, and ideally shows a held-out test (fit on older windows, score on newer ones) against Kalshi's price at the call.

## Keep personal data out of issues

Issues are public. Please **don't** include your Kalshi account details, balances or positions, anything that identifies you, or full file paths that reveal personal information.

## Code style

- Swift 6 language features with SwiftUI and SwiftData. The project defaults to MainActor isolation; engine types are `nonisolated`.
- Swift Testing for unit tests. Every change to the engine needs tests.
- Charts use linear interpolation only (no smoothing), so lines never show prices that weren't seen.
- Every change bumps `MARKETING_VERSION` (SemVer), increments `CURRENT_PROJECT_VERSION`, and adds a [CHANGELOG](CHANGELOG.md) entry.
