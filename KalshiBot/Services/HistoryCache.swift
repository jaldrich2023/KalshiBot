//
//  HistoryCache.swift
//  KalshiBot
//
//  The public market history the model is rebuilt from — Kalshi's settled windows and
//  their odds, and Coinbase 1-minute candles — saved on disk, so a restart, a reset or
//  a call-time change only downloads what's new instead of 180 days again.
//

import Foundation

nonisolated struct HistoryCache: Sendable, Equatable {
    /// Settled KXBTC15M windows, by ticker.
    var markets: [String: KalshiMarket] = [:]
    /// Kalshi Yes mid at each call-time offset (seconds after the open), by ticker.
    var mids: [String: [Int: Double]] = [:]
    /// Windows whose odds were fetched successfully, with or without a quote. Windows
    /// not in here are fetched again on the next rebuild.
    var oddsChecked: Set<String> = []
    /// Coinbase 1-minute candles, oldest → newest, de-duplicated by time.
    var candles: [Candle] = []

    /// Bump when the stored format changes; an older file is ignored and rebuilt.
    static let version = 1

    static var fileURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("MarketHistory.v\(version).json")
    }

    // MARK: Updating

    /// Adds or replaces windows by ticker.
    mutating func merge(markets fresh: [KalshiMarket]) {
        for market in fresh { markets[market.ticker] = market }
    }

    /// Adds candles, keeping them sorted with one per minute.
    mutating func merge(candles fresh: [Candle]) {
        guard !fresh.isEmpty else { return }
        var byTime = Dictionary(candles.map { ($0.time, $0) }, uniquingKeysWith: { first, _ in first })
        for candle in fresh { byTime[candle.time] = candle }
        candles = byTime.values.sorted { $0.time < $1.time }
    }

    mutating func merge(mids fresh: [TimeInterval: [String: Double]], checked: Set<String>) {
        for (offset, byTicker) in fresh {
            for (ticker, mid) in byTicker { mids[ticker, default: [:]][Int(offset)] = mid }
        }
        oddsChecked.formUnion(checked)
    }

    /// Drops everything older than `date`, so the file stays at the history window's size.
    mutating func prune(before date: Date) {
        let old = Set(markets.values.filter { $0.openTime < date }.map(\.ticker))
        for ticker in old {
            markets[ticker] = nil
            mids[ticker] = nil
        }
        oddsChecked.subtract(old)
        // Features look back 160 minutes before a window's open.
        let candleStart = date.addingTimeInterval(-3 * 3600)
        candles.removeAll { $0.time < candleStart }
    }

    /// Ranges inside `start…end` that the cached candles don't cover: before the first
    /// cached candle and after the last. Gaps inside are Coinbase's own (no trades).
    func missingCandleRanges(from start: Date, to end: Date) -> [(start: Date, end: Date)] {
        guard let first = candles.first?.time, let last = candles.last?.time, first <= end, last >= start else {
            return start < end ? [(start, end)] : []
        }
        var ranges: [(start: Date, end: Date)] = []
        if start < first { ranges.append((start, first.addingTimeInterval(-60))) }
        if end > last { ranges.append((last.addingTimeInterval(60), end)) }
        return ranges.filter { $0.start <= $0.end }
    }

    /// Odds for every cached window at `offset` seconds after the open.
    func mids(at offset: TimeInterval) -> [String: Double] {
        mids.compactMapValues { $0[Int(offset)] }
    }

    // MARK: Storage

    private struct Stored: Codable {
        var version: Int
        var markets: [KalshiMarket]
        var mids: [String: [String: Double]]
        var oddsChecked: [String]
        /// Candles packed as [time, open, high, low, close, volume, …] — far smaller and
        /// faster than one JSON object per candle.
        var candles: Data
    }

    /// The saved cache, or an empty one if there's none or it can't be read.
    static func load(from url: URL = fileURL) -> HistoryCache {
        guard let data = try? Data(contentsOf: url),
              let stored = try? decoder.decode(Stored.self, from: data),
              stored.version == version else { return HistoryCache() }
        var cache = HistoryCache()
        cache.markets = Dictionary(stored.markets.map { ($0.ticker, $0) }, uniquingKeysWith: { first, _ in first })
        cache.mids = stored.mids.mapValues { byOffset in
            Dictionary(byOffset.compactMap { key, value in Int(key).map { ($0, value) } }, uniquingKeysWith: { first, _ in first })
        }
        cache.oddsChecked = Set(stored.oddsChecked)
        cache.candles = unpack(stored.candles)
        return cache
    }

    /// Writes the cache atomically; a failed write just means a longer download next time.
    func save(to url: URL = fileURL) {
        let stored = Stored(version: Self.version,
                            markets: markets.values.sorted { $0.openTime < $1.openTime },
                            mids: mids.mapValues { Dictionary(uniqueKeysWithValues: $0.map { (String($0.key), $0.value) }) },
                            oddsChecked: oddsChecked.sorted(),
                            candles: Self.pack(candles))
        guard let data = try? Self.encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func pack(_ candles: [Candle]) -> Data {
        var values: [Double] = []
        values.reserveCapacity(candles.count * 6)
        for c in candles { values += [c.time.timeIntervalSince1970, c.open, c.high, c.low, c.close, c.volume] }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func unpack(_ data: Data) -> [Candle] {
        let values: [Double] = data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
        return stride(from: 0, to: values.count - 5, by: 6).map { i in
            Candle(time: Date(timeIntervalSince1970: values[i]), open: values[i + 1], high: values[i + 2],
                   low: values[i + 3], close: values[i + 4], volume: values[i + 5])
        }
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
