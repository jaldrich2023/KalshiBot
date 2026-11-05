//
//  ReversalRisk.swift
//  KalshiBot
//
//  How likely the side that's winning now is to lose at settlement, and how likely
//  the price is to break out past the window's high or low before the close.
//
//  Backtested Oct 31 on 39,830 minute-by-minute snapshots from 2,847 windows
//  (30 days), fitted on the first half and checked on the second:
//  - Measuring from the current price beats measuring from the 60s average, which
//    lags it by ~30s (Brier 15.78 vs. 16.19 on held-out windows).
//  - The random-walk flip probability is accurate from ~5% up but too low in the
//    tails (it said 0.4% where 1.0% flipped, 3.4% where 5.6% did): BTC has fat
//    tails. Below 15% it's blended toward a fitted correction.
//  - Momentum, RSI, Bollinger, candle patterns and target crossings added nothing
//    beyond the price, so they no longer appear as risk factors.
//  - The reflection-principle breakout probability ran high (said 92%, 47%, 18%
//    where 83%, 36%, 13% happened); a fitted correction brought it in line.
//  Since 2.16 these corrections, a blend with Kalshi's own price and the volatility
//  weighting are refitted from the saved history at each retrain (`RiskCalibration`),
//  and the price's measured tracking error widens the uncertainty.
//

import Foundation

nonisolated struct ReversalRisk: Sendable, Equatable {

    enum Level: Sendable, Equatable {
        case low, moderate, high

        var title: String {
            switch self {
            case .low: "Low"
            case .moderate: "Moderate"
            case .high: "High"
            }
        }
    }

    struct Factor: Sendable, Equatable, Identifiable {
        let title: String
        let detail: String
        /// `true` if this makes a reversal more likely, `false` if less.
        let raisesRisk: Bool
        var id: String { title }
    }

    /// Side the window would settle on, judged by the expected settlement value.
    let currentlyUp: Bool
    /// |expected settlement − target| in dollars.
    let cushion: Double
    /// Cushion in units of the remaining settlement uncertainty.
    let cushionSigma: Double
    /// Calibrated probability that the currently winning side loses at settlement.
    let flipProbability: Double
    /// Kalshi's own price for the same outcome (1 − the leading side's price), when known.
    var kalshiFlipProbability: Double?
    /// Whether `flipProbability` blends in Kalshi's price.
    var blendsKalshi = false
    /// Calibrated probabilities that the price trades above the window high / below the
    /// window low before the close (nil until there's a high and low).
    let breakoutUpProbability: Double?
    let breakoutDownProbability: Double?
    /// How strong the recent move is (descriptive; see `Momentum`).
    var momentum: Momentum?
    let factors: [Factor]

    /// Strength of the move over the last few minutes relative to typical volatility:
    /// 0% = flat, 50% ≈ an ordinary move, 100% = far outside the usual range.
    /// Descriptive only: the Oct 31 backtest found recent momentum added nothing to the
    /// flip probability once the price itself was accounted for.
    struct Momentum: Sendable, Equatable {
        let strength: Double
        let up: Bool
        /// The move is in the direction of the currently winning side.
        let withLeader: Bool
        /// Dollar change over `seconds`.
        let change: Double
        let seconds: TimeInterval
    }

    /// Two-sided normal strength of a move: 2Φ(|z|) − 1 with z = move / (σ√t).
    static func momentumStrength(change: Double, volatility: Double, seconds: TimeInterval) -> Double {
        guard volatility > 0, seconds > 0 else { return 0 }
        let z = abs(change) / (volatility * seconds.squareRoot())
        return 2 * Indicators.normalCDF(z) - 1
    }

    /// By the chance the leading side loses: under 15% low, under 35% moderate.
    var level: Level {
        switch flipProbability {
        case ..<0.15: .low
        case ..<0.35: .moderate
        default: .high
        }
    }

    struct Inputs: Sendable {
        /// Current composite price (calibrated to BRTI).
        var price: Double
        var strike: Double
        var secondsRemaining: TimeInterval
        /// Dollars per √second.
        var volatility: Double
        /// Average of the prices already inside the settlement minute (the final 60s),
        /// once it has started; that part of the settlement is locked in.
        var settlementAverageSoFar: Double?
        var windowHigh: Double?
        var windowLow: Double?
        /// The price `momentumSeconds` ago, for momentum strength.
        var priceEarlier: Double?
        var momentumSeconds: TimeInterval = 180
        /// 1σ error of `price` against the official index, in dollars (from the tracking error).
        var priceUncertainty: Double = 0
        /// Kalshi's Yes mid right now, to compare with and (if calibrated) blend in.
        var kalshiYesMid: Double?
        /// Refitted corrections; nil = the fixed Oct 31 ones.
        var calibration: RiskCalibration?
    }

    static func assess(_ input: Inputs) -> ReversalRisk {
        let odds = SettlementOdds.estimate(price: input.price, strike: input.strike,
                                           secondsRemaining: input.secondsRemaining, volatility: input.volatility,
                                           settlementAverageSoFar: input.settlementAverageSoFar,
                                           priceUncertainty: input.priceUncertainty)
        let up = odds.expected >= input.strike
        let kalshiFlip = input.kalshiYesMid.flatMap { mid in mid > 0 && mid < 1 ? (up ? 1 - mid : mid) : nil }
        // The refit covers +3 to +12 minutes; outside that (and in the settlement minute,
        // where part of the answer is already locked) the fixed correction applies.
        let inFittedRange = input.secondsRemaining >= 180 && input.secondsRemaining <= 720
        let flip: Double
        let blends: Bool
        if let calibration = input.calibration, inFittedRange {
            // The fit's raw flip came from the random walk alone (history has no tracking
            // error), so feed it the same: the raw flip without the price uncertainty.
            let raw = input.priceUncertainty == 0 ? odds.rawFlip
                : SettlementOdds.estimate(price: input.price, strike: input.strike, secondsRemaining: input.secondsRemaining,
                                          volatility: input.volatility,
                                          settlementAverageSoFar: input.settlementAverageSoFar).rawFlip
            flip = calibration.flipProbability(raw: raw, kalshiFlip: kalshiFlip)
            blends = calibration.blend != nil && kalshiFlip != nil
        } else {
            flip = up ? 1 - odds.probabilityUp : odds.probabilityUp
            blends = false
        }

        var factors: [Factor] = []
        if let soFar = input.settlementAverageSoFar, input.secondsRemaining < 60 {
            let locked = (60 - max(input.secondsRemaining, 0)) / 60
            factors.append(Factor(
                title: "Settlement average underway",
                detail: "\(Int((locked * 100).rounded()))% of the final average is already in, at \(BotEngine.usd(soFar)).",
                raisesRisk: false))
        } else if input.secondsRemaining <= 120 && odds.cushionSigma >= 1 {
            factors.append(Factor(
                title: "Little time left",
                detail: "Under 2 minutes to close with a solid cushion.",
                raisesRisk: false))
        }
        if odds.cushionSigma < 0.5 {
            factors.append(Factor(
                title: "Close to the target",
                detail: "The cushion is under half of the price movement still expected before the close.",
                raisesRisk: true))
        }

        let momentum = input.priceEarlier.map { earlier -> Momentum in
            let change = input.price - earlier
            return Momentum(strength: momentumStrength(change: change, volatility: input.volatility, seconds: input.momentumSeconds),
                            up: change >= 0, withLeader: (change >= 0) == up, change: change, seconds: input.momentumSeconds)
        }

        return ReversalRisk(
            currentlyUp: up, cushion: abs(odds.expected - input.strike), cushionSigma: odds.cushionSigma,
            flipProbability: flip, kalshiFlipProbability: kalshiFlip, blendsKalshi: blends,
            breakoutUpProbability: input.windowHigh.map {
                breakoutProbability(distance: $0 - input.price, volatility: input.volatility, secondsRemaining: input.secondsRemaining,
                                    calibration: input.calibration)
            },
            breakoutDownProbability: input.windowLow.map {
                breakoutProbability(distance: input.price - $0, volatility: input.volatility, secondsRemaining: input.secondsRemaining,
                                    calibration: input.calibration)
            },
            momentum: momentum,
            factors: factors)
    }

    /// Probability that a price `distance` dollars below a level (above, for the low)
    /// reaches it before the close. Reflection principle for a random walk,
    /// P = 2·Φ(−d / σ√T), then calibrated (logit a + b·x, fitted on 15 days of windows
    /// and checked on the next 15).
    static func breakoutProbability(distance: Double, volatility: Double, secondsRemaining: TimeInterval,
                                    calibration: RiskCalibration? = nil) -> Double {
        let remaining = max(secondsRemaining, 0)
        guard remaining > 0, volatility > 0 else { return distance <= 0 ? 1 : 0 }
        if distance <= 0 { return 1 }
        let raw = min(2 * Indicators.normalCDF(-distance / (volatility * remaining.squareRoot())), 1)
        if let calibration { return calibration.breakoutProbability(raw: raw) }
        return Calibration.apply(raw, a: RiskCalibration.fixedBreakout[0], b: RiskCalibration.fixedBreakout[1])
    }

    /// Sign changes of (value − strike), ignoring exact touches.
    static func crossings(of values: [Double], strike: Double) -> Int {
        var count = 0
        var previous: Bool?
        for value in values where value != strike {
            let above = value > strike
            if let previous, previous != above { count += 1 }
            previous = above
        }
        return count
    }
}

/// Probability that the window settles Up, from the current price.
nonisolated enum SettlementOdds {

    struct Estimate: Sendable, Equatable {
        /// Expected settlement value (the final-minute average).
        let expected: Double
        /// 1σ uncertainty of the settlement value.
        let sigma: Double
        let cushionSigma: Double
        /// Calibrated P(settles at or above the strike).
        let probabilityUp: Double
        /// Uncalibrated random-walk chance the leading side loses.
        var rawFlip: Double = 0.5
    }

    /// - Parameters:
    ///   - volatility: dollars per √second.
    ///   - settlementAverageSoFar: average of prices already inside the final 60s, if it has started.
    ///   - priceUncertainty: 1σ error of `price` against the official index, added to the
    ///     movement still to come (it matters only when the price is close to the target).
    static func estimate(price: Double, strike: Double, secondsRemaining: TimeInterval, volatility: Double,
                         settlementAverageSoFar: Double? = nil, priceUncertainty: Double = 0) -> Estimate {
        let remaining = max(secondsRemaining, 0)
        let expected: Double
        let movement: Double
        if remaining < 60, let soFar = settlementAverageSoFar {
            // Inside the settlement minute: the elapsed part is known. The rest is the
            // mean of a random walk from `price` over `remaining` seconds, weighted by
            // its share of the minute: σ = vol · (r/60) · √(r/3).
            let share = remaining / 60
            expected = (1 - share) * soFar + share * price
            movement = volatility * share * (remaining / 3).squareRoot()
        } else {
            // Full random walk until the settlement minute, then its average (~⅓ of a
            // minute's variance).
            expected = price
            movement = volatility * (max(remaining - 60, 0) + min(remaining, 60) / 3).squareRoot()
        }
        // The bot's prices — including the settlement seconds already in — can be off the
        // official index by the tracking error, which the remaining movement doesn't shrink.
        let sigma = (movement * movement + priceUncertainty * priceUncertainty).squareRoot()
        let gap = expected - strike
        guard sigma > 0 else {
            return Estimate(expected: expected, sigma: 0, cushionSigma: gap == 0 ? 0 : .infinity,
                            probabilityUp: gap > 0 ? 1 : (gap < 0 ? 0 : 0.5), rawFlip: gap == 0 ? 0.5 : 0)
        }
        let z = abs(gap) / sigma
        let raw = Indicators.normalCDF(-z)
        let flip = calibratedFlip(raw: raw)
        return Estimate(expected: expected, sigma: sigma, cushionSigma: z,
                        probabilityUp: gap >= 0 ? 1 - flip : flip, rawFlip: raw)
    }

    /// The random-walk flip probability is accurate from ~15% up but too low in the
    /// tails. Below 5% use the fitted correction; between 5% and 15% blend linearly.
    static func calibratedFlip(raw: Double) -> Double {
        let corrected = Calibration.apply(raw, a: -0.206, b: 0.783)
        let weight = min(max((0.15 - raw) / 0.10, 0), 1)
        return min(weight * corrected + (1 - weight) * raw, 0.5)
    }
}

nonisolated enum Calibration {
    /// σ(a + b · logit p), with p clamped away from 0 and 1.
    static func apply(_ p: Double, a: Double, b: Double) -> Double {
        let q = min(max(p, 1e-6), 1 - 1e-6)
        return 1 / (1 + exp(-(a + b * log(q / (1 - q)))))
    }
}
