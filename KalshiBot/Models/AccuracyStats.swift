//
//  AccuracyStats.swift
//  KalshiBot
//

import Foundation

/// Summary statistics over a set of settled predictions.
nonisolated struct AccuracyStats: Sendable, Equatable {

    struct Bucket: Sendable, Equatable, Identifiable {
        let label: String
        let range: Range<Double>
        var total = 0
        var correct = 0
        var id: String { label }
        var accuracy: Double? { total > 0 ? Double(correct) / Double(total) : nil }
    }

    /// Minimal view of a settled prediction, so stats can be computed and tested
    /// without SwiftData.
    struct Outcome: Sendable {
        let probabilityUp: Double
        let actualUp: Bool
        let marketYesMid: Double?
    }

    var total = 0
    var correct = 0
    var predictedUp = 0
    var actualUp = 0
    /// Mean squared error of P(up) vs. outcome; 0.25 is a coin flip.
    var brierScore: Double?
    var marketTotal = 0
    var marketCorrect = 0
    var marketBrierScore: Double?
    var longestWinStreak = 0
    var longestLosingStreak = 0
    var currentStreak = 0
    var buckets: [Bucket] = [
        Bucket(label: "50–55%", range: 0.50..<0.55),
        Bucket(label: "55–60%", range: 0.55..<0.60),
        Bucket(label: "60–70%", range: 0.60..<0.70),
        Bucket(label: "70%+", range: 0.70..<1.01),
    ]

    /// Paired comparison with Kalshi's favorite on the same windows.
    struct Edge: Sendable, Equatable {
        /// Bot accuracy minus Kalshi-favorite accuracy (fraction, e.g. −0.08 = 8 points worse).
        var accuracy: Double
        /// 95% margin of error on `accuracy`, for display. Never 0 once the two have
        /// disagreed: at least 1.96·√(disagreements) / windows.
        var accuracyMargin: Double
        /// Kalshi's Brier score minus the bot's (positive = bot better).
        var brier: Double
        /// 95% margin of error on `brier` (t-based for small samples).
        var brierMargin: Double
        var windows: Int
        /// Windows where only the bot's side won, and where only Kalshi's favorite did. Accuracy
        /// can differ only on these; everywhere else both were right or both wrong.
        var botOnlyRight = 0
        var kalshiOnlyRight = 0
        /// Windows whose Brier scores differed at all (the bot didn't just quote Kalshi's price).
        var brierPairs = 0

        var disagreements: Int { botOnlyRight + kalshiOnlyRight }

        /// Two-sided exact sign (McNemar) test on the disagreements: the chance of a split at
        /// least this lopsided if each disagreement were a coin flip.
        var accuracyPValue: Double {
            AccuracyStats.signTestPValue(botOnlyRight, kalshiOnlyRight)
        }

        /// The accuracy difference is unlikely to be chance (exact test, p < 0.05). With only
        /// a few disagreements it can't be, however lopsided: 4 of 4 still gives p = 0.125.
        var isSignificant: Bool { disagreements > 0 && accuracyPValue < 0.05 }

        /// The Brier difference is beyond its margin, on enough windows that differed to judge.
        var isBrierSignificant: Bool {
            brierPairs >= AccuracyStats.minimumPairedDifferences && abs(brier) > brierMargin
        }
    }
    var edgeVsMarket: Edge?

    /// Calls at or above this confidence count as "confident".
    static let confidentThreshold = 0.65
    /// Bot calls at ≥ `confidentThreshold` confidence, and how many were right.
    var confidentTotal = 0
    var confidentCorrect = 0
    /// The same for Kalshi's favorite when it was priced at ≥ `confidentThreshold`.
    var marketConfidentTotal = 0
    var marketConfidentCorrect = 0

    var confidentAccuracy: Double? { confidentTotal > 0 ? Double(confidentCorrect) / Double(confidentTotal) : nil }
    var marketConfidentAccuracy: Double? {
        marketConfidentTotal > 0 ? Double(marketConfidentCorrect) / Double(marketConfidentTotal) : nil
    }

    /// How many calls the bot's own probabilities said should be right: the sum of
    /// each call's confidence. Actual well below this means a real problem; a gap
    /// within `expectedCorrectMargin` is ordinary luck.
    var expectedCorrect = 0.0
    /// 95% range around `expectedCorrect` (each call is a weighted coin flip).
    var expectedCorrectMargin = 0.0

    var accuracy: Double? { total > 0 ? Double(correct) / Double(total) : nil }

    /// 95% Wilson score interval on the bot's accuracy: stays within 0–100% and doesn't
    /// collapse to a point at 0% or 100%, unlike the plain ± formula.
    var accuracyInterval: ClosedRange<Double>? {
        total > 0 ? Self.wilsonInterval(successes: correct, total: total) : nil
    }

    /// Half the width of `accuracyInterval` — a single ± figure; never 0 once there's a window.
    var accuracyMargin: Double? {
        accuracyInterval.map { ($0.upperBound - $0.lowerBound) / 2 }
    }

    /// Windows needed for a ±`margin` 95% interval on accuracy near 50%.
    static func windowsNeeded(forMargin margin: Double) -> Int {
        Int((1.96 * 1.96 * 0.25 / (margin * margin)).rounded(.up))
    }
    var marketAccuracy: Double? { marketTotal > 0 ? Double(marketCorrect) / Double(marketTotal) : nil }

    /// What it takes for overall accuracy to reach a target.
    struct TargetPath: Sendable, Equatable {
        let target: Double
        /// Correct calls in a row needed to reach the target (0 once there).
        let correctInARow: Int
        /// Misses in a row that can be absorbed while staying at or above the target.
        let missesToSpare: Int
        /// Average confidence of the calls so far: long-run accuracy tends toward this.
        let averageConfidence: Double?
        /// Further calls the gap would take to close if accuracy ran at `averageConfidence`;
        /// nil when that average is at or below the target (it wouldn't close on its own).
        let expectedCalls: Int?

        var isReached: Bool { correctInARow == 0 }
    }

    /// Solves `(correct + x) / (total + x) ≥ target` for the calls still needed, and
    /// `correct / (total + m) ≥ target` for the misses that can be absorbed.
    func path(to target: Double) -> TargetPath {
        let n = Double(total), c = Double(correct)
        // A small tolerance so an exact hit (7 of 10 at 70%) counts as reached.
        let gap = target * n - c - 1e-9
        let inARow = gap > 0 ? Int((gap / (1 - target)).rounded(.up)) : 0
        let spare = gap > 0 ? 0 : max(Int((c / target - n + 1e-9).rounded(.down)), 0)
        let average = total > 0 ? expectedCorrect / n : nil
        var expected: Int?
        if let average {
            if gap <= 0 { expected = 0 } else if average > target { expected = Int((gap / (average - target)).rounded(.up)) }
        }
        return TargetPath(target: target, correctInARow: inARow, missesToSpare: spare,
                          averageConfidence: average, expectedCalls: expected)
    }

    /// - Parameter outcomes: settled predictions, oldest → newest.
    init(_ outcomes: [Outcome]) {
        var brier = 0.0, marketBrier = 0.0
        var streak = 0
        var accuracyDiffs: [Double] = [], brierDiffs: [Double] = []
        var expectedVariance = 0.0
        for o in outcomes {
            let predictedUpSide = o.probabilityUp >= 0.5
            let isCorrect = predictedUpSide == o.actualUp
            let y = o.actualUp ? 1.0 : 0.0
            total += 1
            if isCorrect { correct += 1 }
            if predictedUpSide { predictedUp += 1 }
            if o.actualUp { actualUp += 1 }
            brier += (o.probabilityUp - y) * (o.probabilityUp - y)

            // Signed streak: positive = consecutive wins, negative = losses.
            streak = isCorrect ? max(streak, 0) + 1 : min(streak, 0) - 1
            longestWinStreak = max(longestWinStreak, streak)
            longestLosingStreak = max(longestLosingStreak, -streak)

            let confidence = max(o.probabilityUp, 1 - o.probabilityUp)
            expectedCorrect += confidence
            expectedVariance += confidence * (1 - confidence)
            if confidence >= Self.confidentThreshold {
                confidentTotal += 1
                if isCorrect { confidentCorrect += 1 }
            }
            if let i = buckets.firstIndex(where: { $0.range.contains(confidence) }) {
                buckets[i].total += 1
                if isCorrect { buckets[i].correct += 1 }
            }

            if let mid = o.marketYesMid {
                let marketIsCorrect = (mid >= 0.5) == o.actualUp
                if max(mid, 1 - mid) >= Self.confidentThreshold {
                    marketConfidentTotal += 1
                    if marketIsCorrect { marketConfidentCorrect += 1 }
                }
                marketTotal += 1
                if marketIsCorrect { marketCorrect += 1 }
                marketBrier += (mid - y) * (mid - y)
                accuracyDiffs.append((isCorrect ? 1 : 0) - (marketIsCorrect ? 1 : 0))
                brierDiffs.append((mid - y) * (mid - y) - (o.probabilityUp - y) * (o.probabilityUp - y))
            }
        }
        currentStreak = streak
        expectedCorrectMargin = 1.96 * expectedVariance.squareRoot()
        if total > 0 { brierScore = brier / Double(total) }
        if marketTotal > 0 { marketBrierScore = marketBrier / Double(marketTotal) }

        // Paired differences on the same windows: far tighter than comparing two separate accuracies.
        if accuracyDiffs.count >= 2 {
            let n = Double(accuracyDiffs.count)
            let botOnly = accuracyDiffs.count { $0 > 0 }, kalshiOnly = accuracyDiffs.count { $0 < 0 }
            let (accuracyEdge, accuracySpread) = Self.meanAndMargin(accuracyDiffs)
            // Most differences are 0, so the spread can be 0 (2 of 2 won by the bot): floor
            // the margin at what the disagreements alone imply.
            let accuracyMargin = max(accuracySpread, 1.96 * Double(botOnly + kalshiOnly).squareRoot() / n)
            let (brierEdge, brierMargin) = Self.meanAndMargin(brierDiffs)
            edgeVsMarket = Edge(accuracy: accuracyEdge, accuracyMargin: accuracyMargin,
                                brier: brierEdge, brierMargin: brierMargin, windows: accuracyDiffs.count,
                                botOnlyRight: botOnly, kalshiOnlyRight: kalshiOnly,
                                brierPairs: brierDiffs.count { abs($0) >= 1e-9 })
        }
    }
}

// MARK: Significance

nonisolated extension AccuracyStats {

    /// Fewest paired windows that must actually differ before a mean difference is called
    /// significant: below this the spread itself is too poorly known to trust.
    static let minimumPairedDifferences = 10

    /// Mean of paired differences and its 95% margin, using Student's t for small samples.
    static func meanAndMargin(_ values: [Double]) -> (mean: Double, margin: Double) {
        let n = Double(values.count)
        guard n > 1 else { return (values.first ?? 0, .infinity) }
        let mean = values.reduce(0, +) / n
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (n - 1)
        return (mean, tCritical95(degreesOfFreedom: values.count - 1) * (variance / n).squareRoot())
    }

    /// Two-sided 95% critical value of Student's t; 1.96 (the normal value) beyond 30.
    static func tCritical95(degreesOfFreedom df: Int) -> Double {
        let table: [Double] = [12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228,
                               2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086,
                               2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042]
        guard df >= 1 else { return .infinity }
        return df <= table.count ? table[df - 1] : 1.96
    }

    /// Exact two-sided sign test: 2·P(X ≥ max(b, c)) for X ~ Binomial(b + c, ½), capped at 1.
    /// 1 when there's nothing to compare.
    static func signTestPValue(_ b: Int, _ c: Int) -> Double {
        let n = b + c
        guard n > 0 else { return 1 }
        // In log space, so thousands of disagreements don't overflow.
        let logHalfToN = Double(n) * log(0.5)
        let tail = (max(b, c)...n).reduce(0.0) { sum, k in
            sum + exp(lgamma(Double(n + 1)) - lgamma(Double(k + 1)) - lgamma(Double(n - k + 1)) + logHalfToN)
        }
        return min(2 * tail, 1)
    }

    /// 95% Wilson score interval for `successes` of `total`, within [0, 1].
    static func wilsonInterval(successes: Int, total: Int) -> ClosedRange<Double> {
        guard total > 0 else { return 0...1 }
        let z = 1.96, n = Double(total), p = Double(successes) / n
        let denominator = 1 + z * z / n
        let center = (p + z * z / (2 * n)) / denominator
        let half = z / denominator * (p * (1 - p) / n + z * z / (4 * n * n)).squareRoot()
        return max(center - half, 0)...min(center + half, 1)
    }
}

extension AccuracyStats {
    init(records: [PredictionRecord]) {
        let outcomes = records
            .filter(\.isResolved)
            .sorted { $0.openTime < $1.openTime }
            .compactMap { r in
                r.actualUp.map { Outcome(probabilityUp: r.probabilityUp, actualUp: $0, marketYesMid: r.marketYesMid) }
            }
        self.init(outcomes)
    }
}
