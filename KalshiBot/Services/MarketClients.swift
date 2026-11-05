//
//  MarketClients.swift
//  KalshiBot
//
//  Public, unauthenticated REST endpoints for Kalshi and spot exchanges.
//

import Foundation

nonisolated enum ClientError: Error, LocalizedError {
    case badResponse(String)
    case httpStatus(Int, host: String, path: String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let source):
            "Unexpected response from \(source)"
        case .httpStatus(let code, let host, let path):
            "\(host) returned HTTP \(code)\(code == 429 ? " (rate limited)" : "") for \(path)"
        }
    }
}

/// Network failures worth another try: the request may well succeed a moment later.
private nonisolated func isTransient(_ error: Error) -> Bool {
    guard let error = error as? URLError else { return false }
    return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet,
            .dnsLookupFailed, .cannotFindHost, .resourceUnavailable].contains(error.code)
}

/// GET with retries: rate limiting (429), server errors (5xx) and transient network
/// failures are retried up to `attempts` times, waiting for the server's Retry-After
/// when given, else 1s, 2s, 4s… (at most 10s).
private nonisolated func fetchData(_ urlString: String, session: URLSession = .shared,
                                   timeout: TimeInterval = 8, attempts: Int = 3) async throws -> Data {
    guard let url = URL(string: urlString) else { throw ClientError.badResponse(urlString) }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("KalshiBot/1.0", forHTTPHeaderField: "User-Agent")

    var attempt = 0
    while true {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch where isTransient(error) && attempt + 1 < attempts {
            attempt += 1
            try await Task.sleep(for: .seconds(min(Double(1 << (attempt - 1)), 10)))
            continue
        }
        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse(url.host() ?? urlString) }
        if (200..<300).contains(http.statusCode) { return data }

        let retryable = http.statusCode == 429 || (500..<600).contains(http.statusCode)
        attempt += 1
        guard retryable, attempt < attempts else {
            throw ClientError.httpStatus(http.statusCode, host: url.host() ?? "server", path: url.path())
        }
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
        try await Task.sleep(for: .seconds(min(retryAfter ?? Double(1 << (attempt - 1)), 10)))
    }
}

private nonisolated func double(_ any: Any?) -> Double? {
    if let s = any as? String { return Double(s) }
    if let n = any as? NSNumber { return n.doubleValue }
    return nil
}

// MARK: - Kalshi

/// One side of a fetched Kalshi order book: its best price, or `.empty` when the book was
/// read and that side had no resting orders (no quote, rather than an unknown one).
nonisolated enum OrderBookSide: Sendable, Equatable {
    case empty
    case best(Double)

    var price: Double? {
        if case .best(let price) = self { return price }
        return nil
    }
}

/// A KXBTC15M market ("BTC price up in next 15 mins?").
nonisolated struct KalshiMarket: Codable, Sendable, Equatable {
    let ticker: String
    let status: String
    let openTime: Date
    let closeTime: Date
    /// Official 60s BRTI average before the open — the target price. Until Kalshi
    /// publishes it, the bot fills in its own estimate and sets `strikeIsEstimate`.
    var floorStrike: Double?
    /// `true` while `floorStrike` is the bot's own 60s average, not Kalshi's official value.
    var strikeIsEstimate = false
    /// Best Yes bid/ask from the live order book (nil = no book read yet). The market
    /// endpoint's own quotes are cached for ~11 seconds; the order book updates every
    /// second. Once the book has been read, an empty side means no quote: the cached
    /// endpoint quote may already be gone, so it's used only before the first book.
    var liveYesBid: OrderBookSide?
    var liveYesAsk: OrderBookSide?
    let yesBidDollars: String?
    let yesAskDollars: String?
    /// Official 60s BRTI average before the close, once known.
    let expirationValue: String?
    /// "yes", "no", or empty while unsettled.
    let result: String?

    enum CodingKeys: String, CodingKey {
        case ticker, status, result
        case openTime = "open_time"
        case closeTime = "close_time"
        case floorStrike = "floor_strike"
        case yesBidDollars = "yes_bid_dollars"
        case yesAskDollars = "yes_ask_dollars"
        case expirationValue = "expiration_value"
    }

    var yesBid: Double? { liveYesBid.map(\.price) ?? yesBidDollars.flatMap(Double.init) }
    var yesAsk: Double? { liveYesAsk.map(\.price) ?? yesAskDollars.flatMap(Double.init) }

    var yesMid: Double? {
        guard let bid = yesBid, let ask = yesAsk, ask > 0, ask >= bid else { return nil }
        return (bid + ask) / 2
    }

    var settlementValue: Double? { expirationValue.flatMap(Double.init) }

    /// `true` = settled Up (Yes), `false` = Down (No), `nil` = not yet settled.
    var settledUp: Bool? {
        switch result?.lowercased() {
        case "yes": true
        case "no": false
        default: nil
        }
    }
}

nonisolated struct KalshiClient: Sendable {
    static let seriesTicker = "KXBTC15M"
    private let base = "https://api.elections.kalshi.com/trade-api/v2"

    private struct MarketsResponse: Decodable {
        let markets: [KalshiMarket]
        let cursor: String?
    }
    private struct MarketResponse: Decodable { let market: KalshiMarket }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Every settled window that closed after `date`, following pagination.
    func settledMarkets(closedAfter date: Date) async throws -> [KalshiMarket] {
        var all: [KalshiMarket] = []
        var cursor = ""
        var seen = Set<String>()
        repeat {
            let url = marketsURL(["series_ticker": Self.seriesTicker, "status": "settled", "limit": "200",
                                  "min_close_ts": String(Int(date.timeIntervalSince1970)), "cursor": cursor])
            // History pages: five tries each, so one slow moment doesn't abandon the rebuild.
            let page = try decoder.decode(MarketsResponse.self, from: try await fetchData(url, attempts: 5))
            all += page.markets
            cursor = Self.nextCursor(page.cursor, pageEmpty: page.markets.isEmpty, seen: &seen) ?? ""
            // ~30 pages for 60 days; pace them so live polling keeps its share of the rate limit.
            if !cursor.isEmpty { try await Task.sleep(for: .milliseconds(150)) }
        } while !cursor.isEmpty
        return all
    }

    /// The cursor to fetch next, or nil when pagination is done: an empty page, no cursor,
    /// or a cursor already followed (which would otherwise loop forever).
    static func nextCursor(_ cursor: String?, pageEmpty: Bool, seen: inout Set<String>) -> String? {
        guard !pageEmpty, let cursor, !cursor.isEmpty, seen.insert(cursor).inserted else { return nil }
        return cursor
    }

    /// A markets-list URL with each value percent-encoded (empty values left out). Cursors
    /// are opaque and may hold `+`, `/` or `=`, which a raw query would misread.
    private func marketsURL(_ query: KeyValuePairs<String, String>) -> String {
        Self.url("\(base)/markets", query: query)
    }

    static func url(_ path: String, query: KeyValuePairs<String, String>) -> String {
        let items = query.filter { !$0.value.isEmpty }.map { "\($0.key)=\(queryEscaped($0.value))" }
        return items.isEmpty ? path : path + "?" + items.joined(separator: "&")
    }

    /// Percent-encodes a query value, including the `+ & = / ?` URLQueryItem would leave as is.
    static func queryEscaped(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=/?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private struct CandlestickBatch: Decodable {
        struct Market: Decodable {
            let marketTicker: String
            let candlesticks: [Candlestick]
            enum CodingKeys: String, CodingKey {
                case marketTicker = "market_ticker"
                case candlesticks
            }
        }
        struct Candlestick: Decodable {
            struct Quote: Decodable {
                let closeDollars: String?
                enum CodingKeys: String, CodingKey { case closeDollars = "close_dollars" }
            }
            let endPeriodTs: Int
            /// Optional: a candle missing either quote is skipped, not the whole batch.
            let yesBid: Quote?
            let yesAsk: Quote?
            enum CodingKeys: String, CodingKey {
                case endPeriodTs = "end_period_ts"
                case yesBid = "yes_bid"
                case yesAsk = "yes_ask"
            }
        }
        let markets: [Market]
    }

    private static func decodeCandlesticks(_ data: Data) throws -> CandlestickBatch {
        try JSONDecoder().decode(CandlestickBatch.self, from: data)
    }

    /// Kalshi's Yes mid at `offset` seconds after each market opened, from a candlesticks
    /// response (the parsing half of `yesMids`, separate so it can be tested offline).
    static func yesMids(fromCandlesticks data: Data, opens: [String: Int], offsets: [TimeInterval]) throws
        -> [TimeInterval: [String: Double]] {
        mids(from: try decodeCandlesticks(data), opens: opens, offsets: offsets)
    }

    private static func mids(from response: CandlestickBatch, opens: [String: Int], offsets: [TimeInterval])
        -> [TimeInterval: [String: Double]] {
        var mids: [TimeInterval: [String: Double]] = [:]
        for market in response.markets {
            guard let open = opens[market.marketTicker] else { continue }
            for offset in offsets {
                guard let candle = market.candlesticks.first(where: { $0.endPeriodTs == open + Int(offset) }),
                      let bid = candle.yesBid?.closeDollars.flatMap(Double.init),
                      let ask = candle.yesAsk?.closeDollars.flatMap(Double.init),
                      bid > 0, ask < 1, ask >= bid else { continue }
                mids[offset, default: [:]][market.marketTicker] = (bid + ask) / 2
            }
        }
        return mids
    }

    /// Kalshi's Yes mid `offsets` seconds after each market opened (offsets must be
    /// whole minutes), read from the close of the 1-minute candle ending then.
    /// Fetched in batches; Kalshi caps a request at 10,000 candles (markets × minutes).
    /// Each batch is retried with backoff; a batch that still fails is skipped (its
    /// windows are retried on the next catch-up) rather than failing the whole fetch.
    /// `checked` lists the windows whose batch succeeded, with or without odds.
    func yesMids(_ markets: [KalshiMarket], at offsets: [TimeInterval])
        async -> (mids: [TimeInterval: [String: Double]], checked: Set<String>, failedBatches: Int, lastError: Error?) {
        let sorted = markets.sorted { $0.openTime < $1.openTime }
        let latestOffset = Int((offsets.max() ?? 60) / 60)
        var mids: [TimeInterval: [String: Double]] = [:]
        var checked = Set<String>()
        var failedBatches = 0
        var lastError: Error?
        var index = 0
        while index < sorted.count {
            // Grow the batch while markets × span stays under the cap.
            var end = index + 1
            while end < sorted.count {
                let span = Int(sorted[end].openTime.timeIntervalSince(sorted[index].openTime) / 60) + latestOffset + 2
                if (end - index + 1) * span > 9_000 { break }
                end += 1
            }
            let batch = Array(sorted[index..<end])
            let start = Int(batch[0].openTime.timeIntervalSince1970)
            let finish = Int(batch[batch.count - 1].openTime.timeIntervalSince1970) + latestOffset * 60
            let tickers = batch.map(\.ticker).joined(separator: ",")
            let url = "\(base)/markets/candlesticks?market_tickers=\(tickers)&start_ts=\(start)&end_ts=\(finish)&period_interval=1"
            index = end

            var response: CandlestickBatch?
            let attempts = 3
            for attempt in 0..<attempts {
                do {
                    // Batches run to a few MB, so allow longer than a normal request.
                    response = try Self.decodeCandlesticks(try await fetchData(url, timeout: 30))
                    break
                } catch {
                    lastError = error
                    // The same bytes would fail to decode again; and no wait after the last try.
                    if error is DecodingError || attempt + 1 == attempts { break }
                    try? await Task.sleep(for: .seconds(1 << attempt))
                }
            }
            guard let response else {
                failedBatches += 1
                continue
            }
            checked.formUnion(batch.map(\.ticker))

            let opens = Dictionary(uniqueKeysWithValues: batch.map { ($0.ticker, Int($0.openTime.timeIntervalSince1970)) })
            for (offset, byTicker) in Self.mids(from: response, opens: opens, offsets: offsets) {
                mids[offset, default: [:]].merge(byTicker) { _, new in new }
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return (mids, checked, failedBatches, lastError)
    }

    /// The ticker of the window closing at `close`, e.g. "KXBTC15M-26OCT272300-00" for
    /// 23:00 Eastern on Oct 27, 2026. Kalshi names windows by their Eastern close time,
    /// and creates them about a day ahead, so the next one can be fetched before it opens.
    static func ticker(closingAt close: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyMMMddHHmm"
        let minute = Calendar(identifier: .gregorian).dateComponents(in: formatter.timeZone, from: close).minute ?? 0
        return "\(seriesTicker)-\(formatter.string(from: close).uppercased())-\(String(format: "%02d", minute))"
    }

    /// Best Yes bid and ask from the order book (real-time). Kalshi lists resting bids
    /// for Yes and for No; buying Yes means hitting the best No bid, so ask = 1 − best No bid.
    func topOfBook(ticker: String) async throws -> (yesBid: OrderBookSide, yesAsk: OrderBookSide) {
        try Self.topOfBook(from: try await fetchData("\(base)/markets/\(ticker)/orderbook?depth=1"))
    }

    /// Parses an order-book response. A side with no resting orders is `.empty` (Kalshi
    /// leaves it out or sends null), so the caller doesn't fall back to a stale quote.
    static func topOfBook(from data: Data) throws -> (yesBid: OrderBookSide, yesAsk: OrderBookSide) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let book = (json["orderbook_fp"] ?? json["orderbook"]) as? [String: Any] else {
            throw ClientError.badResponse("Kalshi order book")
        }
        func bestBid(_ side: String) -> Double? {
            (book[side] as? [[Any]])?.compactMap { ($0.first as? String).flatMap(Double.init) }.max()
        }
        return (bestBid("yes_dollars").map(OrderBookSide.best) ?? .empty,
                bestBid("no_dollars").map { OrderBookSide.best(1 - $0) } ?? .empty)
    }

    func market(ticker: String) async throws -> KalshiMarket {
        let data = try await fetchData("\(base)/markets/\(ticker)")
        return try decoder.decode(MarketResponse.self, from: data).market
    }

    /// The window closing at `close`, checked against its close time. Tickers are Eastern
    /// wall-clock times, so in the repeated 1–2 AM hour when clocks fall back two closes share
    /// one; if the ticker's market closes at another time, the series' markets closing within
    /// a minute of `close` are listed instead. Nil if none matches.
    func market(closingAt close: Date) async throws -> KalshiMarket? {
        if let market = try? await market(ticker: Self.ticker(closingAt: close)),
           Self.matching([market], closingAt: close) != nil {
            return market
        }
        let at = Int(close.timeIntervalSince1970)
        let url = marketsURL(["series_ticker": Self.seriesTicker, "limit": "20",
                              "min_close_ts": String(at - 60), "max_close_ts": String(at + 60)])
        let page = try decoder.decode(MarketsResponse.self, from: try await fetchData(url))
        return Self.matching(page.markets, closingAt: close)
    }

    /// The market whose close time is within a minute of `close` (the nearest, if several).
    static func matching(_ markets: [KalshiMarket], closingAt close: Date) -> KalshiMarket? {
        markets.filter { abs($0.closeTime.timeIntervalSince(close)) <= 60 }
            .min { abs($0.closeTime.timeIntervalSince(close)) < abs($1.closeTime.timeIntervalSince(close)) }
    }
}

// MARK: - Coinbase (candles)

nonisolated struct CoinbaseClient: Sendable {
    private let base = "https://api.exchange.coinbase.com/products/BTC-USD"

    /// Last ~300 one-minute candles, oldest → newest.
    func oneMinuteCandles() async throws -> [Candle] {
        try await oneMinuteCandles(query: "")
    }

    /// Historical 1-minute candles covering `start…end`, oldest → newest.
    /// Coinbase returns at most 300 bars per request, so the range is fetched in chunks.
    func oneMinuteCandles(from start: Date, to end: Date) async throws -> [Candle] {
        let chunk: TimeInterval = 300 * 60
        var candles: [Candle] = []
        var chunkStart = start
        let iso = ISO8601DateFormatter()
        while chunkStart < end {
            let chunkEnd = min(chunkStart.addingTimeInterval(chunk - 60), end)
            candles += try await oneMinuteCandles(query: "&start=\(iso.string(from: chunkStart))&end=\(iso.string(from: chunkEnd))",
                                                  attempts: 5)
            chunkStart = chunkEnd.addingTimeInterval(60)
            // Stay well under Coinbase's public rate limit.
            try await Task.sleep(for: .milliseconds(150))
        }
        // Chunks can overlap at the edges; de-duplicate by bar time.
        var seen = Set<Date>()
        return candles.sorted { $0.time < $1.time }.filter { seen.insert($0.time).inserted }
    }

    private func oneMinuteCandles(query: String, attempts: Int = 3) async throws -> [Candle] {
        let data = try await fetchData("\(base)/candles?granularity=60\(query)", attempts: attempts)
        // Rows are [time, low, high, open, close, volume], newest first.
        let rows = try JSONDecoder().decode([[Double]].self, from: data)
        return rows.compactMap { r in
            guard r.count >= 6 else { return nil }
            return Candle(time: Date(timeIntervalSince1970: r[0]), open: r[3], high: r[2], low: r[1], close: r[4], volume: r[5])
        }
        .sorted { $0.time < $1.time }
    }
}

// MARK: - Composite spot (BRTI proxy)

/// CF Benchmarks' BRTI isn't publicly streamed, so we approximate it with the
/// median mid-price across several of its constituent exchanges.
nonisolated struct CompositePriceClient: Sendable {
    /// US-reachable BTC spot books priced in dollars (or USDC), checked Oct 31 and Nov 2
    /// to quote within ~$40 of each other with tight spreads. OKX and KuCoin (USDC) sit
    /// ~$30 above the dollar books; their per-exchange BRTI offsets remove that. Excluded:
    /// Paxos/itBit, LMAX and Bullish (not reachable from the US), Bybit (blocks the US),
    /// Bitfinex (~$150 premium), USDT books (Tether basis), Gemini's USDC book (the same
    /// book as its USD one), and Uphold, Cex.io, Bitso, bitFlyer and Bitstamp's USDC book
    /// (spreads of $14–$200, or stale).
    enum Exchange: String, CaseIterable, Sendable {
        case coinbase, kraken, bitstamp, gemini, cryptocom, binanceUS, deribitUSDC, krakenUSDC, okxUSDC, kucoinUSDC

        var title: String {
            switch self {
            case .coinbase: "Coinbase"
            case .kraken: "Kraken"
            case .bitstamp: "Bitstamp"
            case .gemini: "Gemini"
            case .cryptocom: "Crypto.com"
            case .binanceUS: "Binance.US"
            case .deribitUSDC: "Deribit (USDC)"
            case .krakenUSDC: "Kraken (USDC)"
            case .okxUSDC: "OKX (USDC)"
            case .kucoinUSDC: "KuCoin (USDC)"
            }
        }

        var url: String {
            switch self {
            case .coinbase: "https://api.exchange.coinbase.com/products/BTC-USD/ticker"
            case .kraken: "https://api.kraken.com/0/public/Ticker?pair=XBTUSD"
            case .bitstamp: "https://www.bitstamp.net/api/v2/ticker/btcusd/"
            case .gemini: "https://api.gemini.com/v1/pubticker/btcusd"
            case .cryptocom: "https://api.crypto.com/exchange/v1/public/get-tickers?instrument_name=BTC_USD"
            case .binanceUS: "https://api.binance.us/api/v3/ticker/bookTicker?symbol=BTCUSD"
            case .deribitUSDC: "https://www.deribit.com/api/v2/public/ticker?instrument_name=BTC_USDC"
            case .krakenUSDC: "https://api.kraken.com/0/public/Ticker?pair=XBTUSDC"
            case .okxUSDC: "https://www.okx.com/api/v5/market/ticker?instId=BTC-USDC"
            case .kucoinUSDC: "https://api.kucoin.com/api/v1/market/orderbook/level1?symbol=BTC-USDC"
            }
        }

        /// Seconds between polls when this book isn't streamed (Kraken's public REST
        /// limit is about one call a second per IP, shared by both of its books).
        var pollInterval: TimeInterval { self == .krakenUSDC ? 2 : 1 }

        func quote(from data: Data) -> (bid: Double, ask: Double)? {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let bid: Double?, ask: Double?
            switch self {
            case .kraken, .krakenUSDC:
                let pair = (json["result"] as? [String: Any])?.values.first as? [String: Any]
                bid = double((pair?["b"] as? [Any])?.first)
                ask = double((pair?["a"] as? [Any])?.first)
            case .coinbase, .bitstamp, .gemini:
                bid = double(json["bid"])
                ask = double(json["ask"])
            case .cryptocom:
                let entry = ((json["result"] as? [String: Any])?["data"] as? [[String: Any]])?.first
                bid = double(entry?["b"])
                ask = double(entry?["k"])
            case .binanceUS:
                bid = double(json["bidPrice"])
                ask = double(json["askPrice"])
            case .deribitUSDC:
                let result = json["result"] as? [String: Any]
                bid = double(result?["best_bid_price"])
                ask = double(result?["best_ask_price"])
            case .okxUSDC:
                let entry = (json["data"] as? [[String: Any]])?.first
                bid = double(entry?["bidPx"])
                ask = double(entry?["askPx"])
            case .kucoinUSDC:
                let entry = json["data"] as? [String: Any]
                bid = double(entry?["bestBid"])
                ask = double(entry?["bestAsk"])
            }
            guard let bid, let ask, bid > 0, ask >= bid else { return nil }
            return (bid, ask)
        }

        func mid(from data: Data) -> Double? {
            quote(from: data).map { ($0.bid + $0.ask) / 2 }
        }
    }

    /// One exchange's current best bid and ask over REST (no retries: the caller polls).
    static func fetchQuote(_ exchange: Exchange, session: URLSession = .shared) async -> (bid: Double, ask: Double)? {
        guard let url = URL(string: exchange.url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return exchange.quote(from: data)
    }

    /// No response cache: a cached ticker would look like a live quote that never moves.
    /// Shared by the live feed's polls and streams and by the REST fallback.
    static let uncachedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Outlier-trimmed mean of whichever exchanges answered; `nil` if none did. One uncached
    /// try each with a 3s timeout, so the fallback answers quickly with prices that are live.
    func compositeMid() async -> (price: Double, sources: Int)? {
        let mids = await withTaskGroup(of: Double?.self) { group in
            for exchange in Exchange.allCases {
                group.addTask {
                    await Self.fetchQuote(exchange, session: Self.uncachedSession).map { ($0.bid + $0.ask) / 2 }
                }
            }
            var values: [Double] = []
            for await mid in group { if let mid { values.append(mid) } }
            return values.sorted()
        }
        // Same construction as the live streams, so the price doesn't change character on fallback.
        return LivePriceFeed.trimmedMean(mids)
    }
}
