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
        /// 95% margin of error on `accuracy`.
        var accuracyMargin: Double
        /// Kalshi's Brier score minus the bot's (positive = bot better).
        var brier: Double
        var brierMargin: Double
        var windows: Int

        /// The difference is bigger than its margin of error.
        var isSignificant: Bool { abs(accuracy) > accuracyMargin }
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

    /// 95% margin of error on the bot's accuracy.
    var accuracyMargin: Double? {
        guard let accuracy, total > 1 else { return nil }
        return 1.96 * (accuracy * (1 - accuracy) / Double(total)).squareRoot()
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
        func meanAndMargin(_ values: [Double]) -> (Double, Double) {
            let n = Double(values.count)
            let mean = values.reduce(0, +) / n
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / max(n - 1, 1)
            return (mean, 1.96 * (variance / n).squareRoot())
        }
        if accuracyDiffs.count >= 2 {
            let (accuracyEdge, accuracyMargin) = meanAndMargin(accuracyDiffs)
            let (brierEdge, brierMargin) = meanAndMargin(brierDiffs)
            edgeVsMarket = Edge(accuracy: accuracyEdge, accuracyMargin: accuracyMargin,
                                brier: brierEdge, brierMargin: brierMargin, windows: accuracyDiffs.count)
        }
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
