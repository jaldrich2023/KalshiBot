//
//  PredictionRecord.swift
//  KalshiBot
//

import Foundation
import SwiftData

/// One 15-minute window: the prediction locked in at the open, and the outcome once settled.
@Model
final class PredictionRecord {
    @Attribute(.unique) var ticker: String
    var openTime: Date
    var closeTime: Date
    var predictedAt: Date
    /// The call time the call was locked for, in seconds after the open — the setting, not
    /// the moment it was actually made (a slow data fetch can make that a little later).
    /// 0 on records made before 2.28.
    var callDelay: Double = 0

    /// Official target (60s BRTI average before the open), from Kalshi.
    var strike: Double
    /// Composite spot price when the prediction was made.
    var spotAtPrediction: Double
    /// Our own 60s average of the composite before the open, to track proxy drift vs. BRTI.
    var proxyOpenAverage: Double?

    var probabilityUp: Double
    var predictedUp: Bool
    /// Kalshi Yes mid at prediction time — the market's own forecast, used as a baseline.
    var marketYesMid: Double?
    /// Kalshi's best Yes bid and ask at prediction time — what a trade would actually
    /// have cost (buying Yes pays the ask; buying No pays 1 − bid). Nil on records made
    /// before these were logged.
    var marketYesBid: Double?
    var marketYesAsk: Double?

    /// JSON-encoded `[FeatureKey.rawValue: Double]` snapshots.
    var featuresData: Data
    var contributionsData: Data
    /// Features that were excluded from the model when this prediction was made.
    var excludedFeatures: [String] = []

    // Outcome
    var actualUp: Bool?
    var settlementValue: Double?
    /// When the result came in. Set with no `actualUp` when the window was voided (it
    /// never settled Yes or No); such a window isn't counted anywhere.
    var resolvedAt: Date?

    init(ticker: String, openTime: Date, closeTime: Date, predictedAt: Date, strike: Double,
         spotAtPrediction: Double, proxyOpenAverage: Double?, probabilityUp: Double,
         marketYesMid: Double?, marketYesBid: Double? = nil, marketYesAsk: Double? = nil,
         features: [FeatureKey: Double], contributions: [FeatureKey: Double],
         excludedFeatures: Set<FeatureKey>, callDelay: Double = 0) {
        self.ticker = ticker
        self.openTime = openTime
        self.closeTime = closeTime
        self.predictedAt = predictedAt
        self.callDelay = callDelay
        self.strike = strike
        self.spotAtPrediction = spotAtPrediction
        self.proxyOpenAverage = proxyOpenAverage
        self.probabilityUp = probabilityUp
        self.predictedUp = probabilityUp >= 0.5
        self.marketYesMid = marketYesMid
        self.marketYesBid = marketYesBid
        self.marketYesAsk = marketYesAsk
        self.featuresData = Self.encode(features)
        self.contributionsData = Self.encode(contributions)
        self.excludedFeatures = excludedFeatures.map(\.rawValue)
    }

    var isResolved: Bool { actualUp != nil }

    /// Closed with no Yes/No result (voided); no longer waited on, and not counted.
    var isVoid: Bool { actualUp == nil && resolvedAt != nil }

    var isCorrect: Bool? { actualUp.map { $0 == predictedUp } }

    /// Whether the market's own favorite (Yes mid ≥ 0.5) was right.
    var marketCorrect: Bool? {
        guard let actualUp, let marketYesMid else { return nil }
        return (marketYesMid >= 0.5) == actualUp
    }

    /// Confidence in the predicted side, 0.5…1.
    var confidence: Double { max(probabilityUp, 1 - probabilityUp) }

    // Wait until confident (2.28)
    /// The confidence the call waited for (0 = it locked at the call time, as before 2.28).
    var waitLevel: Double = 0
    /// When a waiting call locked. Nil while it's still waiting — or, once the deadline
    /// has passed, because it never reached `waitLevel` (a No call).
    var lockedAt: Date?

    /// The call is waiting to reach its confidence level (or never did).
    var isAwaitingCall: Bool { waitLevel > 0 && lockedAt == nil }

    /// Seconds into the window the call locked.
    var lockOffset: TimeInterval { max(predictedAt.timeIntervalSince(openTime), 0) }

    /// "+6:12": minutes and seconds into the window.
    nonisolated static func offsetText(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds.rounded()), 0)
        return "+\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// When settled calls locked, on average, and how many of them waited. Calls that
    /// never locked (no call) aren't included; nil with no settled calls.
    static func averageLock(_ calls: [PredictionRecord]) -> (seconds: TimeInterval, calls: Int, waited: Int)? {
        let locked = calls.filter { $0.isResolved && !$0.isAwaitingCall }
        guard !locked.isEmpty else { return nil }
        let mean = locked.map(\.lockOffset).reduce(0, +) / Double(locked.count)
        return (mean, locked.count, locked.filter { $0.waitLevel > 0 }.count)
    }

    /// Locks a waiting call with the model's view now. The features from the call time
    /// stay as they were: they're the window's training example, made at the same moment
    /// for every window.
    func lockCall(at time: Date, probabilityUp: Double, spot: Double, yesMid: Double?, yesBid: Double?, yesAsk: Double?,
                  contributions: [FeatureKey: Double]) {
        self.probabilityUp = probabilityUp
        predictedUp = probabilityUp >= 0.5
        predictedAt = time
        spotAtPrediction = spot
        marketYesMid = yesMid
        marketYesBid = yesBid
        marketYesAsk = yesAsk
        contributionsData = Self.encode(contributions)
        lockedAt = time
    }

    var features: [FeatureKey: Double] { Self.decode(featuresData) }
    var contributions: [FeatureKey: Double] { Self.decode(contributionsData) }
    var excluded: Set<FeatureKey> { Set(excludedFeatures.compactMap(FeatureKey.init(rawValue:))) }

    private static func encode(_ values: [FeatureKey: Double]) -> Data {
        let raw = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
        return (try? JSONEncoder().encode(raw)) ?? Data()
    }

    private static func decode(_ data: Data) -> [FeatureKey: Double] {
        guard let raw = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        var result: [FeatureKey: Double] = [:]
        for (key, value) in raw {
            if let feature = FeatureKey(rawValue: key) { result[feature] = value }
        }
        return result
    }
}
