//
//  LivePriceFeed.swift
//  KalshiBot
//
//  Real-time top-of-book from ten US-reachable BTC/USD(C) books: Coinbase, Kraken and
//  Bitstamp stream over WebSockets; the rest are polled every second or two. The
//  composite tracks the market to the second instead of lagging minute-old data.
//

import Foundation

/// One source's latest price and its part in the composite.
nonisolated struct SourceStatus: Sendable, Identifiable, Equatable {
    enum State: Sendable, Equatable {
        /// Averaged into the composite.
        case used
        /// In line with the others but the highest or lowest, so left out of the average.
        case trimmed
        /// Too far from the other books to trust.
        case outlier
        /// No fresh quote in the last few seconds.
        case stale
        /// Not connected or no quote yet.
        case waiting
    }
    let source: CompositePriceClient.Exchange
    /// The exchange's own mid, before its offset.
    let mid: Double?
    let state: State
    /// Dollars added to this exchange's mid so it tracks the official BRTI (0 until measured).
    var offset: Double = 0
    /// When the source entered its current state.
    var since: Date?
    /// Times its stream was reconnected since the bot started (streamed sources only).
    var reconnects = 0
    /// Its share of the composite (0 when not used).
    var weight: Double = 0
    var id: String { source.rawValue }

    /// The mid as it enters the composite.
    var corrected: Double? { mid.map { $0 + offset } }
}

/// Latest best bid/ask mid per exchange, pushed by each exchange as it changes.
actor LivePriceFeed {

    /// Gemini isn't streamed: its top-of-book feed only reports changes on one side at a
    /// time, and the quote rebuilt from it ran ~$20 off the other exchanges. Its REST
    /// ticker (used by the polling fallback) is accurate.
    enum Exchange: String, CaseIterable, Sendable {
        case coinbase, kraken, bitstamp

        var url: URL {
            switch self {
            case .coinbase: URL(string: "wss://ws-feed.exchange.coinbase.com")!
            case .kraken: URL(string: "wss://ws.kraken.com/v2")!
            case .bitstamp: URL(string: "wss://ws.bitstamp.net")!
            }
        }

        /// Message sent right after connecting, if the exchange needs one.
        var subscription: String? {
            switch self {
            case .coinbase: #"{"type":"subscribe","product_ids":["BTC-USD"],"channels":["ticker"]}"#
            // bbo: push on every best bid/offer change, not only on trades.
            case .kraken: #"{"method":"subscribe","params":{"channel":"ticker","symbol":["BTC/USD"],"event_trigger":"bbo"}}"#
            case .bitstamp: #"{"event":"bts:subscribe","data":{"channel":"order_book_btcusd"}}"#
            }
        }
    }

    private struct Quote {
        var bid: Double?
        var ask: Double?
        var updated: Date
    }

    /// A quote older than this is treated as stale and left out of the composite.
    /// Coinbase's ticker only updates on trades, so a quiet few seconds is normal; a
    /// dropped connection removes the quote immediately instead.
    static let maxQuoteAge: TimeInterval = 10

    /// Every source, streamed or polled, by `CompositePriceClient.Exchange` raw value.
    private var quotes: [String: Quote] = [:]
    /// Per-exchange corrections toward the official BRTI, set by the engine.
    private var offsets: [String: Double] = [:]
    /// Relative weights by how steadily each exchange tracks the official BRTI (see
    /// `BotEngine.trackingWeights`); empty = equal weights.
    private var trackingWeights: [String: Double] = [:]
    /// Each source's current state and when it began, for "stale for 2 min".
    private var stateSince: [String: (state: SourceStatus.State, since: Date)] = [:]
    private var reconnects: [String: Int] = [:]
    /// Last message of any kind on each stream, so a silent socket can be replaced.
    private var lastMessage: [String: Date] = [:]
    /// A stream with no message for this long is assumed dead and reconnected. Each
    /// streamed book updates several times a second in normal trading.
    static let silentLimit: TimeInterval = 30
    /// Messages that changed each exchange's quote, for diagnosing a quiet feed.
    private(set) var updateCounts: [String: Int] = [:]
    private(set) var messageCounts: [String: Int] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    /// No response cache: a cached ticker would look like a live quote that never moves.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Sources polled over REST because they aren't streamed.
    static let polled = CompositePriceClient.Exchange.allCases.filter { Exchange(rawValue: $0.rawValue) == nil }
    /// All sources the composite draws on.
    static var sourceCount: Int { CompositePriceClient.Exchange.allCases.count }

    func start() {
        for exchange in Exchange.allCases where tasks[exchange.rawValue] == nil {
            tasks[exchange.rawValue] = Task { await self.run(exchange) }
        }
        for source in Self.polled where tasks[source.rawValue] == nil {
            tasks[source.rawValue] = Task { await self.poll(source) }
        }
    }

    /// Polls one REST source on its interval; a failed poll leaves the old quote to age out.
    private func poll(_ source: CompositePriceClient.Exchange) async {
        while !Task.isCancelled {
            if let quote = await CompositePriceClient.fetchQuote(source, session: session) {
                messageCounts[source.rawValue, default: 0] += 1
                let previous = quotes[source.rawValue]
                if previous?.bid != quote.bid || previous?.ask != quote.ask {
                    updateCounts[source.rawValue, default: 0] += 1
                }
                quotes[source.rawValue] = Quote(bid: quote.bid, ask: quote.ask, updated: .now)
            }
            try? await Task.sleep(for: .seconds(source.pollInterval))
        }
    }

    func stop() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        quotes = [:]
        stateSince = [:]
    }

    /// Per-exchange corrections (by `CompositePriceClient.Exchange` raw value) applied
    /// before the quotes are combined.
    func setOffsets(_ offsets: [String: Double], weights: [String: Double] = [:]) {
        self.offsets = offsets
        self.trackingWeights = weights
    }

    /// Exchanges currently contributing a fresh quote.
    func liveExchanges(at date: Date = .now) -> [CompositePriceClient.Exchange] {
        CompositePriceClient.Exchange.allCases.filter { source in
            quotes[source.rawValue].map { date.timeIntervalSince($0.updated) <= Self.maxQuoteAge && $0.bid != nil && $0.ask != nil } ?? false
        }
    }

    /// Mid prices further than this from the median are treated as stale or off-market:
    /// 0.05% (~$39 at $78k). Healthy books sat up to ~$36 apart on Oct 31; a $12 band
    /// dropped good exchanges whenever they drifted apart. Off-market books (Bitfinex's
    /// ~$150 premium, a frozen quote) are far outside it.
    static func outlierBand(for median: Double) -> Double { max(25, median * 0.0005) }

    /// Mean mid of exchanges with a fresh, in-line quote; nil if none are fresh.
    ///
    /// Steps: drop quotes outside the band around the median, then — with five or
    /// more left — drop the highest and lowest too, and average the rest. That moves
    /// whenever any middle exchange moves, and no single book can drag it.
    func composite(at date: Date = .now) -> (price: Double, sources: Int)? {
        Self.combine(freshMids(at: date), weights: trackingWeights).composite
    }

    /// Each source's latest mid and whether it's in the composite right now.
    func statuses(at date: Date = .now) -> [SourceStatus] {
        let combined = Self.combine(freshMids(at: date), weights: trackingWeights)
        let states = combined.states
        return CompositePriceClient.Exchange.allCases.map { source in
            let id = source.rawValue
            let quote = quotes[id]
            let mid = quote.flatMap { q in q.bid.flatMap { b in q.ask.map { (b + $0) / 2 } } }
            let state: SourceStatus.State = states[id] ?? (mid == nil ? .waiting : .stale)
            if stateSince[id]?.state != state { stateSince[id] = (state, date) }
            return SourceStatus(source: source, mid: mid, state: state, offset: offsets[id] ?? 0,
                                since: stateSince[id]?.since, reconnects: reconnects[id] ?? 0,
                                weight: combined.shares[id] ?? 0)
        }
    }

    /// Fresh mids with each exchange's offset applied.
    private func freshMids(at date: Date) -> [(id: String, mid: Double)] {
        quotes.compactMap { id, quote in
            guard date.timeIntervalSince(quote.updated) <= Self.maxQuoteAge,
                  let bid = quote.bid, let ask = quote.ask, bid > 0, ask >= bid else { return nil }
            return (id, (bid + ask) / 2 + (offsets[id] ?? 0))
        }
    }

    static func trimmedMean(_ mids: [Double]) -> (price: Double, sources: Int)? {
        combine(mids.enumerated().map { (id: String($0.offset), mid: $0.element) }).composite
    }

    /// The composite and each source's part in it. Drops mids outside the band around
    /// the median; with five or more left, also leaves the highest and lowest out of the
    /// average; averages the rest.
    /// No single exchange carries more than this share of the composite.
    static let maxShare = 0.25

    /// Shares for the used sources from their relative weights (missing = the median
    /// weight), capped at `maxShare` with the excess spread over the rest.
    static func shares(for ids: [String], weights: [String: Double]) -> [String: Double] {
        guard !ids.isEmpty else { return [:] }
        let known = ids.compactMap { weights[$0] }.sorted()
        let typical = known.isEmpty ? 1 : known[known.count / 2]
        var raw = Dictionary(uniqueKeysWithValues: ids.map { ($0, max(weights[$0] ?? typical, 0)) })
        if raw.values.reduce(0, +) <= 0 { raw = raw.mapValues { _ in 1 } }
        // A cap below an equal share can't be met; fall back to equal shares then.
        let cap = max(maxShare, 1 / Double(ids.count))
        var capped: [String: Double] = [:]
        for _ in 0..<ids.count {
            let free = raw.filter { capped[$0.key] == nil }
            let remaining = 1 - capped.values.reduce(0, +)
            let total = free.values.reduce(0, +)
            guard total > 0 else { break }
            let over = free.filter { $0.value / total * remaining > cap }
            if over.isEmpty {
                for (id, w) in free { capped[id] = w / total * remaining }
                break
            }
            for id in over.keys { capped[id] = cap }
        }
        return capped
    }

    static func combine(_ mids: [(id: String, mid: Double)], weights: [String: Double] = [:])
        -> (composite: (price: Double, sources: Int)?, states: [String: SourceStatus.State], shares: [String: Double]) {
        let sorted = mids.sorted { $0.mid < $1.mid }
        guard !sorted.isEmpty else { return (nil, [:], [:]) }
        let n = sorted.count
        let median = n % 2 == 1 ? sorted[n / 2].mid : (sorted[n / 2 - 1].mid + sorted[n / 2].mid) / 2
        let band = outlierBand(for: median)
        let inLine = sorted.filter { abs($0.mid - median) <= band }
        var states: [String: SourceStatus.State] = [:]
        for entry in sorted { states[entry.id] = .outlier }
        // Two quotes further apart than twice the band both sit outside it around their
        // midpoint; with no way to tell which is off, use the median rather than
        // averaging nothing (0/0 = NaN, which crashed the charts).
        guard !inLine.isEmpty else { return ((median, n), states, [:]) }
        let core = inLine.count >= 5 ? Array(inLine.dropFirst().dropLast()) : inLine
        for entry in inLine { states[entry.id] = .trimmed }
        for entry in core { states[entry.id] = .used }
        // Weighted by tracking steadiness when known; equal otherwise.
        let shares = shares(for: core.map(\.id), weights: weights)
        let price = core.map { $0.mid * (shares[$0.id] ?? 0) }.reduce(0, +)
        // `sources` counts every in-line book, including the two trimmed extremes.
        return ((price, inLine.count), states, shares)
    }

    // MARK: Connection

    /// Keeps one exchange connected, reconnecting with backoff (1s, 2s, 4s… up to 30s).
    /// A watchdog also replaces a socket that stays open but goes silent, which would
    /// otherwise leave the source stale indefinitely.
    private func run(_ exchange: Exchange) async {
        var backoff: Double = 1
        var connections = 0
        while !Task.isCancelled {
            let socket = session.webSocketTask(with: exchange.url)
            socket.resume()
            connections += 1
            if connections > 1 { reconnects[exchange.rawValue, default: 0] += 1 }
            lastMessage[exchange.rawValue] = .now
            let watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard let self, !Task.isCancelled else { return }
                    if await self.isSilent(exchange) {
                        // Ends the pending receive with an error, so the loop reconnects.
                        socket.cancel(with: .goingAway, reason: nil)
                        return
                    }
                }
            }
            do {
                if let subscription = exchange.subscription {
                    try await socket.send(.string(subscription))
                }
                backoff = 1
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let text: String? = switch message {
                    case .string(let string): string
                    case .data(let data): String(data: data, encoding: .utf8)
                    @unknown default: nil
                    }
                    if let text { handle(text, from: exchange) }
                }
            } catch {
                // Dropped, refused or silenced by the watchdog; fall through to reconnect.
            }
            watchdog.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            quotes[exchange.rawValue] = nil
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 30)
        }
    }

    private func isSilent(_ exchange: Exchange, at date: Date = .now) -> Bool {
        lastMessage[exchange.rawValue].map { date.timeIntervalSince($0) > Self.silentLimit } ?? false
    }

    private func handle(_ text: String, from exchange: Exchange) {
        messageCounts[exchange.rawValue, default: 0] += 1
        lastMessage[exchange.rawValue] = .now
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let now = Date.now
        var quote = quotes[exchange.rawValue] ?? Quote(updated: now)

        switch exchange {
        case .coinbase:
            guard json["type"] as? String == "ticker" else { return }
            quote.bid = number(json["best_bid"])
            quote.ask = number(json["best_ask"])

        case .kraken:
            guard json["channel"] as? String == "ticker",
                  let entry = (json["data"] as? [[String: Any]])?.first else { return }
            quote.bid = number(entry["bid"])
            quote.ask = number(entry["ask"])

        case .bitstamp:
            guard json["event"] as? String == "data", let book = json["data"] as? [String: Any],
                  let bids = book["bids"] as? [[Any]], let asks = book["asks"] as? [[Any]] else { return }
            quote.bid = number(bids.first?.first)
            quote.ask = number(asks.first?.first)

        }
        quote.updated = now
        if quote.bid != quotes[exchange.rawValue]?.bid || quote.ask != quotes[exchange.rawValue]?.ask {
            updateCounts[exchange.rawValue, default: 0] += 1
        }
        quotes[exchange.rawValue] = quote
    }

    /// Per-exchange (messages, quote changes, current mid), for diagnostics.
    func diagnostics() -> [String] {
        CompositePriceClient.Exchange.allCases.map { source in
            let quote = quotes[source.rawValue]
            let mid = quote.flatMap { q in q.bid.flatMap { b in q.ask.map { (b + $0) / 2 } } }
            return "\(source.rawValue): \(messageCounts[source.rawValue] ?? 0) msgs, \(updateCounts[source.rawValue] ?? 0) quote changes, mid \(mid.map { String(format: "%.2f", $0) } ?? "–")"
        }
    }

    private func number(_ any: Any?) -> Double? {
        if let string = any as? String { return Double(string) }
        if let number = any as? NSNumber { return number.doubleValue }
        return nil
    }
}
