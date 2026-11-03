//
//  IndicatorGuide.swift
//  KalshiBot
//
//  Plain-language explanations of each indicator and how it is moving the call.
//

import Foundation

extension FeatureKey {

    /// What the indicator measures, independent of its current value.
    var summary: String {
        switch self {
        case .headStart:
            "How far spot is from the target, in units of the price movement expected before the close. The target is a lagging 60s average, so being above it at the open gives Up a head start."
        case .tickMomentum:
            "How much the composite price moved over the last 60 seconds, relative to typical volatility."
        case .momentum5m:
            "Price change over the last 5 minutes, relative to typical volatility."
        case .momentum15m:
            "Price change over the last 15 minutes, relative to typical volatility."
        case .emaTrend:
            "Gap between the 9- and 21-minute exponential moving averages. Fast above slow means a short-term uptrend."
        case .rsi:
            "Relative Strength Index (0–100) over 14 minutes. Above 70 is overbought, below 30 oversold."
        case .bollinger:
            "Where price sits within its 20-minute Bollinger Bands: 0% at the lower band, 100% at the upper."
        case .stochastic:
            "Where the latest close sits within the last 14 minutes' high–low range (0–100)."
        case .vwapDeviation:
            "Distance from the 60-minute volume-weighted average price. Far above VWAP can mean stretched."
        case .kalshiImplied:
            "The Kalshi market's own price for Up — the crowd's probability, which already reflects public information."
        }
    }

    /// The model input this context-only indicator moves with (correlation in live data).
    var overlap: (key: FeatureKey, correlation: Double)? {
        switch self {
        case .tickMomentum: (.headStart, 0.89)
        case .momentum15m: (.rsi, 0.85)
        case .emaTrend: (.rsi, 0.91)
        case .bollinger: (.rsi, 0.84)
        case .stochastic: (.rsi, 0.76)
        case .vwapDeviation: (.rsi, 0.82)
        default: nil
        }
    }

    /// The normalized signal converted back to a human-readable value.
    func displayValue(_ v: Double) -> String {
        func sigma(_ x: Double) -> String { "\(x >= 0 ? "+" : "−")\(abs(x).formatted(.number.precision(.fractionLength(2))))σ" }
        func pct(_ x: Double) -> String { x.formatted(.percent.precision(.fractionLength(0))) }
        switch self {
        case .headStart, .tickMomentum, .momentum5m, .momentum15m: return sigma(v)
        case .emaTrend: return "\(v >= 0 ? "+" : "−")\(abs(v).formatted(.number.precision(.fractionLength(2)))) ATR"
        case .rsi: return (50 + v * 15).formatted(.number.precision(.fractionLength(0)))
        case .bollinger: return pct(v / 2 + 0.5)
        case .stochastic: return (50 + v * 25).formatted(.number.precision(.fractionLength(0)))
        case .vwapDeviation: return "\(v >= 0 ? "+" : "−")\(abs(v * 2).formatted(.number.precision(.fractionLength(2)))) ATR"
        case .kalshiImplied: return pct(1 / (1 + exp(-v)))
        }
    }

    /// What the current value means, in a sentence.
    func interpretation(_ v: Double) -> String {
        func strength(_ x: Double) -> String { abs(x) >= 1.5 ? "strongly" : abs(x) >= 0.5 ? "moderately" : "slightly" }
        switch self {
        case .headStart:
            if abs(v) < 0.1 { return "Spot is essentially at the target — no head start either way." }
            return "Spot is \(strength(v)) \(v > 0 ? "above" : "below") the target, a head start for \(v > 0 ? "Up" : "Down")."
        case .tickMomentum, .momentum5m, .momentum15m:
            let span = self == .tickMomentum ? "last minute" : self == .momentum5m ? "last 5 minutes" : "last 15 minutes"
            if abs(v) < 0.2 { return "Price has been flat over the \(span)." }
            return "Price has \(v > 0 ? "risen" : "fallen") \(strength(v)) over the \(span)."
        case .emaTrend:
            if abs(v) < 0.1 { return "The moving averages are level — no clear short-term trend." }
            return v > 0 ? "Fast average is above slow — a short-term uptrend." : "Fast average is below slow — a short-term downtrend."
        case .rsi:
            let r = 50 + v * 15
            if r >= 70 { return "Overbought — the recent rally is stretched and prone to pull back." }
            if r <= 30 { return "Oversold — the recent drop is stretched and prone to bounce." }
            return r > 50 ? "Leaning bullish, but not stretched." : "Leaning bearish, but not stretched."
        case .bollinger:
            let b = v / 2 + 0.5
            if b >= 0.95 { return "At or above the upper band — price is at the top of its recent range." }
            if b <= 0.05 { return "At or below the lower band — price is at the bottom of its recent range." }
            return b > 0.5 ? "In the upper half of its recent range." : "In the lower half of its recent range."
        case .stochastic:
            let k = 50 + v * 25
            if k >= 80 { return "Closing near the top of its recent range — overbought territory." }
            if k <= 20 { return "Closing near the bottom of its recent range — oversold territory." }
            return k > 50 ? "Closing in the upper part of its recent range." : "Closing in the lower part of its recent range."
        case .vwapDeviation:
            if abs(v) < 0.15 { return "Trading right around VWAP — fair value by volume." }
            return v > 0 ? "Trading above VWAP — buyers have paid up recently." : "Trading below VWAP — sellers have pushed price down."
        case .kalshiImplied:
            let p = 1 / (1 + exp(-v))
            if abs(p - 0.5) < 0.03 { return "The market sees this window as a coin flip." }
            return "The market favors \(p > 0.5 ? "Up" : "Down") at \(max(p, 1 - p).formatted(.percent.precision(.fractionLength(0))))."
        }
    }

    /// Which way the current reading points: positive Up, negative Down. Matches
    /// `interpretation` — stretched oscillators (overbought/oversold) point toward a
    /// pullback, not toward the trend that stretched them.
    func lean(_ v: Double) -> Double {
        switch self {
        case .rsi:
            let r = 50 + v * 15
            return r >= 70 ? -1 : r <= 30 ? 1 : v
        case .bollinger:
            let b = v / 2 + 0.5
            return b >= 0.95 ? -1 : b <= 0.05 ? 1 : v
        case .stochastic:
            let k = 50 + v * 25
            return k >= 80 ? -1 : k <= 20 ? 1 : v
        default:
            return v
        }
    }

    /// The longest interpretation this indicator can produce — used to reserve space.
    var longestInterpretation: String {
        stride(from: -4.0, through: 4.0, by: 0.05).map(interpretation).max { $0.count < $1.count } ?? ""
    }
}

/// How one indicator is moving the prediction.
enum IndicatorEffect {

    /// Change in P(up), in percentage points, from this indicator's contribution:
    /// P(up) with it minus P(up) with its contribution removed.
    static func points(probabilityUp p: Double, contribution c: Double) -> Double {
        let clamped = min(max(p, 1e-6), 1 - 1e-6)
        let logit = log(clamped / (1 - clamped))
        return (p - 1 / (1 + exp(-(logit - c)))) * 100
    }

    static func describe(_ key: FeatureKey, model: PredictionModel, excluded: Set<FeatureKey>,
                         probabilityUp: Double?, contribution: Double?, kalshiYes: Double?) -> String {
        if excluded.contains(key) {
            return "Excluded: “Use Kalshi odds” is off, so the model ignores the market price and leans on the head start instead."
        }
        guard model.isActive(key) else {
            var text = "Not used by the model."
            if let overlap = key.overlap {
                text += " In live data it moved closely with \(overlap.key.title) (correlation \(overlap.correlation.formatted(.number.precision(.fractionLength(2))))), so counting both would double-count the same signal."
            }
            return text + " " + trialSummary(key, model: model)
        }
        if key == .kalshiImplied && model.marketAnchored && !model.usesLearnedWeights {
            let odds = kalshiYes.map { " (\($0.formatted(.percent.precision(.fractionLength(0)))) Up)" } ?? ""
            return "The anchor of the prediction: the call starts from Kalshi's odds\(odds). Other inputs can only shift it once they've proven themselves on held-out windows."
        }
        let weight = model.weight(for: key)
        guard abs(weight) > 0.001 else {
            return "A model input, but its weight is 0 — it hasn't yet improved predictions on held-out windows, so it isn't moving the call."
        }
        guard let probabilityUp, let contribution else {
            return "A model input with weight \(weight.formatted(.number.precision(.fractionLength(2)))); waiting for data."
        }
        let pts = points(probabilityUp: probabilityUp, contribution: contribution)
        if abs(pts) < 0.5 {
            return "Near-neutral right now: shifts P(up) by under half a point (weight \(weight.formatted(.number.precision(.fractionLength(2)))))."
        }
        return "Shifts P(up) \(pts > 0 ? "+" : "−")\(abs(pts).formatted(.number.precision(.fractionLength(1)))) pts toward \(pts > 0 ? "Up" : "Down") (weight \(weight.formatted(.number.precision(.fractionLength(2)))))."
    }

    /// The latest promotion trial, in words.
    static func trialSummary(_ key: FeatureKey, model: PredictionModel) -> String {
        guard let trial = model.trial(for: key) else { return "Not trialled yet." }
        guard trial.hasEnoughData else {
            if trial.liveOnly == true {
                return "Only windows the bot watched live have it, so it's trialled on those alone: \(trial.liveWindows ?? 0) of the \(ModelTrainer.minimumLiveTrialWindows) needed so far."
            }
            return "Can't be trialled: only \(trial.coverage.formatted(.percent.precision(.fractionLength(0)))) of past windows have it."
        }
        let gain = (trial.gain * 1000).formatted(.number.precision(.fractionLength(2)).sign(strategy: .always()))
        let margin = (trial.margin * 1000).formatted(.number.precision(.fractionLength(2)))
        let verdict = trial.isSignificantGain ? "a significant gain" : "no significant gain"
        let counting = trial.counted == true
            ? (trial.isSignificantGain ? " It counts toward promotion." : " It counts against promotion.")
            : " Only windows that settle after the last counted result can count; \(ModelTrainer.freshWindowsPerTrial) are needed."
        return "Latest trial\(trial.liveOnly == true ? " (live windows only)" : ""): \(gain) ± \(margin) milli-log-loss on \(trial.windows) held-out windows, \(verdict) (margin widened for testing several signals).\(counting)"
    }

    /// The longest description `describe` can produce for this indicator — used to reserve space.
    static func longestDescription(_ key: FeatureKey) -> String {
        var learned = PredictionModel.starting(excluding: [])
        learned.usesLearnedWeights = true
        learned.weights[key.rawValue] = -8.88
        var trialled = PredictionModel.starting(excluding: [])
        trialled.trials[key.rawValue] = TrialResult(gain: -0.00888, margin: 0.00888, coverage: 0.88, windows: 8888, counted: false)
        let candidates = [
            describe(key, model: trialled, excluded: [], probabilityUp: 0.5, contribution: 0, kalshiYes: 0.88),
            describe(key, model: .starting(excluding: []), excluded: [], probabilityUp: 0.5, contribution: 0, kalshiYes: 0.88),
            describe(key, model: learned, excluded: [], probabilityUp: 0.88, contribution: -8.88, kalshiYes: 0.88),
            describe(key, model: .starting(excluding: [.kalshiImplied]), excluded: [.kalshiImplied], probabilityUp: nil, contribution: nil, kalshiYes: nil),
            "A model input with weight −8.88; waiting for data.",
        ]
        return candidates.max { $0.count < $1.count } ?? ""
    }
}
