//
//  Predictor.swift
//  KalshiBot
//
//  Turns raw market data into normalized features and combines them with an
//  online logistic-regression model into P(window settles Up).
//

import Foundation

/// Every signal the model looks at. Raw values are normalized to roughly −3…3,
/// where positive means "bullish for this window".
nonisolated enum FeatureKey: String, CaseIterable, Codable, Sendable, Identifiable {
    case headStart
    case tickMomentum
    case momentum5m
    case momentum15m
    case emaTrend
    case rsi
    case bollinger
    case stochastic
    case vwapDeviation
    case kalshiImplied
    // Combinations (2.19): a signal counted only in the situation where it plausibly
    // matters. Derived from the signals above (see `FeatureExtractor.addCombinations`),
    // so past windows have them without a rebuild.
    case momentumNearTarget
    case rsiNearTarget
    case momentumWhenUnsure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .headStart: "Spot vs. target"
        case .tickMomentum: "Last-60s tick momentum"
        case .momentum5m: "5m momentum"
        case .momentum15m: "15m momentum"
        case .emaTrend: "EMA 9/21 trend"
        case .rsi: "RSI(14)"
        case .bollinger: "Bollinger %B"
        case .stochastic: "Stochastic %K"
        case .vwapDeviation: "VWAP(60) deviation"
        case .kalshiImplied: "Kalshi implied odds"
        case .momentumNearTarget: "Momentum near the target"
        case .rsiNearTarget: "RSI near the target"
        case .momentumWhenUnsure: "Momentum when Kalshi is unsure"
        }
    }

    /// Signals the model always uses. The rest start as context only: in live data they
    /// were near-duplicates of these (0.76–0.91 correlated), and counting the same "price
    /// has been rising" signal several times inflated confidence. A context signal can
    /// still be promoted into the model by passing the trials in `ModelTrainer`.
    var isBaseInput: Bool {
        switch self {
        case .kalshiImplied, .headStart, .momentum5m, .rsi: true
        default: false
        }
    }

    /// Context signals that can be trialled for promotion.
    static var promotionCandidates: [FeatureKey] { allCases.filter { !$0.isBaseInput } }

    /// Starting weight before any learning.
    ///
    /// Market-anchored (the default), the model starts as exactly Kalshi's own forecast:
    /// weight 1 on its log-odds and 0 on everything else, so an indicator only moves the
    /// call once it has earned weight on held-out windows. Without Kalshi's odds, the
    /// head start gets its random-walk weight: the target is a lagging 60s average, so
    /// P(up) ≈ Φ(z), whose log-odds ≈ 1.7·z.
    func priorWeight(marketAnchored: Bool) -> Double {
        switch self {
        case .kalshiImplied: 1
        case .headStart: marketAnchored ? 0 : 1.7
        default: 0
        }
    }
}

/// Everything needed to evaluate the features at a moment in time.
nonisolated struct MarketSnapshot: Sendable {
    /// One-minute candles, oldest → newest.
    var candles: [Candle]
    /// Current composite spot price (BRTI proxy).
    var spot: Double
    /// Composite price samples from roughly the last minute, oldest → newest.
    var recentTicks: [Double]
    /// The window's target: the official 60s BRTI average before the open.
    var strike: Double
    /// Mid of Kalshi's Yes bid/ask, 0…1.
    var kalshiYesMid: Double?
    /// Minutes until the window closes.
    var minutesRemaining: Double = 15
}

nonisolated enum FeatureExtractor {

    static func features(from s: MarketSnapshot) -> [FeatureKey: Double] {
        let closes = s.candles.map(\.close)
        guard closes.count >= 30, s.spot > 0 else { return [:] }

        // Per-minute price volatility from the last hour of 1m log returns.
        let returns = Indicators.logReturns(Array(closes.suffix(61)))
        let sigmaPerMinute = max((Indicators.standardDeviation(returns) ?? 0.0005) * s.spot, s.spot * 0.00005)
        let atr = max(Indicators.atr(s.candles) ?? sigmaPerMinute, s.spot * 0.00005)

        var f: [FeatureKey: Double] = [:]

        // The settlement value is itself a 60s average, whose variance over the
        // final minute is ~1/3 of a full minute's — hence (T − 1) + 1/3.
        let horizon = max(s.minutesRemaining - 1, 0) + 1.0 / 3.0
        f[.headStart] = (s.spot - s.strike) / (sigmaPerMinute * horizon.squareRoot())

        if s.recentTicks.count >= 10, let slope = Indicators.slope(s.recentTicks) {
            // Slope per sample × samples ≈ move over the last minute.
            f[.tickMomentum] = slope * Double(s.recentTicks.count) / sigmaPerMinute
        }
        if closes.count > 5 {
            f[.momentum5m] = (s.spot - closes[closes.count - 6]) / (sigmaPerMinute * 5.0.squareRoot())
        }
        if closes.count > 15 {
            f[.momentum15m] = (s.spot - closes[closes.count - 16]) / (sigmaPerMinute * 15.0.squareRoot())
        }
        if let e9 = Indicators.ema(closes, period: 9), let e21 = Indicators.ema(closes, period: 21) {
            f[.emaTrend] = (e9 - e21) / atr
        }
        if let r = Indicators.rsi(closes) {
            f[.rsi] = (r - 50) / 15
        }
        if let b = Indicators.bollingerPercentB(closes) {
            f[.bollinger] = (b - 0.5) * 2
        }
        if let k = Indicators.stochasticK(s.candles) {
            f[.stochastic] = (k - 50) / 25
        }
        if let v = Indicators.vwap(s.candles, period: 60) {
            f[.vwapDeviation] = (s.spot - v) / atr / 2
        }
        if let mid = s.kalshiYesMid {
            f[.kalshiImplied] = kalshiFeature(yesMid: mid)
        }

        return addCombinations(f.mapValues { min(max($0, -4), 4) })
    }

    /// How close a z-like value is to zero: 1 at 0, ~0.6 at ±1, ~0.1 at ±2.
    static func closeness(_ z: Double) -> Double { exp(-z * z / 2) }

    /// Adds the combination signals from the ones already present. Stored windows are
    /// passed through here when loaded, so the trainer can trial them on all history.
    static func addCombinations(_ base: [FeatureKey: Double]) -> [FeatureKey: Double] {
        var f = base
        if let m = f[.momentum5m], let h = f[.headStart] { f[.momentumNearTarget] = m * closeness(h) }
        if let r = f[.rsi], let h = f[.headStart] { f[.rsiNearTarget] = r * closeness(h) }
        // kalshiImplied is log-odds; ±1 is about 27%/73%.
        if let m = f[.momentum5m], let k = f[.kalshiImplied] { f[.momentumWhenUnsure] = m * closeness(k) }
        return f
    }

    /// The 1-minute bar (stamped with its start) that ends exactly at `time`.
    /// - Parameter candles: sorted oldest → newest.
    static func candle(endingAt time: Date, in candles: [Candle]) -> Candle? {
        let start = time.addingTimeInterval(-60)
        var low = 0, high = candles.count
        while low < high {
            let mid = (low + high) / 2
            if candles[mid].time < start { low = mid + 1 } else { high = mid }
        }
        return low < candles.count && candles[low].time == start ? candles[low] : nil
    }

    /// Kalshi's Yes price as log-odds, clamped so a 1¢/99¢ quote can't dominate.
    static func kalshiFeature(yesMid: Double) -> Double {
        let p = min(max(yesMid, 0.02), 0.98)
        return log(p / (1 - p))
    }

    /// Rebuilds the features a past window would have had at `time` (the live bot calls
    /// at open + the engine's call delay), from 1-minute candles alone. Spot is the close
    /// of the minute ending at `time`. Tick momentum and Kalshi odds aren't
    /// in candles, so they're left out (odds are fetched separately).
    /// Returns `nil` if the candles leading up to `time` have a gap.
    /// - Parameter candles: sorted oldest → newest.
    static func historicalFeatures(candles: [Candle], at time: Date, strike: Double,
                                   minutesRemaining: Double,
                                   lookback: Int = 150) -> [FeatureKey: Double]? {
        // First bar that hasn't finished by `time` (bars are stamped with their start time).
        var low = 0, high = candles.count
        while low < high {
            let mid = (low + high) / 2
            if candles[mid].time.addingTimeInterval(60) <= time { low = mid + 1 } else { high = mid }
        }
        let history = Array(candles[max(0, low - lookback)..<low])
        guard history.count >= 60, let last = history.last,
              last.time.addingTimeInterval(60) == time,
              let first = history.first,
              last.time.timeIntervalSince(first.time) <= Double(history.count - 1) * 60 * 1.1 else { return nil }

        let snapshot = MarketSnapshot(candles: history, spot: last.close, recentTicks: [], strike: strike,
                                      kalshiYesMid: nil, minutesRemaining: minutesRemaining)
        let features = features(from: snapshot)
        return features.isEmpty ? nil : features
    }
}

/// Logistic-regression weights plus how they were trained. Starts at the priors
/// (Kalshi's forecast when market-anchored) and is refit by `ModelTrainer`.
nonisolated struct PredictionModel: Codable, Sendable, Equatable {
    var bias: Double = 0
    var weights: [String: Double]
    /// Whether this model starts from Kalshi's odds (vs. the head start alone).
    var marketAnchored: Bool
    /// Context signals that earned promotion in the trials (stored by raw value).
    var promoted: Set<String> = []
    /// Settled windows the current weights were fit on (0 = still the priors).
    var trainingCount = 0
    var trainedAt: Date?
    /// Out-of-sample check from the most recent training run.
    var evaluation: ModelEvaluation?
    /// `false` while learned weights haven't yet beaten the starting weights out of
    /// sample, in which case these are the starting weights.
    var usesLearnedWeights = false
    /// The latest promotion trial for each context signal.
    var trials: [String: TrialResult] = [:]

    init(marketAnchored: Bool = true, promoted: Set<FeatureKey> = []) {
        self.marketAnchored = marketAnchored
        self.promoted = Set(promoted.map(\.rawValue))
        weights = Dictionary(uniqueKeysWithValues: (FeatureKey.allCases.filter(\.isBaseInput) + promoted).map {
            ($0.rawValue, $0.priorWeight(marketAnchored: marketAnchored))
        })
    }

    /// The untrained model for a given feature set.
    static func starting(excluding excluded: Set<FeatureKey>, promoted: Set<FeatureKey> = []) -> PredictionModel {
        PredictionModel(marketAnchored: !excluded.contains(.kalshiImplied), promoted: promoted)
    }

    /// Signals this model uses: the base inputs plus any promoted ones.
    func isActive(_ key: FeatureKey) -> Bool {
        key.isBaseInput || promoted.contains(key.rawValue)
    }

    var activeKeys: [FeatureKey] { FeatureKey.allCases.filter(isActive) }

    func weight(for key: FeatureKey) -> Double {
        guard isActive(key) else { return 0 }
        return weights[key.rawValue] ?? key.priorWeight(marketAnchored: marketAnchored)
    }

    func trial(for key: FeatureKey) -> TrialResult? { trials[key.rawValue] }

    /// Per-feature contribution to the logit (active signals only).
    func contributions(_ features: [FeatureKey: Double], excluding excluded: Set<FeatureKey> = []) -> [FeatureKey: Double] {
        var result: [FeatureKey: Double] = [:]
        for (key, value) in features where isActive(key) && !excluded.contains(key) {
            result[key] = weight(for: key) * value
        }
        return result
    }

    func probabilityUp(_ features: [FeatureKey: Double], excluding excluded: Set<FeatureKey> = []) -> Double {
        let logit = bias + contributions(features, excluding: excluded).values.reduce(0, +)
        return 1 / (1 + exp(-logit))
    }
}
