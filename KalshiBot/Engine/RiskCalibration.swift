//
//  RiskCalibration.swift
//  KalshiBot
//
//  Keeps the Reversal Risk card calibrated. From the saved market history it rebuilds
//  every window minute by minute (price, volatility, Kalshi's price, whether the
//  leading side went on to lose, whether the high or low broke), fits the flip and
//  breakout corrections on the older 80% of windows, and scores them on the newest
//  20%. A fitted correction is used only where it beats the fixed one on those
//  unseen windows. Runs after every history rebuild.
//

import Foundation

nonisolated struct RiskCalibration: Codable, Sendable, Equatable {

    /// Flip chance without Kalshi: logit p = a + b·logit(raw random-walk flip).
    var flip: [Double]?
    /// Flip chance with Kalshi's price: logit p = a + b·logit(raw) + c·logit(Kalshi's flip).
    var blend: [Double]?
    /// Breakout chance: logit p = a + b·logit(raw reflection-principle probability).
    var breakout: [Double]?
    /// Half-life, in minutes, of the volatility weighting (nil = the last hour, equally).
    var volatilityHalfLife: Double?
    /// Held-out scores (Brier, lower is better) on the newest 20% of windows.
    var evaluation: Evaluation
    var windows: Int
    var fittedAt: Date

    struct Evaluation: Codable, Sendable, Equatable {
        var snapshots = 0
        var fixedFlip = 0.0
        var fittedFlip = 0.0
        var kalshi = 0.0
        var blended = 0.0
        var fixedBreakout = 0.0
        var fittedBreakout = 0.0
    }

    /// Before any fit: the fixed corrections from the Oct 31 backtest.
    static let fixedBreakout = [-0.429, 0.656]

    // MARK: Applying

    /// Calibrated chance the leading side loses, from the random-walk flip and, when
    /// known, Kalshi's own price for the same outcome.
    func flipProbability(raw: Double, kalshiFlip: Double?) -> Double {
        let p: Double
        if let k = kalshiFlip, let w = blend {
            p = Self.sigmoid(w[0] + w[1] * Self.logit(raw) + w[2] * Self.logit(k))
        } else if let w = flip {
            p = Self.sigmoid(w[0] + w[1] * Self.logit(raw))
        } else {
            p = SettlementOdds.calibratedFlip(raw: raw)
        }
        return min(max(p, 0.001), 0.95)
    }

    func breakoutProbability(raw: Double) -> Double {
        let w = breakout ?? Self.fixedBreakout
        return Self.sigmoid(w[0] + w[1] * Self.logit(raw))
    }

    static func logit(_ p: Double) -> Double {
        let q = min(max(p, 1e-4), 1 - 1e-4)
        return log(q / (1 - q))
    }

    static func sigmoid(_ x: Double) -> Double { 1 / (1 + exp(-x)) }

    // MARK: Snapshots

    /// One window at one minute, rebuilt from history.
    struct Snapshot: Sendable {
        let openTime: Date
        /// Random-walk chance the leading side loses.
        let rawFlip: Double
        /// Kalshi's price for the leading side losing (1 − its price), when known.
        let kalshiFlip: Double?
        let leaderLost: Bool
        /// Raw breakout probabilities toward the window high and low, and whether each broke.
        let breakouts: [(raw: Double, happened: Bool)]
    }

    /// Dollars per √second from 1-minute closes, oldest → newest; equally weighted, or
    /// exponentially weighted with `halfLife` minutes. Nil without enough returns.
    static func volatility(closes: [Double], halfLife: Double?) -> Double? {
        let returns = Indicators.logReturns(closes)
        guard returns.count >= 30, let last = closes.last, last > 0 else { return nil }
        let variance: Double
        if let halfLife {
            let decay = pow(0.5, 1 / halfLife)
            var weight = 1.0, total = 0.0, sum = 0.0
            for r in returns.reversed() {
                sum += weight * r * r
                total += weight
                weight *= decay
            }
            variance = sum / total
        } else {
            let mean = returns.reduce(0, +) / Double(returns.count)
            variance = returns.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(returns.count - 1)
        }
        return variance.squareRoot() * last / 60.0.squareRoot()
    }

    /// Minute-by-minute snapshots of every settled window in the cache, for minutes +3
    /// to +12 (where Kalshi's odds are saved). Coinbase prices are shifted to the index by
    /// each window's own target, as the live composite is by its calibration.
    static func snapshots(from cache: HistoryCache, halfLife: Double?) -> [Snapshot] {
        let candles = Dictionary(cache.candles.map { ($0.time, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Snapshot] = []
        for market in cache.markets.values {
            guard let up = market.settledUp, let strike = market.floorStrike, strike > 0,
                  let before = candles[market.openTime.addingTimeInterval(-60)] else { continue }
            let offset = strike - (before.open + before.close) / 2
            let window = (0..<15).map { candles[market.openTime.addingTimeInterval(Double($0) * 60)] }
            let mids = cache.mids[market.ticker] ?? [:]
            for minute in 3...12 {
                guard let candle = window[minute - 1] else { continue }
                let history = (0...60).compactMap { candles[candle.time.addingTimeInterval(Double(-$0) * 60)]?.close }.reversed()
                guard history.count == 61, let vol = volatility(closes: Array(history), halfLife: halfLife), vol > 0 else { continue }
                let price = candle.close + offset
                let gap = price - strike
                guard gap != 0 else { continue }
                let remaining = 900 - Double(minute) * 60
                let sigma = vol * (max(remaining - 60, 0) + min(remaining, 60) / 3).squareRoot()
                let raw = Indicators.normalCDF(-abs(gap) / sigma)
                let leaderUp = gap > 0
                let kalshi = mids[minute * 60].map { leaderUp ? 1 - $0 : $0 }

                // Breakouts: the high and low so far versus the rest of the window.
                let sofar = window[0..<minute].compactMap { $0 }
                let rest = window[minute..<15].compactMap { $0 }
                var breakouts: [(raw: Double, happened: Bool)] = []
                if !sofar.isEmpty, rest.count == 15 - minute {
                    let high = sofar.map(\.high).max()! + offset, low = sofar.map(\.low).min()! + offset
                    let scale = vol * remaining.squareRoot()
                    if high > price {
                        breakouts.append((min(2 * Indicators.normalCDF(-(high - price) / scale), 1),
                                          rest.map(\.high).max()! + offset > high))
                    }
                    if low < price {
                        breakouts.append((min(2 * Indicators.normalCDF(-(price - low) / scale), 1),
                                          rest.map(\.low).min()! + offset < low))
                    }
                }
                result.append(Snapshot(openTime: market.openTime, rawFlip: raw, kalshiFlip: kalshi,
                                       leaderLost: up != leaderUp, breakouts: breakouts))
            }
        }
        return result.sorted { $0.openTime < $1.openTime }
    }

    // MARK: Fitting

    /// Logistic regression by Newton's method; rows are feature vectors (without the constant).
    static func fitLogistic(_ rows: [(x: [Double], y: Bool)]) -> [Double]? {
        guard let width = rows.first.map({ $0.x.count + 1 }), rows.count > 50 else { return nil }
        var w = [Double](repeating: 0, count: width)
        if width > 1 { w[1] = 1 }
        for _ in 0..<30 {
            var gradient = [Double](repeating: 0, count: width)
            var hessian = [[Double]](repeating: [Double](repeating: 0, count: width), count: width)
            for row in rows {
                let v = [1.0] + row.x
                let p = sigmoid(zip(w, v).map(*).reduce(0, +))
                let y = row.y ? 1.0 : 0
                for i in 0..<width {
                    gradient[i] += (y - p) * v[i]
                    for j in 0..<width { hessian[i][j] += p * (1 - p) * v[i] * v[j] }
                }
            }
            for i in 0..<width { hessian[i][i] += 1e-3 }
            guard let step = ModelTrainer.solve(hessian, gradient) else { return nil }
            w = zip(w, step).map(+)
            if step.map(abs).max() ?? 0 < 1e-7 { break }
        }
        return w.allSatisfy(\.isFinite) ? w : nil
    }

    static func brier(_ pairs: [(p: Double, y: Bool)]) -> Double {
        guard !pairs.isEmpty else { return .nan }
        return pairs.map { let y = $0.y ? 1.0 : 0; return ($0.p - y) * ($0.p - y) }.reduce(0, +) / Double(pairs.count)
    }

    /// Fits on the older 80% of windows, scores on the newest 20%, and keeps each fitted
    /// part only if it scored better there than the fixed one (or, for the blend, better
    /// than both Kalshi's price alone and the price-only flip).
    static func fit(_ snapshots: [Snapshot], halfLife: Double?, now: Date = .now) -> RiskCalibration? {
        let opens = Array(Set(snapshots.map(\.openTime))).sorted()
        guard opens.count >= 1000 else { return nil }
        let cutoff = opens[opens.count * 4 / 5]
        let train = snapshots.filter { $0.openTime < cutoff }, test = snapshots.filter { $0.openTime >= cutoff }

        let flipRows = train.map { (x: [logit($0.rawFlip)], y: $0.leaderLost) }
        let blendTrain = train.filter { $0.kalshiFlip != nil }
        let blendRows = blendTrain.map { (x: [logit($0.rawFlip), logit($0.kalshiFlip!)], y: $0.leaderLost) }
        let breakoutRows = train.flatMap { s in s.breakouts.map { (x: [logit($0.raw)], y: $0.happened) } }
        let flipFit = fitLogistic(flipRows), blendFit = fitLogistic(blendRows), breakoutFit = fitLogistic(breakoutRows)

        var e = Evaluation(snapshots: test.count)
        e.fixedFlip = brier(test.map { (SettlementOdds.calibratedFlip(raw: $0.rawFlip), $0.leaderLost) })
        if let w = flipFit {
            e.fittedFlip = brier(test.map { (sigmoid(w[0] + w[1] * logit($0.rawFlip)), $0.leaderLost) })
        }
        let withKalshi = test.filter { $0.kalshiFlip != nil }
        e.kalshi = brier(withKalshi.map { ($0.kalshiFlip!, $0.leaderLost) })
        if let w = blendFit {
            e.blended = brier(withKalshi.map { (sigmoid(w[0] + w[1] * logit($0.rawFlip) + w[2] * logit($0.kalshiFlip!)), $0.leaderLost) })
        }
        let breakoutTest = test.flatMap(\.breakouts)
        e.fixedBreakout = brier(breakoutTest.map { (sigmoid(fixedBreakout[0] + fixedBreakout[1] * logit($0.raw)), $0.happened) })
        if let w = breakoutFit {
            e.fittedBreakout = brier(breakoutTest.map { (sigmoid(w[0] + w[1] * logit($0.raw)), $0.happened) })
        }

        // Adopted parts are refitted on every window for the live card.
        let allFlip = snapshots.map { (x: [logit($0.rawFlip)], y: $0.leaderLost) }
        let allBlend = snapshots.filter { $0.kalshiFlip != nil }.map { (x: [logit($0.rawFlip), logit($0.kalshiFlip!)], y: $0.leaderLost) }
        let allBreakout = snapshots.flatMap { s in s.breakouts.map { (x: [logit($0.raw)], y: $0.happened) } }
        let useFlip = flipFit != nil && e.fittedFlip < e.fixedFlip
        let useBlend = blendFit != nil && e.blended < min(e.kalshi, useFlip ? e.fittedFlip : e.fixedFlip)
        let useBreakout = breakoutFit != nil && e.fittedBreakout < e.fixedBreakout
        return RiskCalibration(flip: useFlip ? fitLogistic(allFlip) : nil,
                               blend: useBlend ? fitLogistic(allBlend) : nil,
                               breakout: useBreakout ? fitLogistic(allBreakout) : nil,
                               volatilityHalfLife: halfLife, evaluation: e, windows: opens.count, fittedAt: now)
    }

    /// Volatility weightings tried at each refit: the last hour equally, or a 30- or
    /// 15-minute half-life.
    static let halfLifeCandidates: [Double?] = [nil, 30, 15]

    /// Fits each volatility weighting and keeps the one whose flip chance scored best on
    /// the held-out windows.
    static func best(from cache: HistoryCache, now: Date = .now) -> RiskCalibration? {
        halfLifeCandidates
            .compactMap { fit(snapshots(from: cache, halfLife: $0), halfLife: $0, now: now) }
            .min { $0.score < $1.score }
    }

    /// The flip score the live card will actually get with this calibration.
    var score: Double {
        if blend != nil { return evaluation.blended }
        return flip != nil ? evaluation.fittedFlip : evaluation.fixedFlip
    }
}

/// The Reversal Risk card's flip chance, logged once a minute and scored when the window
/// settles, so its live calibration can be checked.
nonisolated struct RiskLog: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        let ticker: String
        let time: Date
        /// The card's chance that the side leading at `time` loses.
        let flip: Double
        let leaderUp: Bool
        /// Set when the window settles.
        var leaderLost: Bool?
    }

    var entries: [Entry] = []
    static let limit = 20_000

    static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("ReversalRiskLog.v1.json")
    }

    mutating func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// Scores a settled window's entries. Returns whether anything changed.
    mutating func resolve(ticker: String, settledUp: Bool) -> Bool {
        var changed = false
        for i in entries.indices where entries[i].ticker == ticker && entries[i].leaderLost == nil {
            entries[i].leaderLost = entries[i].leaderUp != settledUp
            changed = true
        }
        return changed
    }

    /// Said vs. happened in each risk band, over the scored entries.
    struct Band: Sendable, Equatable, Identifiable {
        let label: String
        let count: Int
        let said: Double
        let happened: Double
        var id: String { label }
    }

    var bands: [Band] {
        let scored = entries.compactMap { e in e.leaderLost.map { (e.flip, $0) } }
        return [("Under 15%", 0.0, 0.15), ("15–35%", 0.15, 0.35), ("35% or more", 0.35, 1.01)].compactMap { label, lo, hi in
            let inBand = scored.filter { $0.0 >= lo && $0.0 < hi }
            guard !inBand.isEmpty else { return nil }
            let n = Double(inBand.count)
            return Band(label: label, count: inBand.count, said: inBand.map(\.0).reduce(0, +) / n,
                        happened: Double(inBand.filter(\.1).count) / n)
        }
    }

    static func load(from url: URL = fileURL) -> RiskLog {
        guard let data = try? Data(contentsOf: url), let log = try? decoder.decode(RiskLog.self, from: data) else { return RiskLog() }
        return log
    }

    func save(to url: URL = fileURL) {
        guard let data = try? Self.encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
