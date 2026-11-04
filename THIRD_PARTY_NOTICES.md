# Third-party notices

Kalshi Bot contains **no third-party code**. It's built only on Apple's system frameworks: SwiftUI, Swift Charts, SwiftData, Foundation and AppKit.

## Data services

Kalshi Bot reads publicly available data from the services below. It doesn't use API keys, accounts or authenticated endpoints, and it never places orders. Data from each service is subject to that service's own terms of use, which you agree to follow when you use Kalshi Bot.

| Service | What Kalshi Bot reads | Endpoint |
| --- | --- | --- |
| Kalshi | KXBTC15M markets: targets, live Yes bid/ask, settlements, and price history for training | `api.elections.kalshi.com/trade-api/v2` |
| Coinbase Exchange | BTC-USD ticker (WebSocket), and 1-minute candles for training history | `ws-feed.exchange.coinbase.com`, `api.exchange.coinbase.com` |
| Kraken | XBT/USD (WebSocket) and XBT/USDC tickers | `ws.kraken.com/v2`, `api.kraken.com` |
| Bitstamp | BTC/USD ticker (WebSocket) | `ws.bitstamp.net`, `www.bitstamp.net` |
| Gemini | BTC/USD ticker | `api.gemini.com` |
| Crypto.com Exchange | BTC_USD ticker | `api.crypto.com` |
| Binance.US | BTC/USD best bid/ask | `api.binance.us` |
| Deribit | BTC_USDC spot ticker | `www.deribit.com` |
| OKX | BTC-USDC ticker | `www.okx.com` |
| KuCoin | BTC-USDC best bid/ask | `api.kucoin.com` |

## Install notice

Kalshi Bot sends an anonymous install notice to I'm The Team, LLC (`www.imtheteam.com`) once per installation, and again after each update and about once a month: a random install id generated on your Mac, the app version and build, the macOS version, the Mac model (for example `Mac16,10`), the locale and the time zone (for example `America/Chicago`). The app never looks up its own location; the server derives an approximate one (country, region, city) from the IP address of the connection that delivers the notice. It contains no personal data — no name, account, serial number, prediction log or trading data, and the app doesn't send its IP address itself. The reply may name a newer release, which the app offers as a dismissible notice; it never downloads or installs anything by itself. Builds made from source send it only if an ingest key is set in `KalshiBot/Resources/ITTConfig.plist` (see the README); it can be turned off in **Kalshi Bot › Settings…**.

## Crash and bug reports

Reporting is **off by default**. Turn it on in **Kalshi Bot › Settings…** (⌘,) with **Send crash and bug reports**, and off the same way. When it's on and Kalshi Bot crashes, the next launch sends an anonymous report to I'm The Team, LLC: the crash type and message, the stack trace, a fingerprint that groups repeats, the last 300 lines of the app's own log with API keys, tokens, passwords and e-mail addresses masked, the app and macOS versions, the Mac model, the locale, the random install id and the bot's non-personal settings (call time, threshold, trading style and similar — not your stake). While it's off, a crash leaves only a local file, and the next launch asks once — **Send**, **Don't Send** or **Always Send**. **Help › Report a Problem…** sends a bug report or feedback you write yourself (with an optional contact e-mail and, if you leave it checked, recent logs; **Preview…** shows exactly what will be sent); it works whether or not automatic reports are on. Paths under your home folder are shortened to `~` and your user name is removed; no documents, window titles or clipboard contents are included. Crash files wait in `~/Library/Containers/I-m-The-Team.KalshiBot/Data/Library/Application Support/crashes/` (at most 20). A report that can't be sent yet waits in the `outbox` folder beside it (at most 50) and is retried at the next launch and every 10 minutes, backing off up to 12 hours; the app's logs are in the `Logs` folder there too. Reports go to `www.imtheteam.com`, and only when an ingest key is set. Update checks ask `www.imtheteam.com` for the newest release (no key, no data about you beyond the request itself), at most every 6 hours or when you choose **Check for Updates…**.

## Trademarks

Kalshi is a trademark of KalshiEX LLC. CF Benchmarks and BRTI (CF Bitcoin Real Time Index) are trademarks of CF Benchmarks Ltd. Coinbase, Kraken, Bitstamp, Gemini, Crypto.com, Binance.US, Deribit, OKX and KuCoin are trademarks of their respective owners.

Kalshi Bot's BRTI estimate is an independent approximation made from public exchange prices. It isn't the official index. Kalshi Bot and I'm The Team, LLC aren't affiliated with, endorsed by or sponsored by any of these companies.

## Artwork

The app icon and background artwork are part of Kalshi Bot and are covered by its [MIT License](LICENSE).
