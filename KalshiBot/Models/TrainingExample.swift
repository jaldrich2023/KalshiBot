//
//  TrainingExample.swift
//  KalshiBot
//

import Foundation
import SwiftData

/// A settled window the model learns from. Kept separate from `PredictionRecord`
/// so rebuilt history never mixes into the live accuracy log.
@Model
final class TrainingExample {
    @Attribute(.unique) var ticker: String
    var openTime: Date
    var wentUp: Bool
    /// `true` when it came from a live prediction (full feature set); `false` when
    /// rebuilt from historical candles (no tick-momentum features; Kalshi odds are fetched separately).
    var isLive: Bool
    /// JSON-encoded `[FeatureKey.rawValue: Double]`.
    var featuresData: Data
    /// Seconds after the open the features were taken at. The model only trains on
    /// examples matching the current call time, so live calls match their training.
    var callDelay: Double = 60

    init(ticker: String, openTime: Date, wentUp: Bool, isLive: Bool, callDelay: Double,
         features: [FeatureKey: Double]) {
        self.ticker = ticker
        self.openTime = openTime
        self.wentUp = wentUp
        self.isLive = isLive
        self.callDelay = callDelay
        let raw = Dictionary(uniqueKeysWithValues: features.map { ($0.key.rawValue, $0.value) })
        self.featuresData = (try? JSONEncoder().encode(raw)) ?? Data()
    }

    var sample: TrainingSample {
        let raw = (try? JSONDecoder().decode([String: Double].self, from: featuresData)) ?? [:]
        var features: [FeatureKey: Double] = [:]
        for (key, value) in raw {
            if let feature = FeatureKey(rawValue: key) { features[feature] = value }
        }
        return TrainingSample(features: features, wentUp: wentUp, time: openTime)
    }
}
