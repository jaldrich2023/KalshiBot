# Security policy

## Reporting a vulnerability

**Please don't report security problems in public issues.**

Report them privately using GitHub's private vulnerability reporting:

1. Go to the repository's **[Security](https://github.com/jaldrich2023/KalshiBot/security)** tab.
2. Click **Report a vulnerability**. This opens a private Security Advisory that only you and the maintainer can see.
3. Include:
   - what the problem is and what someone could do with it,
   - the steps to reproduce it,
   - the version of Kalshi Bot (**Kalshi Bot › About Kalshi Bot**, for example "Version 2.14.2 · Build 27") and of macOS.

You'll get an acknowledgement as soon as possible, followed by updates as the issue is investigated and fixed. Please give a reasonable amount of time for a fix before you disclose anything publicly.

## Supported versions

| Version | Supported |
| --- | --- |
| 2.14.x (latest) | Yes |
| Earlier | No — update to the latest version |

## Scope

Kalshi Bot is a sandboxed macOS app. It makes **outgoing** connections only, to public market-data endpoints. It runs no server, accepts no incoming connections, needs no account or API keys, stores no credentials, and never places orders.

In scope:

- **Parsing untrusted network data.** This covers Kalshi's market and history responses, Coinbase candles, and the exchange tickers and WebSocket messages (Coinbase, Kraken, Bitstamp, Gemini, Crypto.com, Binance.US and Deribit). Malformed or hostile responses should never crash the app or corrupt its stored data.
- **The composite price.** The off-market filter and the outlier trimming in `Services/LivePriceFeed.swift` should stop a single bad or manipulated feed from moving the price far.
- **Local data.** This covers the SwiftData store (the prediction log and training history) and the settings in the app's sandbox container.

Out of scope:

- The accuracy of predictions, odds or recommendations. These are statistical estimates, not security properties; see the license's "Not financial advice" section.
- The availability or correctness of the third-party services themselves.
- Problems that need someone who already controls your Mac or your user account.
