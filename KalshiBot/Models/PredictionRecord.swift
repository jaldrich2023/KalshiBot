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
    var resolvedAt: Date?

    init(ticker: String, openTime: Date, closeTime: Date, predictedAt: Date, strike: Double,
         spotAtPrediction: Double, proxyOpenAverage: Double?, probabilityUp: Double,
         marketYesMid: Double?, marketYesBid: Double? = nil, marketYesAsk: Double? = nil,
         features: [FeatureKey: Double], contributions: [FeatureKey: Double],
         excludedFeatures: Set<FeatureKey>) {
        self.ticker = ticker
        self.openTime = openTime
        self.closeTime = closeTime
        self.predictedAt = predictedAt
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

    var isCorrect: Bool? { actualUp.map { $0 == predictedUp } }

    /// Whether the market's own favorite (Yes mid ≥ 0.5) was right.
    var marketCorrect: Bool? {
        guard let actualUp, let marketYesMid else { return nil }
        return (marketYesMid >= 0.5) == actualUp
    }

    /// Confidence in the predicted side, 0.5…1.
    var confidence: Double { max(probabilityUp, 1 - probabilityUp) }

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
