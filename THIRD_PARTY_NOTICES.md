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

## Trademarks

Kalshi is a trademark of KalshiEX LLC. CF Benchmarks and BRTI (CF Bitcoin Real Time Index) are trademarks of CF Benchmarks Ltd. Coinbase, Kraken, Bitstamp, Gemini, Crypto.com, Binance.US, Deribit, OKX and KuCoin are trademarks of their respective owners.

Kalshi Bot's BRTI estimate is an independent approximation made from public exchange prices. It isn't the official index. Kalshi Bot and I'm The Team, LLC aren't affiliated with, endorsed by or sponsored by any of these companies.

## Artwork

The app icon and background artwork are part of Kalshi Bot and are covered by its [MIT License](LICENSE).
