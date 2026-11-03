# Contributing to Kalshi Bot

Thanks for your interest in Kalshi Bot.

Kalshi Bot is **proprietary software** (see [LICENSE](LICENSE)). The source code is public so people can read it, but it isn't open source.

## What's welcome

- **Bug reports.** Open an issue with the **Bug report** template.
- **Feature requests.** Open an issue with the **Feature request** template. For new indicators or signals, see "Proposing a new signal" below.
- **Questions about how something works.** Check the [User Manual](docs/USER_MANUAL.md) and [Known issues](docs/KNOWN_ISSUES.md) first.

**Code contributions are accepted only by prior arrangement.** Please don't open pull requests that haven't been agreed beforehand, because they can't be merged. If you'd like to help with code, open an issue describing what you'd like to do, and wait for a reply first.

**Security vulnerabilities** must not be reported in public issues. Follow [SECURITY.md](SECURITY.md) instead.

## How to write a good bug report

Before you report, search the [existing issues](https://github.com/jaldrich2023/KalshiBot/issues) and [Known issues](docs/KNOWN_ISSUES.md). Your problem may already be known.

Include:

- **The Kalshi Bot version** (**Kalshi Bot › About Kalshi Bot**, for example "Version 2.15.1 · Build 29").
- **The macOS version** (Apple menu › About This Mac) and your Mac model.
- **Steps to reproduce:** what you did, what you expected, and what happened instead.
- **The window.** Give the window's ticker (shown under the Current Window card, for example `KXBTC15M-26NOV021815-15`) and the time, if the problem is about a particular call, price or settlement.
- **The Activity tab.** Copy the lines around the time of the problem.
- **Screenshots,** if they help.

## Proposing a new signal

Kalshi's price is very hard to beat at this horizon. Every indicator tested so far added nothing on held-out windows: momentum, RSI, MACD, Bollinger, stochastic, VWAP, EMA, ADX/DI, order-book imbalance, trade flow, the perpetual futures premium, funding and DVOL. The user manual has the details. A useful proposal says how the signal would be computed from data available at the call, and ideally shows a held-out test (fit on older windows, score on newer ones) against Kalshi's price at the call.

## Keep personal data out of issues

Issues are public. Please **don't** include your Kalshi account details, balances or positions, anything that identifies you, or full file paths that reveal personal information.

## Code style (for agreed contributions)

- Swift 6 language features with SwiftUI and SwiftData. The project defaults to MainActor isolation; engine types are `nonisolated`.
- Swift Testing for unit tests. Every change to the engine needs tests.
- Charts use linear interpolation only (no smoothing), so lines never show prices that weren't seen.
- Every change bumps `MARKETING_VERSION` (SemVer), increments `CURRENT_PROJECT_VERSION`, and adds a [CHANGELOG](CHANGELOG.md) entry.
