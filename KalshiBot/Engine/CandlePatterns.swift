//
//  CandlePatterns.swift
//  KalshiBot
//
//  Classic candlestick pattern recognition on completed 1-minute candles.
//

import Foundation

nonisolated enum PatternBias: String, Sendable {
    case bullish, bearish, neutral

    var title: String {
        switch self {
        case .bullish: "Bullish"
        case .bearish: "Bearish"
        case .neutral: "Neutral"
        }
    }
}

nonisolated enum PriorTrend: Sendable, Equatable {
    case up, down, sideways

    var title: String {
        switch self {
        case .up: "uptrend"
        case .down: "downtrend"
        case .sideways: "sideways"
        }
    }
}

nonisolated struct CandlePattern: Sendable, Equatable, Identifiable {
    let name: String
    let bias: PatternBias
    /// 1 = weak, 2 = moderate, 3 = strong (by textbook reliability).
    let strength: Int
    /// How many of the most recent candles form the pattern.
    let candleCount: Int
    let meaning: String

    var id: String { name }

    var strengthTitle: String {
        switch strength {
        case 3: "Strong"
        case 2: "Moderate"
        default: "Weak"
        }
    }
}

nonisolated struct PatternAnalysis: Sendable, Equatable {
    /// Every pattern that matched, most significant first.
    let patterns: [CandlePattern]
    let trend: PriorTrend
    /// The completed candles analyzed, oldest → newest.
    let candles: [Candle]

    var primary: CandlePattern? { patterns.first }
}

nonisolated enum CandlePatterns {

    /// Analyzes the most recent contiguous run of completed candles.
    /// - Parameter candles: completed 1-minute candles, oldest → newest.
    static func analyze(_ candles: [Candle]) -> PatternAnalysis? {
        let run = contiguousTail(candles)
        guard let last = run.last, last.high > last.low else { return nil }

        var patterns: [CandlePattern] = []
        let count = run.count

        // Trend is judged on the candles *before* each pattern begins.
        func trend(before patternLength: Int) -> PriorTrend {
            priorTrend(Array(run.dropLast(patternLength)))
        }

        if count >= 3 {
            patterns += threeCandle(run[count - 3], run[count - 2], run[count - 1], trend: trend(before: 3))
        }
        if count >= 2 {
            patterns += twoCandle(run[count - 2], run[count - 1], trend: trend(before: 2))
        }
        patterns += singleCandle(last, trend: trend(before: 1))

        patterns.sort { ($0.candleCount, $0.strength) > ($1.candleCount, $1.strength) }
        return PatternAnalysis(patterns: patterns, trend: trend(before: 1), candles: run)
    }

    // MARK: Geometry

    private static func body(_ c: Candle) -> Double { abs(c.close - c.open) }
    private static func range(_ c: Candle) -> Double { c.high - c.low }
    private static func upperShadow(_ c: Candle) -> Double { c.high - max(c.open, c.close) }
    private static func lowerShadow(_ c: Candle) -> Double { min(c.open, c.close) - c.low }
    private static func isUp(_ c: Candle) -> Bool { c.close > c.open }
    private static func isDown(_ c: Candle) -> Bool { c.close < c.open }
    private static func midpoint(_ c: Candle) -> Double { (c.open + c.close) / 2 }

    /// Trailing candles with no missing minutes (the bot may have been paused).
    static func contiguousTail(_ candles: [Candle]) -> [Candle] {
        guard var start = candles.indices.last else { return [] }
        while start > 0, candles[start].time.timeIntervalSince(candles[start - 1].time) == 60 {
            start -= 1
        }
        return Array(candles[start...])
    }

    /// Net move across up to 5 prior candles, in units of their average range.
    static func priorTrend(_ prior: [Candle]) -> PriorTrend {
        let window = prior.suffix(5)
        guard window.count >= 3, let first = window.first, let last = window.last else { return .sideways }
        let averageRange = window.map(range).reduce(0, +) / Double(window.count)
        guard averageRange > 0 else { return .sideways }
        let move = (last.close - first.open) / averageRange
        if move > 1 { return .up }
        if move < -1 { return .down }
        return .sideways
    }

    // MARK: Single candle

    private static func singleCandle(_ c: Candle, trend: PriorTrend) -> [CandlePattern] {
        let r = range(c), b = body(c), up = upperShadow(c), low = lowerShadow(c)
        guard r > 0 else { return [] }

        if b <= r * 0.1 {
            if low >= r * 0.7 {
                return [CandlePattern(name: "Dragonfly Doji", bias: .bullish, strength: 2, candleCount: 1,
                                      meaning: "Sellers pushed price down but buyers drove it all the way back to the open. Signals rejection of lower prices, especially after a decline.")]
            }
            if up >= r * 0.7 {
                return [CandlePattern(name: "Gravestone Doji", bias: .bearish, strength: 2, candleCount: 1,
                                      meaning: "Buyers pushed price up but sellers drove it all the way back to the open. Signals rejection of higher prices, especially after a rally.")]
            }
            return [CandlePattern(name: "Doji", bias: .neutral, strength: 1, candleCount: 1,
                                  meaning: "Open and close are nearly equal — buyers and sellers are in balance. Indecision; after a strong move it can mark exhaustion.")]
        }

        if b >= r * 0.9 {
            return isUp(c)
                ? [CandlePattern(name: "Bullish Marubozu", bias: .bullish, strength: 2, candleCount: 1,
                                 meaning: "A full-bodied up candle with almost no wicks: buyers controlled the entire minute. Shows strong momentum that often carries into the next candles.")]
                : [CandlePattern(name: "Bearish Marubozu", bias: .bearish, strength: 2, candleCount: 1,
                                 meaning: "A full-bodied down candle with almost no wicks: sellers controlled the entire minute. Shows strong momentum that often carries into the next candles.")]
        }

        // Long lower wick, small body near the top.
        if low >= b * 2, up <= b * 0.5 {
            switch trend {
            case .down:
                return [CandlePattern(name: "Hammer", bias: .bullish, strength: 2, candleCount: 1,
                                      meaning: "After a decline, sellers drove price well down but buyers recovered most of it. A classic early sign the selling is exhausted and a bounce may follow.")]
            case .up:
                return [CandlePattern(name: "Hanging Man", bias: .bearish, strength: 1, candleCount: 1,
                                      meaning: "After a rally, a deep intra-minute sell-off appeared before buyers recovered. Warns that selling pressure is building; needs a down candle next to confirm.")]
            case .sideways:
                return [CandlePattern(name: "Bullish Pin Bar", bias: .bullish, strength: 1, candleCount: 1,
                                      meaning: "A long lower wick shows lower prices were tested and rejected. Mildly bullish, though without a prior trend it's a weaker signal.")]
            }
        }

        // Long upper wick, small body near the bottom.
        if up >= b * 2, low <= b * 0.5 {
            switch trend {
            case .up:
                return [CandlePattern(name: "Shooting Star", bias: .bearish, strength: 2, candleCount: 1,
                                      meaning: "After a rally, buyers pushed price higher but sellers slammed it back down. A classic warning that the up-move is losing steam.")]
            case .down:
                return [CandlePattern(name: "Inverted Hammer", bias: .bullish, strength: 1, candleCount: 1,
                                      meaning: "After a decline, buyers made a strong attempt higher. Hints the downtrend may be ending; needs an up candle next to confirm.")]
            case .sideways:
                return [CandlePattern(name: "Bearish Pin Bar", bias: .bearish, strength: 1, candleCount: 1,
                                      meaning: "A long upper wick shows higher prices were tested and rejected. Mildly bearish, though without a prior trend it's a weaker signal.")]
            }
        }

        if b <= r * 0.3, up > b, low > b {
            return [CandlePattern(name: "Spinning Top", bias: .neutral, strength: 1, candleCount: 1,
                                  meaning: "A small body with wicks on both sides — price swung both ways and settled near where it started. Indecision; momentum is fading.")]
        }
        return []
    }

    // MARK: Two candles

    private static func twoCandle(_ a: Candle, _ b: Candle, trend: PriorTrend) -> [CandlePattern] {
        var found: [CandlePattern] = []
        let tolerance = max(range(a), range(b)) * 0.05

        if isDown(a), isUp(b), b.open <= a.close, b.close >= a.open, body(b) > body(a) {
            found.append(CandlePattern(name: "Bullish Engulfing", bias: .bullish, strength: trend == .down ? 3 : 2, candleCount: 2,
                                       meaning: "An up candle whose body completely swallows the prior down candle. Buyers overpowered sellers decisively — one of the more reliable reversal signals, strongest after a decline."))
        } else if isUp(a), isDown(b), b.open >= a.close, b.close <= a.open, body(b) > body(a) {
            found.append(CandlePattern(name: "Bearish Engulfing", bias: .bearish, strength: trend == .up ? 3 : 2, candleCount: 2,
                                       meaning: "A down candle whose body completely swallows the prior up candle. Sellers overpowered buyers decisively — one of the more reliable reversal signals, strongest after a rally."))
        } else if isDown(a), body(a) >= range(a) * 0.5, body(b) <= body(a) * 0.5,
                  max(b.open, b.close) <= a.open, min(b.open, b.close) >= a.close {
            found.append(CandlePattern(name: "Bullish Harami", bias: .bullish, strength: 1, candleCount: 2,
                                       meaning: "A small candle contained within the prior large down candle. Selling momentum has stalled; a possible early reversal that needs confirmation."))
        } else if isUp(a), body(a) >= range(a) * 0.5, body(b) <= body(a) * 0.5,
                  max(b.open, b.close) <= a.close, min(b.open, b.close) >= a.open {
            found.append(CandlePattern(name: "Bearish Harami", bias: .bearish, strength: 1, candleCount: 2,
                                       meaning: "A small candle contained within the prior large up candle. Buying momentum has stalled; a possible early reversal that needs confirmation."))
        } else if isDown(a), isUp(b), body(a) >= range(a) * 0.5, b.open < a.close, b.close > midpoint(a), b.close < a.open {
            found.append(CandlePattern(name: "Piercing Line", bias: .bullish, strength: 2, candleCount: 2,
                                       meaning: "After a strong down candle, price opened lower but closed above the prior body's midpoint. Buyers are fighting back."))
        } else if isUp(a), isDown(b), body(a) >= range(a) * 0.5, b.open > a.close, b.close < midpoint(a), b.close > a.open {
            found.append(CandlePattern(name: "Dark Cloud Cover", bias: .bearish, strength: 2, candleCount: 2,
                                       meaning: "After a strong up candle, price opened higher but closed below the prior body's midpoint. Sellers are taking control."))
        }

        if trend == .down, abs(a.low - b.low) <= tolerance, isDown(a), isUp(b) {
            found.append(CandlePattern(name: "Tweezer Bottom", bias: .bullish, strength: 1, candleCount: 2,
                                       meaning: "Two candles hit the same low and the second turned up. That price is acting as support."))
        } else if trend == .up, abs(a.high - b.high) <= tolerance, isUp(a), isDown(b) {
            found.append(CandlePattern(name: "Tweezer Top", bias: .bearish, strength: 1, candleCount: 2,
                                       meaning: "Two candles hit the same high and the second turned down. That price is acting as resistance."))
        }
        return found
    }

    // MARK: Three candles

    private static func threeCandle(_ a: Candle, _ b: Candle, _ c: Candle, trend: PriorTrend) -> [CandlePattern] {
        let smallMiddle = body(b) <= min(body(a), body(c)) * 0.5

        if isDown(a), body(a) >= range(a) * 0.5, smallMiddle, isUp(c), c.close > midpoint(a) {
            return [CandlePattern(name: "Morning Star", bias: .bullish, strength: 3, candleCount: 3,
                                  meaning: "A strong down candle, a small pause candle, then a strong up candle closing deep into the first. A textbook three-step bullish reversal.")]
        }
        if isUp(a), body(a) >= range(a) * 0.5, smallMiddle, isDown(c), c.close < midpoint(a) {
            return [CandlePattern(name: "Evening Star", bias: .bearish, strength: 3, candleCount: 3,
                                  meaning: "A strong up candle, a small pause candle, then a strong down candle closing deep into the first. A textbook three-step bearish reversal.")]
        }

        let candles = [a, b, c]
        let solidBodies = candles.allSatisfy { body($0) >= range($0) * 0.5 }
        if solidBodies, candles.allSatisfy(isUp), a.close < b.close, b.close < c.close,
           b.open > a.open, c.open > b.open {
            return [CandlePattern(name: "Three White Soldiers", bias: .bullish, strength: 3, candleCount: 3,
                                  meaning: "Three consecutive strong up candles, each closing higher. Sustained buying pressure and a strong continuation signal.")]
        }
        if solidBodies, candles.allSatisfy(isDown), a.close > b.close, b.close > c.close,
           b.open < a.open, c.open < b.open {
            return [CandlePattern(name: "Three Black Crows", bias: .bearish, strength: 3, candleCount: 3,
                                  meaning: "Three consecutive strong down candles, each closing lower. Sustained selling pressure and a strong continuation signal.")]
        }
        return []
    }
}
