//
//  KalshiBotTests.swift
//  KalshiBotTests
//
//  Created by John Aldrich on 10/26/26.
//

import Foundation
import SwiftUI
import Testing
@testable import KalshiBot

struct IndicatorTests {

    private func candles(_ closes: [Double]) -> [Candle] {
        closes.enumerated().map { i, c in
            Candle(time: Date(timeIntervalSince1970: Double(i) * 60), open: c, high: c + 1, low: c - 1, close: c, volume: 1)
        }
    }

    @Test func emaOfConstantSeriesIsConstant() {
        #expect(Indicators.ema(Array(repeating: 5, count: 30), period: 9) == 5)
    }

    @Test func rsiExtremes() throws {
        let rising = (0..<30).map(Double.init)
        let falling = Array(rising.reversed())
        #expect(try #require(Indicators.rsi(rising)) == 100)
        #expect(try #require(Indicators.rsi(falling)) < 1)
    }

    @Test func macdPositiveInUptrend() throws {
        let closes = (0..<60).map { 100 + Double($0) * Double($0) * 0.01 }
        #expect(try #require(Indicators.macd(closes)).macd > 0)
    }

    @Test func bollingerPercentBAboveUpperBandOnBreakout() throws {
        let closes = (0..<19).map { 100 + ($0.isMultiple(of: 2) ? 0.5 : -0.5) } + [110]
        #expect(try #require(Indicators.bollingerPercentB(closes)) > 1)
    }

    @Test func stochasticAtTopOfRange() throws {
        let k = try #require(Indicators.stochasticK(candles((0..<20).map(Double.init))))
        #expect(k > 90)
    }

    @Test func slopeOfLine() throws {
        #expect(abs(try #require(Indicators.slope([1, 3, 5, 7])) - 2) < 1e-9)
    }

    @Test func volumeFlowAllUp() throws {
        #expect(try #require(Indicators.volumeFlow(candles((0..<20).map(Double.init)), period: 15)) == 1)
    }

    @Test func trailingAverageUsesOnlyTheLast60Seconds() throws {
        // One sample per second: price 100 for t = 0…59, then 200 for t = 60…119.
        let base = Date(timeIntervalSince1970: 0)
        let samples = (0..<120).map { (time: base.addingTimeInterval(Double($0)), price: $0 < 60 ? 100.0 : 200.0) }
        let averages = Indicators.trailingAverage(samples)

        // Nothing is emitted until 55s of history exists.
        #expect(try #require(averages.first).time == base.addingTimeInterval(55))
        // At t = 59 the window (−1, 59] holds sixty 100s.
        #expect(averages.first { $0.time == base.addingTimeInterval(59) }?.average == 100)
        // At t = 89 the window (29, 89] is half 100s, half 200s.
        #expect(averages.first { $0.time == base.addingTimeInterval(89) }?.average == 150)
        // At t = 119 the window (59, 119] holds sixty 200s.
        #expect(averages.last?.average == 200)
    }

    @Test func trailingAverageWaitsForCoverage() {
        let base = Date(timeIntervalSince1970: 0)
        let samples = (0..<30).map { (time: base.addingTimeInterval(Double($0)), price: 1.0) }
        #expect(Indicators.trailingAverage(samples).isEmpty)
    }

    @Test func minuteCandlesAggregateOHLC() throws {
        let base = Date(timeIntervalSince1970: 0)
        let samples: [(time: Date, price: Double)] = [
            (base.addingTimeInterval(-5), 999),           // before the window — ignored
            (base.addingTimeInterval(1), 10), (base.addingTimeInterval(20), 14),
            (base.addingTimeInterval(40), 8), (base.addingTimeInterval(59), 12),
            (base.addingTimeInterval(61), 13),
        ]
        let candles = Indicators.minuteCandles(samples, from: base, to: base.addingTimeInterval(900))
        #expect(candles.count == 2)
        let first = try #require(candles.first)
        #expect(first.time == base)
        #expect((first.open, first.high, first.low, first.close) == (10, 14, 8, 12))
        #expect(candles[1].time == base.addingTimeInterval(60))
        #expect(candles[1].open == 13)
    }

    @Test func normalCDF() {
        #expect(abs(Indicators.normalCDF(0) - 0.5) < 1e-9)
        #expect(abs(Indicators.normalCDF(1.96) - 0.975) < 1e-3)
    }
}

struct PredictorTests {

    private func snapshot(spot: Double, strike: Double) -> MarketSnapshot {
        // Gentle random-ish walk around 80k so volatility is non-zero.
        let closes = (0..<120).map { 80_000 + sin(Double($0) / 3) * 40 }
        let candles = closes.enumerated().map { i, c in
            Candle(time: Date(timeIntervalSince1970: Double(i) * 60), open: c, high: c + 10, low: c - 10, close: c, volume: 2)
        }
        return MarketSnapshot(candles: candles, spot: spot, recentTicks: [], strike: strike, kalshiYesMid: 0.5)
    }

    @Test func headStartSignMatchesSpotVsStrike() throws {
        let above = FeatureExtractor.features(from: snapshot(spot: 80_050, strike: 80_000))
        let below = FeatureExtractor.features(from: snapshot(spot: 79_950, strike: 80_000))
        #expect(try #require(above[.headStart]) > 0)
        #expect(try #require(below[.headStart]) < 0)
    }

    @Test func featuresAreClipped() {
        let features = FeatureExtractor.features(from: snapshot(spot: 90_000, strike: 80_000))
        #expect(features.values.allSatisfy { abs($0) <= 4 })
    }

    @Test func startingModelIsExactlyTheMarket() {
        let model = PredictionModel.starting(excluding: [])
        let features: [FeatureKey: Double] = [.kalshiImplied: FeatureExtractor.kalshiFeature(yesMid: 0.62),
                                              .headStart: 2, .rsi: -1.5, .emaTrend: 3]
        #expect(abs(model.probabilityUp(features) - 0.62) < 1e-9)
    }

    @Test func withoutKalshiTheHeadStartLeads() {
        let model = PredictionModel.starting(excluding: [.kalshiImplied])
        #expect(!model.marketAnchored)
        #expect(model.weight(for: .headStart) == 1.7)
        #expect(model.probabilityUp([.headStart: 1]) > 0.8)
    }

    @Test func candleEndingAtFindsTheRightBar() throws {
        let bars = (0..<5).map { Candle(time: Date(timeIntervalSince1970: Double($0) * 60), open: 1, high: 1, low: 1, close: Double($0), volume: 0) }
        #expect(try #require(FeatureExtractor.candle(endingAt: Date(timeIntervalSince1970: 180), in: bars)).close == 2)
        #expect(FeatureExtractor.candle(endingAt: Date(timeIntervalSince1970: 600), in: bars) == nil)
    }

    @Test func contextOnlyIndicatorsNeverCount() {
        var model = PredictionModel.starting(excluding: [])
        model.weights[FeatureKey.emaTrend.rawValue] = 5
        #expect(!FeatureKey.emaTrend.isBaseInput)
        #expect(model.weight(for: .emaTrend) == 0)
        #expect(model.contributions([.emaTrend: 2]).isEmpty)
    }

    @Test func excludedFeaturesAreIgnored() {
        let model = PredictionModel.starting(excluding: [])
        let p = model.probabilityUp([.kalshiImplied: 3], excluding: [.kalshiImplied])
        #expect(abs(p - 0.5) < 1e-9)
    }

    @Test func historicalFeaturesRequireContiguousCandlesUpToTheOpen() throws {
        let open = Date(timeIntervalSince1970: 200 * 60)
        let candles = (0..<200).map { i in
            let c = 80_000 + sin(Double(i) / 4) * 30
            return Candle(time: Date(timeIntervalSince1970: Double(i) * 60), open: c, high: c + 5, low: c - 5, close: c, volume: 1)
        }
        let features = try #require(FeatureExtractor.historicalFeatures(candles: candles, at: open, strike: 80_000, minutesRemaining: 15))
        #expect(features[.headStart] != nil)
        #expect(features[.tickMomentum] == nil)   // ticks aren't in candles
        // A call one minute in needs the bar that ends one minute in.
        #expect(FeatureExtractor.historicalFeatures(candles: candles, at: open.addingTimeInterval(60), strike: 80_000,
                                                    minutesRemaining: 14) == nil)
        // The bar ending at the open is missing → no features.
        #expect(FeatureExtractor.historicalFeatures(candles: Array(candles.dropLast()), at: open, strike: 80_000, minutesRemaining: 15) == nil)
    }
}

struct ModelTrainerTests {

    /// Synthetic windows where `rsi` is genuinely predictive (with noise) and `momentum5m` is pure noise.
    private func samples(_ count: Int, seed: UInt64 = 42) -> [TrainingSample] {
        var rng = SeededGenerator(seed: seed)
        return (0..<count).map { i in
            let signal = Double.random(in: -2...2, using: &rng)
            let noise = Double.random(in: -2...2, using: &rng)
            let p = 1 / (1 + exp(-1.5 * signal))
            return TrainingSample(features: [.rsi: signal, .momentum5m: noise, .kalshiImplied: 0],
                                  wentUp: Double.random(in: 0...1, using: &rng) < p,
                                  time: Date(timeIntervalSince1970: Double(i) * 900))
        }
    }

    @Test func learnsAPredictiveFeature() {
        let data = samples(800)
        let model = ModelTrainer.fit(data, excluding: [], now: data.last!.time, regularization: 10)
        // The prior for RSI is slightly negative; the data says strongly positive.
        #expect(model.weight(for: .rsi) > 1)
        #expect(abs(model.weight(for: .momentum5m)) < 0.3)
        #expect(model.trainingCount == 800)
    }

    @Test func holdoutShowsImprovementOverStartingWeights() throws {
        let model = ModelTrainer.train(samples(800), excluding: [])
        let evaluation = try #require(model.evaluation)
        #expect(evaluation.holdoutCount == 320)          // newest 40%, in four blocks
        #expect(evaluation.folds == 4)
        #expect((evaluation.foldsWon ?? 0) >= 3)
        #expect(evaluation.accuracy > evaluation.priorAccuracy)
        #expect(evaluation.brierScore < evaluation.priorBrierScore)
        #expect(model.usesLearnedWeights)
        #expect(ModelTrainer.regularizationCandidates.contains(evaluation.regularization))
        #expect(model.weight(for: .rsi) > 0)
    }

    @Test func keepsStartingWeightsWithoutEnoughHistory() {
        let model = ModelTrainer.train(samples(30), excluding: [])
        #expect(!model.usesLearnedWeights)
        #expect(model.trainingCount == 30)
        #expect(model.evaluation == nil)
        #expect(model.weight(for: .rsi) == FeatureKey.rsi.priorWeight(marketAnchored: true))
    }

    @Test func keepsStartingWeightsWhenLearningDoesNotHelp() {
        // Without Kalshi odds, the starting weights know the head start.
        // Training windows: outcomes follow −RSI. Holdout windows: that relationship is
        // gone (RSI is noise) and the head start drives outcomes. The learned RSI
        // weight only hurts, so it's rejected.
        var rng = SeededGenerator(seed: 7)
        let data = (0..<400).map { i in
            let rsi = Double.random(in: -2...2, using: &rng)
            let z = Double.random(in: -2...2, using: &rng)
            let isHoldoutRegime = i >= 320
            let logit = isHoldoutRegime ? 1.2 * z : -2 * rsi
            return TrainingSample(features: isHoldoutRegime ? [.headStart: z, .rsi: rsi] : [.rsi: rsi],
                                  wentUp: Double.random(in: 0...1, using: &rng) < 1 / (1 + exp(-logit)),
                                  time: Date(timeIntervalSince1970: Double(i) * 900))
        }
        let model = ModelTrainer.train(data, excluding: [.kalshiImplied])
        #expect(!model.usesLearnedWeights)
        #expect(model.weight(for: .rsi) == FeatureKey.rsi.priorWeight(marketAnchored: false))
        #expect(model.trainingCount == 400)
    }

    @Test func fewSamplesStayNearPriors() {
        let model = ModelTrainer.fit(Array(samples(5)), excluding: [], now: Date(timeIntervalSince1970: 5 * 900))
        #expect(abs(model.weight(for: .headStart) - FeatureKey.headStart.priorWeight(marketAnchored: true)) < 1e-6)
        #expect(abs(model.weight(for: .rsi) - FeatureKey.rsi.priorWeight(marketAnchored: true)) < 0.5)
    }

    @Test func excludedFeatureKeepsPrior() {
        let model = ModelTrainer.fit(samples(200), excluding: [.rsi], now: Date(timeIntervalSince1970: 200 * 900))
        #expect(model.weight(for: .rsi) == FeatureKey.rsi.priorWeight(marketAnchored: true))
    }

    @Test func marketAnchoredTrainingSkipsWindowsWithoutOdds() {
        let withOdds = samples(100)
        let withoutOdds = withOdds.map { TrainingSample(features: [.rsi: $0.features[.rsi] ?? 0], wentUp: $0.wentUp, time: $0.time) }
        #expect(ModelTrainer.train(withOdds + withoutOdds, excluding: []).trainingCount == 100)
        #expect(ModelTrainer.train(withOdds + withoutOdds, excluding: [.kalshiImplied]).trainingCount == 200)
    }

    @Test func trialPromotesAGenuinelyPredictiveContextSignal() throws {
        // The EMA trend (a context signal) truly drives outcomes here; the base inputs are noise.
        var rng = SeededGenerator(seed: 11)
        let data = (0..<1500).map { i in
            let macd = Double.random(in: -2...2, using: &rng)
            return TrainingSample(features: [.kalshiImplied: 0, .emaTrend: macd,
                                             .rsi: Double.random(in: -2...2, using: &rng)],
                                  wentUp: Double.random(in: 0...1, using: &rng) < 1 / (1 + exp(-1.2 * macd)),
                                  time: Date(timeIntervalSince1970: Double(i) * 900))
        }
        let model = ModelTrainer.train(data, excluding: [])
        let trial = try #require(model.trial(for: .emaTrend))
        #expect(trial.isSignificantGain)
        #expect(!model.isActive(.emaTrend))   // a trial alone doesn't promote; the engine needs a streak
        // A noise context signal shouldn't win.
        let noise = try #require(model.trial(for: .stochastic))
        #expect(!noise.hasEnoughData)     // not present in these samples at all
    }

    @Test func bonferroniRaisesTheBarForSeveralSignals() {
        #expect(abs(ModelTrainer.zScore(forTests: 1) - 1.96) < 0.01)
        #expect(abs(ModelTrainer.zScore(forTests: 6) - 2.64) < 0.01)
    }

    @Test func trialCountsOnlyOnFreshWindows() throws {
        var rng = SeededGenerator(seed: 11)
        let data = (0..<1500).map { i in
            let ema = Double.random(in: -2...2, using: &rng)
            return TrainingSample(features: [.kalshiImplied: 0, .emaTrend: ema],
                                  wentUp: Double.random(in: 0...1, using: &rng) < 1 / (1 + exp(-1.2 * ema)),
                                  time: Date(timeIntervalSince1970: Double(i) * 900))
        }
        // First result: judged on the newest 20% (300 windows) and counted, marked at 1500.
        let first = try #require(ModelTrainer.train(data, excluding: []).trial(for: .emaTrend))
        #expect(first.counted == true && first.mark == 1500 && first.windows == 300)
        // 100 windows later: shown, but not counted — those windows were already judged.
        let soon = try #require(ModelTrainer.train(data, excluding: [], lastTrialMarks: ["emaTrend": 1400]).trial(for: .emaTrend))
        #expect(soon.counted == false && !soon.counts)
        // 250 fresh windows: judged on exactly those, and counted.
        let later = try #require(ModelTrainer.train(data, excluding: [], lastTrialMarks: ["emaTrend": 1250]).trial(for: .emaTrend))
        #expect(later.counted == true && later.windows == 250 && later.mark == 1500)
    }

    @Test func oneLuckyBlockDoesNotSwitchToLearnedWeights() throws {
        // RSI drives outcomes before the walk-forward stretch (so a weight is learned),
        // reverses in the first three blocks (so it hurts there), and returns only in the
        // last block. One winning block out of four mustn't switch the model over.
        var rng = SeededGenerator(seed: 5)
        let data = (0..<1000).map { i in
            let rsi = Double.random(in: -2...2, using: &rng)
            let logit = (i < 600 || i >= 900) ? 2 * rsi : -1.5 * rsi
            return TrainingSample(features: [.kalshiImplied: 0, .rsi: rsi],
                                  wentUp: Double.random(in: 0...1, using: &rng) < 1 / (1 + exp(-logit)),
                                  time: Date(timeIntervalSince1970: Double(i) * 900))
        }
        let model = ModelTrainer.train(data, excluding: [])
        let evaluation = try #require(model.evaluation)
        #expect(evaluation.folds == 4)
        #expect(!model.usesLearnedWeights)
    }

    @Test func promotedSignalsAreUsedByTheModel() {
        let model = PredictionModel.starting(excluding: [], promoted: [.emaTrend])
        #expect(model.isActive(.emaTrend))
        #expect(model.activeKeys.contains(.emaTrend))
        var fitted = ModelTrainer.fit(samples(300).map { s in
            TrainingSample(features: s.features.merging([.emaTrend: s.features[.rsi] ?? 0]) { a, _ in a },
                           wentUp: s.wentUp, time: s.time)
        }, excluding: [], promoted: [.emaTrend], now: Date(timeIntervalSince1970: 300 * 900), regularization: 10)
        #expect(fitted.isActive(.emaTrend))
        #expect(fitted.weight(for: .emaTrend) != 0)
        fitted.promoted = []
        #expect(fitted.weight(for: .emaTrend) == 0)
    }

    @Test func solvesLinearSystem() throws {
        let x = try #require(ModelTrainer.solve([[2, 1], [1, 3]], [3, 5]))
        #expect(abs(x[0] - 0.8) < 1e-9 && abs(x[1] - 1.4) < 1e-9)
    }
}

/// Deterministic RNG so the trainer tests are repeatable (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct CandlePatternTests {

    /// Builds contiguous 1-minute candles from (open, high, low, close) tuples.
    private func candles(_ ohlc: [(Double, Double, Double, Double)]) -> [Candle] {
        ohlc.enumerated().map { i, c in
            Candle(time: Date(timeIntervalSince1970: Double(i) * 60), open: c.0, high: c.1, low: c.2, close: c.3, volume: 0)
        }
    }

    private let downtrend: [(Double, Double, Double, Double)] = [
        (110, 111, 105, 106), (106, 107, 101, 102), (102, 103, 97, 98), (98, 99, 93, 94),
    ]
    private let uptrend: [(Double, Double, Double, Double)] = [
        (90, 95, 89, 94), (94, 99, 93, 98), (98, 103, 97, 102), (102, 107, 101, 106),
    ]

    private func primary(_ ohlc: [(Double, Double, Double, Double)]) throws -> CandlePattern {
        try #require(CandlePatterns.analyze(candles(ohlc))?.primary)
    }

    @Test func hammerAfterDowntrend() throws {
        let p = try primary(downtrend + [(93, 94.2, 85, 94)])
        #expect(p.name == "Hammer")
        #expect(p.bias == .bullish)
    }

    @Test func sameShapeAfterUptrendIsHangingMan() throws {
        let p = try primary(uptrend + [(107, 108.2, 99, 108)])
        #expect(p.name == "Hanging Man")
        #expect(p.bias == .bearish)
    }

    @Test func shootingStarAfterUptrend() throws {
        let p = try primary(uptrend + [(107, 115, 106.8, 106)])
        #expect(p.name == "Shooting Star")
    }

    @Test func doji() throws {
        #expect(try primary([(100, 103, 97, 100.2)]).name == "Doji")
    }

    @Test func bullishEngulfingIsStrongAfterDowntrend() throws {
        let p = try primary(downtrend + [(94, 95, 90, 91), (90, 97, 89.5, 96)])
        #expect(p.name == "Bullish Engulfing")
        #expect(p.strength == 3)
    }

    @Test func bearishEngulfing() throws {
        #expect(try primary(uptrend + [(106, 109, 105, 108), (109, 109.5, 103, 104)]).name == "Bearish Engulfing")
    }

    @Test func morningStar() throws {
        let p = try primary(downtrend + [(94, 94.5, 86, 87), (86.5, 88, 85.5, 87), (87, 93, 86.8, 92.5)])
        #expect(p.name == "Morning Star")
        #expect(p.candleCount == 3)
    }

    @Test func threeWhiteSoldiers() throws {
        let p = try primary([(100, 104.5, 99.8, 104), (102, 107.5, 101.8, 107), (105, 110.5, 104.8, 110)])
        #expect(p.name == "Three White Soldiers")
    }

    @Test func trendNeedsThreePriorCandles() {
        #expect(CandlePatterns.priorTrend(candles([(100, 101, 99, 100)])) == .sideways)
        #expect(CandlePatterns.priorTrend(candles(uptrend)) == .up)
        #expect(CandlePatterns.priorTrend(candles(downtrend)) == .down)
    }

    @Test func onlyTheContiguousTailIsAnalyzed() {
        var gapped = candles(downtrend + [(93, 94.2, 85, 94)])
        // Move the last candle two minutes later: the bot missed a minute.
        let last = gapped.removeLast()
        gapped.append(Candle(time: last.time.addingTimeInterval(60), open: last.open, high: last.high,
                             low: last.low, close: last.close, volume: 0))
        #expect(CandlePatterns.contiguousTail(gapped).count == 1)
    }
}

struct WindowProjectionTests {

    private let open = Date(timeIntervalSince1970: 0)
    private var close: Date { open.addingTimeInterval(900) }

    @Test func forecastIsTheCurrentPriceAndTheTrendIsDescriptive() throws {
        // +$1 per second for the first 5 minutes.
        let samples = (0...300).map { (time: open.addingTimeInterval(Double($0)), price: 1000 + Double($0)) }
        let projection = try #require(WindowProjection.fit(samples, open: open, close: close))
        #expect(abs(projection.slopePerSecond - 1) < 1e-9)
        // The forecast does not extend the trend: it's the latest price.
        #expect(projection.forecastSettlement == 1300)
        #expect(abs(projection.trendValue(at: 300) - 1300) < 1e-6)
        #expect(projection.fitStart == 0 && projection.fitEnd == 300)
        #expect(projection.probabilityUp(strike: 1000, secondsRemaining: 600) > 0.5)
    }

    @Test func ignoresTicksOutsideTheWindowAndNeedsEnoughData() {
        let before = (0..<100).map { (time: open.addingTimeInterval(Double(-100 + $0)), price: 5.0) }
        let fewInside = (0..<20).map { (time: open.addingTimeInterval(Double($0)), price: 5.0) }
        #expect(WindowProjection.fit(before + fewInside, open: open, close: close) == nil)
    }

    @Test func closeRangeNarrowsAsTheWindowRunsDown() {
        let projection = WindowProjection(slopePerSecond: 0, intercept: 0, forecastSettlement: 0, volatilityPerRootSecond: 1)
        let early = projection.settlementSigma(secondsRemaining: 840)
        let late = projection.settlementSigma(secondsRemaining: 120)
        #expect(late < early)
        #expect(projection.settlementSigma(secondsRemaining: 0) == 0)
        // 60s left: only ⅓ of a minute's variance.
        #expect(abs(projection.settlementSigma(secondsRemaining: 60) - 20.0.squareRoot()) < 1e-9)
    }

    @Test func linearFitRecoversALine() throws {
        let fit = try #require(Indicators.linearFit(xs: [0, 1, 2, 3], ys: [5, 7, 9, 11]))
        #expect(abs(fit.slope - 2) < 1e-9 && abs(fit.intercept - 5) < 1e-9)
        #expect(Indicators.linearFit(xs: [1, 1], ys: [2, 3]) == nil)
    }
}

struct ReversalRiskTests {

    private func inputs(price: Double, seconds: TimeInterval = 600, soFar: Double? = nil,
                        high: Double? = nil, low: Double? = nil) -> ReversalRisk.Inputs {
        .init(price: price, strike: 100, secondsRemaining: seconds, volatility: 1,
              settlementAverageSoFar: soFar, windowHigh: high, windowLow: low)
    }

    @Test func sittingOnTheTargetIsACoinFlip() {
        let risk = ReversalRisk.assess(inputs(price: 100))
        #expect(abs(risk.flipProbability - 0.5) < 1e-9)
        #expect(risk.level == .high)
    }

    @Test func levelsFollowTheActualChanceOfLosing() {
        // 10%, 25% and 40% flip chances: Low, Moderate, High — no doubling.
        func level(_ flip: Double) -> ReversalRisk.Level {
            ReversalRisk(currentlyUp: true, cushion: 1, cushionSigma: 1, flipProbability: flip,
                         breakoutUpProbability: nil, breakoutDownProbability: nil, factors: []).level
        }
        #expect(level(0.10) == .low)
        #expect(level(0.25) == .moderate)
        #expect(level(0.40) == .high)
    }

    @Test func trackingErrorWidensTheUncertaintyNearTheTarget() {
        let exact = SettlementOdds.estimate(price: 103, strike: 100, secondsRemaining: 70, volatility: 0.2)
        let noisy = SettlementOdds.estimate(price: 103, strike: 100, secondsRemaining: 70, volatility: 0.2, priceUncertainty: 4)
        #expect(noisy.sigma > exact.sigma)
        #expect(noisy.probabilityUp < exact.probabilityUp)   // a $3 cushion is less sure with ±$4 of index error
    }

    @Test func kalshiPriceIsShownAndBlendedOnlyWhenCalibrated() {
        var input = inputs(price: 105)
        input.kalshiYesMid = 0.8
        let plain = ReversalRisk.assess(input)
        #expect(plain.kalshiFlipProbability.map { abs($0 - 0.2) < 1e-9 } == true)
        #expect(!plain.blendsKalshi)
        // A calibration that trusts Kalshi completely: logit p = logit(Kalshi's flip).
        input.calibration = RiskCalibration(flip: nil, blend: [0, 0, 1], breakout: nil, volatilityHalfLife: nil,
                                            evaluation: .init(), windows: 1000, fittedAt: .now)
        let blended = ReversalRisk.assess(input)
        #expect(blended.blendsKalshi)
        #expect(abs(blended.flipProbability - 0.2) < 1e-6)
    }

    @Test func biggerCushionAndLessTimeMeanLessRisk() {
        let near = ReversalRisk.assess(inputs(price: 105))
        let far = ReversalRisk.assess(inputs(price: 160))
        let late = ReversalRisk.assess(inputs(price: 105, seconds: 90))
        #expect(far.flipProbability < near.flipProbability)
        #expect(late.flipProbability < near.flipProbability)
        #expect(far.level == .low)
        #expect(near.currentlyUp)
    }

    @Test func tailsAreRaisedMidRangeIsUnchanged() {
        // Backtest: raw 0.4% flipped 1.0% of the time; raw 3.4% flipped 5.6%.
        #expect(SettlementOdds.calibratedFlip(raw: 0.004) > 0.006)
        #expect(SettlementOdds.calibratedFlip(raw: 0.034) > 0.045)
        #expect(SettlementOdds.calibratedFlip(raw: 0.30) == 0.30)
        #expect(SettlementOdds.calibratedFlip(raw: 0.5) == 0.5)
        // Monotonic through the blend.
        let grid = stride(from: 0.001, through: 0.5, by: 0.001).map(SettlementOdds.calibratedFlip(raw:))
        #expect(zip(grid, grid.dropFirst()).allSatisfy { $0 <= $1 + 1e-12 })
    }

    @Test func lockedSettlementMinuteNarrowsTheOdds() {
        // 30s left, the first half of the settlement minute averaged 110, price now 100:
        // the expected settlement is 105 — still Up — even though price is on the target.
        let odds = SettlementOdds.estimate(price: 100, strike: 100, secondsRemaining: 30, volatility: 1, settlementAverageSoFar: 110)
        #expect(abs(odds.expected - 105) < 1e-9)
        #expect(odds.probabilityUp > 0.95)
        let risk = ReversalRisk.assess(inputs(price: 100, seconds: 30, soFar: 110))
        #expect(risk.currentlyUp)
        #expect(risk.factors.contains { $0.title == "Settlement average underway" })
    }

    @Test func breakoutIsCertainAtTheLevelAndFadesWithDistance() {
        #expect(ReversalRisk.breakoutProbability(distance: 0, volatility: 1, secondsRemaining: 300) == 1)
        let close = ReversalRisk.breakoutProbability(distance: 5, volatility: 1, secondsRemaining: 300)
        let far = ReversalRisk.breakoutProbability(distance: 60, volatility: 1, secondsRemaining: 300)
        #expect(close > far)
        #expect(far < 0.05)
        // Calibrated below the raw reflection estimate in the middle (backtest: 47% → 36%).
        let raw = 2 * Indicators.normalCDF(-17.3 / 300.0.squareRoot())
        #expect(ReversalRisk.breakoutProbability(distance: 17.3, volatility: 1, secondsRemaining: 300) < raw)
        let risk = ReversalRisk.assess(inputs(price: 105, high: 110, low: 95))
        #expect(risk.breakoutUpProbability != nil && risk.breakoutDownProbability != nil)
    }

    @Test func countsTargetCrossings() {
        #expect(ReversalRisk.crossings(of: [99, 101, 100, 102, 98, 97, 103], strike: 100) == 3)
    }
}

struct IndicatorGuideTests {

    @Test func effectInPointsIsTheShiftFromThisContribution() {
        // An indicator contributing logit(0.6) on its own moved P(up) from 50% to 60%.
        let logit = log(0.6 / 0.4)
        #expect(abs(IndicatorEffect.points(probabilityUp: 0.6, contribution: logit) - 10) < 1e-9)
        #expect(IndicatorEffect.points(probabilityUp: 0.7, contribution: 0) == 0)
    }

    @Test func displayValuesUndoTheNormalization() {
        #expect(FeatureKey.rsi.displayValue(1) == "65")
        #expect(FeatureKey.kalshiImplied.displayValue(0) == "50%")
        #expect(FeatureKey.bollinger.displayValue(1) == "100%")
    }

    @Test func interpretationsReadTheValue() {
        #expect(FeatureKey.rsi.interpretation(1.5).hasPrefix("Overbought"))
        #expect(FeatureKey.headStart.interpretation(-0.8).contains("below the target"))
        #expect(FeatureKey.kalshiImplied.interpretation(log(0.7 / 0.3)).contains("Up at 70%"))
    }

    @Test func effectDescriptionsExplainWhyAnIndicatorIsOrIsntMovingTheCall() {
        let market = PredictionModel.starting(excluding: [])
        #expect(IndicatorEffect.describe(.emaTrend, model: market, excluded: [], probabilityUp: 0.5, contribution: nil, kalshiYes: nil)
            .contains("Not used by the model"))
        #expect(IndicatorEffect.describe(.kalshiImplied, model: market, excluded: [], probabilityUp: 0.6, contribution: 0.4, kalshiYes: 0.6)
            .contains("anchor"))
        #expect(IndicatorEffect.describe(.rsi, model: market, excluded: [], probabilityUp: 0.6, contribution: 0, kalshiYes: 0.6)
            .contains("weight is 0"))

        var learned = market
        learned.usesLearnedWeights = true
        learned.weights[FeatureKey.rsi.rawValue] = 0.5
        #expect(IndicatorEffect.describe(.rsi, model: learned, excluded: [], probabilityUp: 0.6, contribution: 0.3, kalshiYes: 0.6)
            .contains("toward Up"))
    }
}

struct SemanticVersionTests {

    @Test func parsesValidVersions() throws {
        let v = try #require(SemanticVersion("1.2.3-beta.2+build.7"))
        #expect((v.major, v.minor, v.patch) == (1, 2, 3))
        #expect(v.preRelease == ["beta", "2"])
        #expect(v.buildMetadata == ["build", "7"])
        #expect(v.description == "1.2.3-beta.2+build.7")
    }

    @Test func rejectsInvalidVersions() {
        for bad in ["1.0", "1.0.0.0", "01.0.0", "1.0.0-", "1.0.0-01", "1.a.0", "", "1.0.0+"] {
            #expect(SemanticVersion(bad) == nil, "\(bad) should be rejected")
        }
    }

    @Test func ordersBySpecPrecedence() throws {
        // The example ordering from SemVer §11.
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
                       "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0"]
        let versions = try ordered.map { try #require(SemanticVersion($0)) }
        for (a, b) in zip(versions, versions.dropFirst()) {
            #expect(a < b, "\(a) should precede \(b)")
        }
    }

    @Test func buildMetadataDoesNotAffectPrecedence() throws {
        #expect(try #require(SemanticVersion("1.0.0+a")) == #require(SemanticVersion("1.0.0+b")))
    }

    @Test func appMarketingVersionIsSemantic() {
        #expect(AppVersion.current.semantic != nil, "MARKETING_VERSION must be MAJOR.MINOR.PATCH")
    }
}

struct StrategyAdvisorTests {

    @Test func kalshiTakerFeeRoundsUpToTheCent() {
        #expect(KalshiFees.taker(price: 0.5) == 0.02)     // 0.0175 → 2¢
        #expect(KalshiFees.taker(price: 0.9) == 0.01)     // 0.0063 → 1¢
    }

    @Test func standsAsideWhenFairValueMatchesThePrice() {
        let advice = StrategyAdvisor.advise(fairUp: 0.60, yesBid: 0.59, yesAsk: 0.61, secondsRemaining: 600)
        #expect(advice.action == .standAside)
        #expect(advice.signals.filter { $0.kind == .entry }.isEmpty)
        #expect(advice.justification.contains("no edge") || advice.headline.contains("no edge"))
    }

    @Test func entersWhenTheEdgeClearsFeesAndMargin() throws {
        let advice = StrategyAdvisor.advise(fairUp: 0.75, yesBid: 0.60, yesAsk: 0.62, secondsRemaining: 600)
        #expect(advice.action == .buyYes)
        let entry = try #require(advice.signals.first { $0.kind == .entry })
        #expect(entry.isYes)
        #expect(entry.justification.contains("75%"))
        #expect(try #require(advice.edgeYes) >= StrategyAdvisor.minimumEdge)
    }

    @Test func buysNoWhenDownIsUnderpriced() {
        let advice = StrategyAdvisor.advise(fairUp: 0.25, yesBid: 0.40, yesAsk: 0.42, secondsRemaining: 600)
        #expect(advice.action == .buyNo)
    }

    @Test func exitsWhenSellingIsWorthAsMuchAsHolding() {
        // Yes bid 80¢ − 1¢ fee = 79¢ ≥ fair 78¢ − 1¢ → sell Yes.
        let advice = StrategyAdvisor.advise(fairUp: 0.78, yesBid: 0.80, yesAsk: 0.81, secondsRemaining: 300)
        #expect(advice.signals.contains { $0.kind == .exit && $0.isYes })
    }

    @Test func noNewEntriesDuringTheSettlementMinute() {
        let advice = StrategyAdvisor.advise(fairUp: 0.95, yesBid: 0.60, yesAsk: 0.62, secondsRemaining: 30)
        #expect(advice.action == .standAside)
        #expect(!advice.signals.contains { $0.kind == .entry })
    }

    @Test func overboughtRSILeansDown() {
        #expect(FeatureKey.rsi.lean(1.5) < 0)      // RSI 72.5
        #expect(FeatureKey.rsi.lean(0.5) > 0)      // RSI 57.5, leaning bullish
        #expect(FeatureKey.momentum5m.lean(-1) < 0)
    }
}

struct LivePriceFeedTests {
    @Test func farOffQuoteIsDroppedAndExtremesTrimmed() throws {
        // Seven books within ~$36, plus Bitfinex-style +$150.
        let mids = [77_496.0, 77_507.6, 77_510.6, 77_516.4, 77_525.0, 77_532.5, 77_531.0, 77_680.0]
        let composite = try #require(LivePriceFeed.trimmedMean(mids))
        #expect(composite.sources == 7)
        // Mean of the five middle in-line books (lowest and highest trimmed).
        let core = [77_507.6, 77_510.6, 77_516.4, 77_525.0, 77_531.0]
        #expect(abs(composite.price - core.reduce(0, +) / 5) < 1e-6)
    }

    @Test func booksThirtyDollarsApartAllCount() throws {
        // Oct 31: Coinbase sat $36 below Crypto.com; both are good books.
        let composite = try #require(LivePriceFeed.trimmedMean([77_496, 77_510, 77_532]))
        #expect(composite.sources == 3)
    }

    @Test func trimmedMeanMovesWhenAnyInLineExchangeMoves() throws {
        let before = try #require(LivePriceFeed.trimmedMean([80_820, 80_822, 80_824, 80_826, 80_828]))
        let after = try #require(LivePriceFeed.trimmedMean([80_820, 80_822, 80_825, 80_826, 80_828]))
        #expect(after.price > before.price)
    }

    @Test func tenSources() {
        #expect(LivePriceFeed.sourceCount == 10)
    }

    @Test func parsesTheUSDCBooks() {
        let okx = Data(#"{"code":"0","data":[{"instId":"BTC-USDC","askPx":"76941.8","bidPx":"76941.7"}]}"#.utf8)
        let okxQuote = CompositePriceClient.Exchange.okxUSDC.quote(from: okx)
        #expect(okxQuote?.bid == 76941.7 && okxQuote?.ask == 76941.8)
        let kucoin = Data(#"{"code":"200000","data":{"bestBid":"76936.2","bestAsk":"76936.3","price":"76951.4"}}"#.utf8)
        let kucoinQuote = CompositePriceClient.Exchange.kucoinUSDC.quote(from: kucoin)
        #expect(kucoinQuote?.bid == 76936.2 && kucoinQuote?.ask == 76936.3)
        #expect(LivePriceFeed.polled.count == 7)
    }
}

struct KalshiDecodingTests {

    @Test func tickerFollowsEasternCloseTime() {
        // Real tickers: the 02:45–03:00 UTC window on Oct 28 closes 23:00 EDT on Oct 27.
        let close = Date(timeIntervalSince1970: 1793156400)   // 2026-10-28T03:00:00Z
        #expect(KalshiClient.ticker(closingAt: close) == "KXBTC15M-26OCT272300-00")
        #expect(KalshiClient.ticker(closingAt: close.addingTimeInterval(15 * 60)) == "KXBTC15M-26OCT272315-15")
    }

    @Test func decodesSettledMarket() throws {
        let json = """
        {"ticker":"KXBTC15M-26OCT262300-00","status":"finalized","open_time":"2026-10-27T02:45:00Z",
         "close_time":"2026-10-27T03:00:00Z","floor_strike":79809.93,"yes_bid_dollars":"0.0000",
         "yes_ask_dollars":"1.0000","expiration_value":"79672.23","result":"no"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let market = try decoder.decode(KalshiMarket.self, from: Data(json.utf8))
        #expect(market.floorStrike == 79809.93)
        #expect(market.settlementValue == 79672.23)
        #expect(market.settledUp == false)
        #expect(market.yesMid == 0.5)
    }
}

struct AccuracyStatsTests {

    @Test func computesAccuracyBrierAndStreaks() throws {
        let stats = AccuracyStats([
            .init(probabilityUp: 0.7, actualUp: true, marketYesMid: 0.6),
            .init(probabilityUp: 0.4, actualUp: true, marketYesMid: 0.6),
            .init(probabilityUp: 0.52, actualUp: true, marketYesMid: 0.4),
            .init(probabilityUp: 0.45, actualUp: false, marketYesMid: nil),
        ])
        #expect(stats.total == 4)
        #expect(stats.correct == 3)
        #expect(stats.currentStreak == 2)
        #expect(stats.longestWinStreak == 2)
        #expect(stats.longestLosingStreak == 1)
        #expect(stats.marketTotal == 3)
        #expect(stats.marketCorrect == 2)
        #expect(try #require(stats.brierScore) < 0.25)
        #expect(stats.buckets.first { $0.label == "70%+" }?.correct == 1)
    }

    @Test func pairedEdgeAgainstTheMarket() throws {
        // Bot and market agree except one window, where the bot is right.
        let stats = AccuracyStats([
            .init(probabilityUp: 0.6, actualUp: true, marketYesMid: 0.6),
            .init(probabilityUp: 0.4, actualUp: false, marketYesMid: 0.4),
            .init(probabilityUp: 0.6, actualUp: true, marketYesMid: 0.4),
            .init(probabilityUp: 0.4, actualUp: true, marketYesMid: 0.4),
        ])
        let edge = try #require(stats.edgeVsMarket)
        #expect(edge.windows == 4)
        #expect(abs(edge.accuracy - 0.25) < 1e-9)
        #expect(edge.brier > 0)
        #expect(!edge.isSignificant)   // one window of difference is noise
    }

    @Test func confidentCallsAreCountedSeparately() {
        let stats = AccuracyStats([
            .init(probabilityUp: 0.80, actualUp: true, marketYesMid: 0.70),   // confident, right
            .init(probabilityUp: 0.30, actualUp: true, marketYesMid: 0.30),   // confident, wrong
            .init(probabilityUp: 0.55, actualUp: false, marketYesMid: 0.55),  // not confident
        ])
        #expect(stats.confidentTotal == 2)
        #expect(stats.confidentCorrect == 1)
        #expect(stats.marketConfidentTotal == 2)
        #expect(stats.marketConfidentCorrect == 1)
    }

    @Test func expectedCorrectSumsConfidence() {
        let stats = AccuracyStats([
            .init(probabilityUp: 0.6, actualUp: false, marketYesMid: nil),
            .init(probabilityUp: 0.3, actualUp: false, marketYesMid: nil),
        ])
        #expect(abs(stats.expectedCorrect - 1.3) < 1e-9)
        #expect(abs(stats.expectedCorrectMargin - 1.96 * (0.24 + 0.21).squareRoot()) < 1e-9)
    }

    /// `correct` right and the rest wrong, every call at `confidence`.
    func stats(correct: Int, of total: Int, confidence: Double) -> AccuracyStats {
        AccuracyStats((0..<total).map { .init(probabilityUp: confidence, actualUp: $0 < correct, marketYesMid: nil) })
    }

    @Test func pathToTargetCountsCorrectCallsInARow() {
        // 5 of 10: (5 + x) / (10 + x) ≥ 0.7 → x ≥ 6.67 → 7.
        let path = stats(correct: 5, of: 10, confidence: 0.6).path(to: 0.7)
        #expect(path.correctInARow == 7)
        #expect(path.missesToSpare == 0)
        #expect(!path.isReached)
        #expect(path.expectedCalls == nil)  // calls average 60%, below the target
    }

    @Test func pathToTargetCountsMissesToSpareOnceReached() {
        // 9 of 10: 9 / (10 + m) ≥ 0.7 → m ≤ 2.86 → 2; exactly 7 of 10 counts as reached.
        #expect(stats(correct: 9, of: 10, confidence: 0.8).path(to: 0.7).missesToSpare == 2)
        #expect(stats(correct: 7, of: 10, confidence: 0.6).path(to: 0.7).isReached)
    }

    @Test func pathToTargetEstimatesCallsWhenConfidenceIsAboveIt() {
        // Gap 7 − 5 = 2 calls; closing at 0.8 − 0.7 = 0.1 per call → 20.
        #expect(stats(correct: 5, of: 10, confidence: 0.8).path(to: 0.7).expectedCalls == 20)
    }

    @Test func windowsNeededForMargin() {
        #expect(AccuracyStats.windowsNeeded(forMargin: 0.05) == 385)
    }
}

struct PerformanceBreakdownTests {
    /// 2026-10-28 00:00 ET (04:00 UTC).
    let midnightET = Date(timeIntervalSince1970: 1_793_160_000)

    func window(_ offsetHours: Double, bot: Double, market: Double, up: Bool) -> PerformanceBreakdown.Window {
        .init(openTime: midnightET.addingTimeInterval(offsetHours * 3600), probabilityUp: bot, marketYesMid: market, actualUp: up)
    }

    @Test func edgeIsPositiveWhenTheBotIsCloser() {
        let w = window(0, bot: 0.7, market: 0.6, up: true)
        #expect(abs(w.edge - (0.16 - 0.09)) < 1e-12)
        #expect(window(0, bot: 0.6, market: 0.7, up: true).edge < 0)
    }

    @Test func quotingKalshiIsExactlyEven() {
        // 0.145 vs. 0.145 + 1 ulp-ish noise: the squared errors differ only by rounding.
        #expect(window(0, bot: 0.145, market: 0.145 + 1e-16, up: false).edge == 0)
    }

    @Test func groupsByEasternDayAndHour() {
        let b = PerformanceBreakdown([
            window(-0.25, bot: 0.6, market: 0.6, up: true),   // 11:45 PM ET the day before
            window(2, bot: 0.7, market: 0.6, up: true),       // 2 AM
            window(2.25, bot: 0.7, market: 0.6, up: true),    // 2:15 AM
            window(14, bot: 0.4, market: 0.6, up: true),      // 2 PM: bot wrong, Kalshi right
        ])
        #expect(b.days.count == 2)
        #expect(b.days.map(\.windows) == [1, 3])
        #expect(b.hours.count == 24)
        #expect(b.hours[2].windows == 2)
        #expect(b.hours[2].verdict == .ahead)
        #expect(b.hours[14].verdict == .behind)
        #expect(b.hours[23].verdict == .even)
        #expect(b.cells.count == 3)  // 2:00 and 2:15 AM share a cell
        #expect(b.cumulative.count == 4)
    }

    @Test func accuracyDecidesTheVerdictBeforeBrier() {
        let p = PerformanceBreakdown.period([window(0, bot: 0.45, market: 0.55, up: true)], id: "x", label: "x")
        #expect(p.botCorrect == 0 && p.marketCorrect == 1)
        #expect(p.verdict == .behind)
    }

    @Test func periodDetailCountsUpsConfidenceAndDisagreements() {
        let p = PerformanceBreakdown.period([window(0, bot: 0.7, market: 0.6, up: true),
                                             window(1, bot: 0.2, market: 0.55, up: false),
                                             window(2, bot: 0.6, market: 0.4, up: true)], id: "x", label: "x")
        #expect(p.settledUp == 2)
        #expect(abs(p.meanConfidence - 0.7) < 1e-9)  // (0.7 + 0.8 + 0.6) / 3
        #expect(p.disagreements == 2)
    }

    @Test func recentFormTrendAppearsWithEnoughWindows() {
        let windows = (0..<40).map { i in window(Double(i) / 4, bot: i >= 16 ? 0.7 : 0.6, market: 0.65, up: true) }
        let b = PerformanceBreakdown(windows)
        let recent = b.trends.first { $0.title.hasPrefix("Last 24 windows") }
        #expect(recent?.kind == .favorable)
    }
}

struct TradingTimesTests {
    /// Wed 2026-10-28 00:00 ET.
    let wednesday = Date(timeIntervalSince1970: 1_793_160_000)

    func window(_ hours: Double, bot: Double) -> PerformanceBreakdown.Window {
        .init(openTime: wednesday.addingTimeInterval(hours * 3600), probabilityUp: bot, marketYesMid: 0.6, actualUp: true)
    }

    @Test func ranksDaysThenBlocksByEdge() {
        let b = PerformanceBreakdown([
            window(1, bot: 0.55),      // Wed 12–4 AM: behind Kalshi
            window(9, bot: 0.8),       // Wed 8 AM–12 PM: well ahead
            window(13, bot: 0.65),     // Wed 12–4 PM: slightly ahead
            window(24 + 2, bot: 0.62), // Thu 12–4 AM: slightly ahead
        ])
        #expect(b.tradingTimes.map(\.weekday) == [4, 5])  // Wednesday's mean edge is larger
        #expect(b.tradingTimes[0].blocks.map(\.label) == ["8 AM–12 PM", "12–4 PM", "12–4 AM"])
        #expect(b.tradingTimes[0].period.label == "Wednesday")
    }

    @Test func blockLabels() {
        #expect(PerformanceBreakdown.blockLabel(0) == "12–4 AM")
        #expect(PerformanceBreakdown.blockLabel(2) == "8 AM–12 PM")
        #expect(PerformanceBreakdown.blockLabel(3) == "12–4 PM")
        #expect(PerformanceBreakdown.blockLabel(5) == "8 PM–12 AM")
    }
}

struct WeeklyMonthlyTests {
    /// Wed 2026-10-28 00:00 ET.
    let wednesday = Date(timeIntervalSince1970: 1_793_160_000)

    @Test func groupsByMondayWeeksAndCalendarMonths() {
        let windows = [-3.0, 0, 4, 5].map { days in  // Sun Oct 25, Wed Oct 28, Sun Nov 1, Mon Nov 2
            PerformanceBreakdown.Window(openTime: wednesday.addingTimeInterval(days * 86_400 + 3600),
                                        probabilityUp: 0.6, marketYesMid: 0.6, actualUp: true)
        }
        let b = PerformanceBreakdown(windows)
        #expect(b.weeks.map(\.label) == ["Week of Oct 19", "Week of Oct 26", "Week of Nov 2"])
        #expect(b.weeks.map(\.windows) == [1, 2, 1])
        #expect(b.months.map(\.label) == ["October 2026", "November 2026"])
        #expect(b.months.map(\.windows) == [2, 2])
    }
}

struct CompositeSafetyTests {
    @Test func twoFarApartQuotesFallBackToTheirMedian() throws {
        let composite = try #require(LivePriceFeed.trimmedMean([80_000, 80_040]))
        #expect(composite.price == 80_020)
        #expect(composite.price.isFinite)
    }
}

struct RemovedIndicatorTests {
    @Test func uninformativeIndicatorsAreGone() {
        let names = Set(FeatureKey.allCases.map(\.rawValue))
        for removed in ["macd", "volumeFlow", "orderBookImbalance", "perpPremium", "perpLead"] {
            #expect(!names.contains(removed))
        }
        #expect(FeatureKey(rawValue: "perpLead") == nil)  // stored values for it are skipped on decode
    }

    @Test func baseInputsAreTheInformativeFour() {
        #expect(Set(FeatureKey.allCases.filter(\.isBaseInput)) == [.kalshiImplied, .headStart, .momentum5m, .rsi])
    }
}

struct WindowExtremesTests {
    @Test func highAndLowComeFromInsideTheWindowOnly() throws {
        let open = Date(timeIntervalSince1970: 0), close = open.addingTimeInterval(900)
        let samples: [(time: Date, price: Double)] = [
            (open.addingTimeInterval(-5), 90_000),   // before the open: ignored
            (open.addingTimeInterval(10), 80_010),
            (open.addingTimeInterval(20), 80_050),
            (open.addingTimeInterval(30), .nan),     // invalid: ignored
            (open.addingTimeInterval(40), 79_990),
            (close, 70_000),                         // the next window: ignored
        ]
        let e = try #require(WindowChart.extremes(samples, from: open, to: close))
        #expect(e.high.price == 80_050 && e.high.time == open.addingTimeInterval(20))
        #expect(e.low.price == 79_990 && e.low.time == open.addingTimeInterval(40))
        #expect(WindowChart.extremes([], from: open, to: close) == nil)
    }
}

struct CallExplanationTests {
    private func inputs(predictedUp: Bool = true, spot: Double, settlement: Double?, kalshi: Double = 0.7) -> CallExplanation.Inputs {
        .init(predictedUp: predictedUp, probabilityUp: predictedUp ? 0.7 : 0.3, callDelaySeconds: 180,
              strike: 80_000, spotAtCall: spot, settlement: settlement,
              actualUp: settlement.map { $0 >= 80_000 }, kalshiYes: kalshi, kalshiBid: 0.69, kalshiAsk: 0.71,
              headStart: (spot - 80_000) / 60, contributions: [("Kalshi implied odds", 0.85)])
    }

    @Test func heldLeadIsExplainedAsCorrect() {
        let e = CallExplanation(inputs(spot: 80_060, settlement: 80_090))
        #expect(e.outcome == .correct)
        #expect(e.headline.hasPrefix("Correct"))
        #expect(e.points.contains { $0.title == "Why it worked" && $0.detail.contains("held to the close") })
    }

    @Test func reversalIsExplainedAsAMiss() {
        let e = CallExplanation(inputs(spot: 80_060, settlement: 79_950))
        #expect(e.outcome == .wrong)
        #expect(e.points.contains { $0.title == "Why it missed" && $0.detail.contains("reversal") })
        #expect(e.points.contains { $0.title == "After the call" && $0.helped == false })
    }

    @Test func pendingCallsSayNotSettled() {
        let e = CallExplanation(inputs(spot: 80_060, settlement: nil))
        #expect(e.outcome == .pending)
        #expect(e.headline.contains("not settled"))
    }

    @Test func closeFinishIsFlagged() {
        let e = CallExplanation(inputs(spot: 80_060, settlement: 80_004))
        #expect(e.points.contains { $0.detail.contains("very close finish") })
    }
}

struct ChartTagLayoutTests {
    @Test func overlappingTagsAreSpreadApartAndKeepTheirOrder() {
        let ys = ChartTag.layout([100, 104, 106], gap: 20, height: 300)
        #expect(ys[0] < ys[1] && ys[1] < ys[2])
        #expect(ys[1] - ys[0] >= 20 && ys[2] - ys[1] >= 20)
    }

    @Test func farApartTagsStayWhereTheyPoint() {
        #expect(ChartTag.layout([50, 200], gap: 20, height: 300) == [50, 200])
    }

    @Test func tagsStayInsideThePlot() {
        let ys = ChartTag.layout([295, 298, -40], gap: 20, height: 300)
        #expect(ys.allSatisfy { $0 >= 10 && $0 <= 290 })
        let sorted = ys.sorted()
        #expect(zip(sorted, sorted.dropFirst()).allSatisfy { $1 - $0 >= 20 - 1e-9 })
    }
}

struct TradingStyleTests {
    @Test func stricterStylesNeedMoreEdge() {
        // Fair 70% vs a 62¢ ask: about +7¢ after the fee.
        let conservative = StrategyAdvisor.advise(fairUp: 0.70, yesBid: 0.60, yesAsk: 0.62, secondsRemaining: 600, style: .conservative)
        let neutral = StrategyAdvisor.advise(fairUp: 0.70, yesBid: 0.60, yesAsk: 0.62, secondsRemaining: 600, style: .neutral)
        #expect(conservative.action == .standAside)
        #expect(neutral.action == .buyYes)
    }

    @Test func conservativeSkipsLongShotsAndLateEntries() {
        let longShot = StrategyAdvisor.advise(fairUp: 0.40, yesBid: 0.18, yesAsk: 0.20, secondsRemaining: 600, style: .conservative)
        #expect(!longShot.signals.contains { $0.kind == .entry })
        let late = StrategyAdvisor.advise(fairUp: 0.75, yesBid: 0.50, yesAsk: 0.52, secondsRemaining: 200, style: .conservative)
        #expect(late.action == .standAside)
        let aggressive = StrategyAdvisor.advise(fairUp: 0.75, yesBid: 0.50, yesAsk: 0.52, secondsRemaining: 200, style: .aggressive)
        #expect(aggressive.action == .buyYes)
    }

    @Test func reversalRiskAndTakeProfitExitsFollowTheStyle() {
        // Up is 70% from the price now: Yes loses 30% of the time.
        let conservative = StrategyAdvisor.advise(fairUp: 0.70, yesBid: 0.69, yesAsk: 0.71, secondsRemaining: 400,
                                                  style: .conservative, priceOddsUp: 0.70)
        #expect(conservative.signals.contains { $0.id == "exit-true-risk" })
        let aggressive = StrategyAdvisor.advise(fairUp: 0.70, yesBid: 0.69, yesAsk: 0.71, secondsRemaining: 400,
                                                style: .aggressive, priceOddsUp: 0.70)
        #expect(!aggressive.signals.contains { $0.id == "exit-true-risk" })
        let rich = StrategyAdvisor.advise(fairUp: 0.97, yesBid: 0.96, yesAsk: 0.97, secondsRemaining: 200, style: .neutral)
        #expect(rich.signals.contains { $0.id == "exit-true-profit" })
    }
}

struct MomentumStrengthTests {
    @Test func flatIsZeroOrdinaryIsAboutHalfExtremeNearsOne() {
        // σ over 180s with $1/√s volatility ≈ $13.4.
        #expect(ReversalRisk.momentumStrength(change: 0, volatility: 1, seconds: 180) == 0)
        let ordinary = ReversalRisk.momentumStrength(change: 9, volatility: 1, seconds: 180)   // ≈ 0.67σ
        #expect(ordinary > 0.4 && ordinary < 0.6)
        #expect(ReversalRisk.momentumStrength(change: -40, volatility: 1, seconds: 180) > 0.99)
    }

    @Test func directionAndLeaderAreReported() throws {
        let risk = ReversalRisk.assess(.init(price: 105, strike: 100, secondsRemaining: 400, volatility: 1, priceEarlier: 112))
        let m = try #require(risk.momentum)
        #expect(!m.up)
        #expect(!m.withLeader)   // falling while Up leads
        #expect(abs(m.change + 7) < 1e-9)
    }
}

struct LiveOnlyTrialTests {
    /// 2,000 windows; only the newest `live` have tick momentum, and there it truly drives outcomes.
    private func samples(live: Int) -> [TrainingSample] {
        var rng = SeededGenerator(seed: 7)
        return (0..<2000).map { i in
            let isLive = i >= 2000 - live
            let tick = Double.random(in: -2...2, using: &rng)
            var features: [FeatureKey: Double] = [.kalshiImplied: 0, .rsi: Double.random(in: -1...1, using: &rng)]
            if isLive { features[.tickMomentum] = tick }
            let p = isLive ? 1 / (1 + exp(-1.5 * tick)) : 0.5
            return TrainingSample(features: features, wentUp: Double.random(in: 0...1, using: &rng) < p,
                                  time: Date(timeIntervalSince1970: Double(i) * 900))
        }
    }

    @Test func liveOnlySignalIsTrialledOnItsOwnWindows() throws {
        let model = ModelTrainer.train(samples(live: 800), excluding: [])
        let trial = try #require(model.trial(for: .tickMomentum))
        #expect(trial.liveOnly == true)
        #expect(trial.liveWindows == 800)
        #expect(trial.hasEnoughData)
        #expect(trial.isSignificantGain)
    }

    @Test func tooFewLiveWindowsWaits() throws {
        let model = ModelTrainer.train(samples(live: 200), excluding: [])
        let trial = try #require(model.trial(for: .tickMomentum))
        #expect(trial.liveOnly == true)
        #expect(!trial.hasEnoughData)
        #expect(IndicatorEffect.trialSummary(.tickMomentum, model: model).contains("200 of the 500"))
    }
}

struct SourceStatusTests {
    @Test func statesMatchWhatTheAverageUses() {
        let mids: [(id: String, mid: Double)] = [("a", 77_496), ("b", 77_507.6), ("c", 77_510.6), ("d", 77_516.4),
                                                 ("e", 77_525), ("f", 77_532.5), ("g", 77_531), ("h", 77_680)]
        let result = LivePriceFeed.combine(mids)
        #expect(result.states["h"] == .outlier)
        #expect(result.states["a"] == .trimmed)   // lowest in-line
        #expect(result.states["f"] == .trimmed)   // highest in-line
        #expect(["b", "c", "d", "e", "g"].allSatisfy { result.states[$0] == .used })
        #expect(result.composite?.sources == 7)
    }
}

struct ExitPlanTests {
    private func market(price: Double, seconds: TimeInterval = 480) -> ExitPlan.Market {
        // Kalshi's quote matches the bot's odds at the current price (no gap), 2¢ spread.
        let up = SettlementOdds.estimate(price: price, strike: 80_000, secondsRemaining: seconds, volatility: 1.5).probabilityUp
        return .init(strike: 80_000, price: price, secondsRemaining: seconds, volatility: 1.5,
                     yesBid: up - 0.01, yesAsk: up + 0.01)
    }

    @Test func stopAndTakeProfitBracketThePriceForAYesCall() throws {
        let m = market(price: 80_010)
        let plan = try #require(ExitPlan.compute(calledUp: true, entry: 0.60, market: m, peakSale: nil, style: .neutral))
        let stop = try #require(plan.stop), profit = try #require(plan.takeProfit)
        #expect(stop < 80_010 && profit > 80_010)
        // Selling at the stop returns half the stake; at the take-profit, 80% of the way to the max.
        #expect(abs(ExitPlan.sale(at: stop, seconds: 480, calledUp: true, market: m) - 0.30) < 0.011)   // fees round to the cent
        #expect(abs(plan.takeProfitSale - (0.60 + 0.8 * (0.98 - 0.60))) < 1e-9)
        #expect(!plan.stopIsTrailing)
    }

    @Test func noCallMirrors() throws {
        let plan = try #require(ExitPlan.compute(calledUp: false, entry: 0.55, market: market(price: 79_990), peakSale: nil, style: .neutral))
        #expect(try #require(plan.stop) > 79_990)          // a No call loses as BTC rises
        #expect(try #require(plan.takeProfit) < 79_990)
    }

    @Test func trailingStopProtectsAnEarlierGain() throws {
        let m = market(price: 80_010)
        let plan = try #require(ExitPlan.compute(calledUp: true, entry: 0.50, market: m, peakSale: 0.80, style: .neutral))
        #expect(plan.stopIsTrailing)
        #expect(abs(plan.stopSale - 0.65) < 1e-9)          // keep half of the 30¢ peak gain
    }

    @Test func aSmallGainDoesNotStartTheTrailingStop() throws {
        // Reproduces the bug: a winning call up under a cent pulled the stop onto the price.
        let m = market(price: 79_987)
        let plan = try #require(ExitPlan.compute(calledUp: false, entry: 0.60, market: m, peakSale: 0.608, style: .neutral))
        #expect(!plan.stopIsTrailing)
        #expect(abs(plan.stopSale - 0.30) < 1e-9)          // the ordinary 50% stop-loss
        #expect(!plan.exitNow)
    }

    @Test func pastTheStopSaysExitNow() throws {
        let plan = try #require(ExitPlan.compute(calledUp: true, entry: 0.90, market: market(price: 79_980), peakSale: nil, style: .conservative))
        #expect(plan.exitNow)
    }
}

struct ChartLayerTests {
    @Test func hiddenListControlsEachLayer() {
        #expect(ChartLayer.isShown(.trend, hidden: ""))
        #expect(!ChartLayer.isShown(.trend, hidden: "exits,trend"))
        #expect(ChartLayer.isShown(.target, hidden: "exits,trend"))
    }

    @Test func everyTagBelongsToALayer() {
        for id in ["target", "settlement", "high", "low", "price", "projected", "trend", "takeProfit", "stop", "close"] {
            #expect(ChartLayer.forTag(id) != nil, "tag \(id) has no layer, so it couldn't be hidden")
        }
    }
}

struct ChartTagPlacementTests {
    let size = CGSize(width: 900, height: 300)

    @Test func labelsSitOffTheirLines() throws {
        let tag = ChartTag(id: "target", text: "Target $80,000.00", color: .white, value: 80_000, side: .leading, placement: .above)
        let placed = try #require(ChartTagPlacement.place([tag], anchors: ["target": 150], focus: nil, size: size)["target"])
        // The tag's bottom edge clears the line.
        #expect(placed.y + ChartTag.height / 2 <= 150 - ChartTagPlacement.lineClearance + 0.001)
    }

    @Test func centerLabelSlidesAwayFromTheNowDot() throws {
        let tag = ChartTag(id: "high", text: "▲ High $80,050.00 hit 10:07:23 AM · 18% chance of a new high",
                           color: .green, value: 80_050, side: .center, placement: .above)
        let dot = CGPoint(x: 450, y: 89)   // right where the centered label would sit
        let placed = try #require(ChartTagPlacement.place([tag], anchors: ["high": 100], focus: dot, size: size)["high"])
        let w = ChartTagPlacement.width(of: tag.text)
        let clearOfDot = abs(placed.x - dot.x) >= w / 2 + ChartTagPlacement.focusClearance
            || abs(placed.y - dot.y) >= ChartTag.height / 2 + ChartTagPlacement.focusClearance
        #expect(clearOfDot)
    }

    @Test func pinnedStackDropsToTheBottomWhenThePriceIsTopRight() throws {
        let tags = [ChartTag(id: "settlement", text: "Settlement avg", color: .secondary, value: nil, side: .trailing),
                    ChartTag(id: "price", text: "Now $80,000.00", color: .primary, value: nil, side: .trailing, rank: 1)]
        let top = ChartTagPlacement.place(tags, anchors: [:], focus: CGPoint(x: 100, y: 250), size: size)
        let bottom = ChartTagPlacement.place(tags, anchors: [:], focus: CGPoint(x: 800, y: 40), size: size)
        #expect(try #require(top["settlement"]).y < 50)
        #expect(try #require(bottom["price"]).y > 250)
        let settlementY = try #require(bottom["settlement"]).y, priceY = try #require(bottom["price"]).y
        #expect(settlementY < priceY)   // order kept
    }
}

struct CustomStopLossTests {
    @Test func customStopReplacesTheStyleDefault() throws {
        let up = SettlementOdds.estimate(price: 80_010, strike: 80_000, secondsRemaining: 480, volatility: 1.5).probabilityUp
        let m = ExitPlan.Market(strike: 80_000, price: 80_010, secondsRemaining: 480, volatility: 1.5,
                                yesBid: up - 0.01, yesAsk: up + 0.01)
        let style = try #require(ExitPlan.compute(calledUp: true, entry: 0.60, market: m, peakSale: nil, style: .neutral))
        let tight = try #require(ExitPlan.compute(calledUp: true, entry: 0.60, market: m, peakSale: nil, style: .neutral, maxLoss: 0.15))
        #expect(abs(style.stopSale - 0.30) < 1e-9)          // neutral default: risk 50%
        #expect(abs(tight.stopSale - 0.51) < 1e-9)          // custom: risk 15%
        let tightStop = try #require(tight.stop), styleStop = try #require(style.stop)
        #expect(tightStop > styleStop)   // a tighter stop sits closer to the price
    }
}

struct PositionEstimateTests {
    @Test func stakeBuysWholeContractsAndPricesEachOutcome() throws {
        let up = SettlementOdds.estimate(price: 80_010, strike: 80_000, secondsRemaining: 480, volatility: 1.5).probabilityUp
        let m = ExitPlan.Market(strike: 80_000, price: 80_010, secondsRemaining: 480, volatility: 1.5,
                                yesBid: up - 0.01, yesAsk: up + 0.01)
        let plan = try #require(ExitPlan.compute(calledUp: true, entry: 0.60, market: m, peakSale: nil, style: .neutral))
        let p = try #require(PositionEstimate.estimate(stake: 100, plan: plan, chanceRight: 0.62))
        // 60¢ + 2¢ fee = 62¢ a contract → 161 contracts for $100.
        #expect(p.contracts == 161)
        #expect(abs(p.cost - 161 * 0.62) < 1e-9)
        #expect(abs(p.profitIfRight - (161 - 161 * 0.62)) < 1e-9)
        #expect(p.profitIfWrong == -p.cost)
        #expect(abs(p.expectedProfit - (0.62 * 161 - p.cost)) < 1e-9)
        #expect(try #require(p.profitAtStop) < 0)
        #expect(try #require(p.profitAtTakeProfit) > 0)
        #expect(PositionEstimate.estimate(stake: 0.30, plan: plan, chanceRight: 0.62) == nil)   // under one contract
    }
}

struct CustomTakeProfitTests {
    private var market: ExitPlan.Market {
        let up = SettlementOdds.estimate(price: 80_010, strike: 80_000, secondsRemaining: 480, volatility: 1.5).probabilityUp
        return .init(strike: 80_000, price: 80_010, secondsRemaining: 480, volatility: 1.5, yesBid: up - 0.01, yesAsk: up + 0.01)
    }

    @Test func customGainSetsTheTakeProfit() throws {
        let plan = try #require(ExitPlan.compute(calledUp: true, entry: 0.50, market: market, peakSale: nil, style: .neutral,
                                                 takeProfitGain: 0.40))
        #expect(abs(plan.takeProfitSale - 0.70) < 1e-9)    // 50¢ + 40%
        #expect(plan.takeProfit != nil)
        #expect(!plan.takeProfitUnreachable)
    }

    @Test func unreachableGainDrawsNoLine() throws {
        let plan = try #require(ExitPlan.compute(calledUp: true, entry: 0.60, market: market, peakSale: nil, style: .neutral,
                                                 takeProfitGain: 1.00))
        #expect(plan.takeProfitUnreachable)                 // $1.20 > the ~98¢ max sale
        #expect(plan.takeProfit == nil)
    }
}

struct RecommendationFollowsTheCallTests {
    @Test func neverRecommendsBuyingAgainstTheCall() {
        // Call Down; fair value 20% Up vs a 10¢/11¢ Yes quote makes Yes look cheap.
        let advice = StrategyAdvisor.advise(fairUp: 0.20, yesBid: 0.10, yesAsk: 0.11, secondsRemaining: 400, calledUp: false)
        #expect(advice.action == .standAside)
        #expect(!advice.signals.contains { $0.kind == .entry })
        #expect(advice.headline.contains("against the call"))
    }

    @Test func stillRecommendsTheCalledSide() {
        // Call Down; No is cheap relative to fair value.
        let advice = StrategyAdvisor.advise(fairUp: 0.20, yesBid: 0.40, yesAsk: 0.42, secondsRemaining: 400, calledUp: false)
        #expect(advice.action == .buyNo)
    }
}

struct HistoryCacheTests {
    func market(_ minutes: Double, up: Bool = true) -> KalshiMarket {
        let open = Date(timeIntervalSince1970: 1_793_000_000 + minutes * 60)
        let json = """
        {"ticker":"T\(Int(minutes))","status":"finalized","open_time":"\(ISO8601DateFormatter().string(from: open))",
         "close_time":"\(ISO8601DateFormatter().string(from: open.addingTimeInterval(900)))","floor_strike":80000,
         "result":"\(up ? "yes" : "no")"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(KalshiMarket.self, from: Data(json.utf8))
    }

    func candle(_ minutes: Double, close: Double = 80_000) -> Candle {
        Candle(time: Date(timeIntervalSince1970: 1_793_000_000 + minutes * 60), open: close, high: close + 5,
               low: close - 5, close: close, volume: 2)
    }

    @Test func savesAndLoadsEverything() throws {
        var cache = HistoryCache()
        cache.merge(markets: [market(0), market(15, up: false)])
        cache.merge(mids: [180: ["T0": 0.62], 240: ["T0": 0.7]], checked: ["T0", "T15"])
        cache.merge(candles: [candle(1, close: 80_010), candle(0)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        cache.save(to: url)
        let loaded = HistoryCache.load(from: url)
        #expect(loaded == cache)
        #expect(loaded.candles.map(\.close) == [80_000, 80_010])   // sorted by time
        #expect(loaded.markets["T15"]?.settledUp == false)
        #expect(loaded.mids(at: 180) == ["T0": 0.62])
    }

    @Test func missingFileOrOldVersionIsEmpty() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).json")
        #expect(HistoryCache.load(from: url) == HistoryCache())
    }

    @Test func onlyUncoveredCandleRangesAreFetched() {
        var cache = HistoryCache()
        #expect(cache.missingCandleRanges(from: candle(0).time, to: candle(10).time).count == 1)
        cache.merge(candles: (0...10).map { candle(Double($0)) })
        // Fully covered: nothing to fetch.
        #expect(cache.missingCandleRanges(from: candle(2).time, to: candle(8).time).isEmpty)
        // Extends past the end: only the new minutes.
        let after = cache.missingCandleRanges(from: candle(5).time, to: candle(20).time)
        #expect(after.count == 1 && after[0].start == candle(11).time && after[0].end == candle(20).time)
        // Starts before: only the earlier minutes.
        let before = cache.missingCandleRanges(from: candle(-10).time, to: candle(4).time)
        #expect(before.count == 1 && before[0].start == candle(-10).time && before[0].end == candle(-1).time)
    }

    @Test func pruneDropsOldWindowsAndCandles() {
        var cache = HistoryCache()
        cache.merge(markets: [market(0), market(600)])
        cache.merge(mids: [180: ["T0": 0.5, "T600": 0.6]], checked: ["T0", "T600"])
        cache.merge(candles: [candle(0), candle(590)])
        cache.prune(before: market(600).openTime)
        #expect(Set(cache.markets.keys) == ["T600"])
        #expect(cache.oddsChecked == ["T600"])
        #expect(cache.candles.map(\.time) == [candle(590).time])   // kept: within 3 h of the cutoff
    }
}

struct SourceOffsetTests {
    @Test func offsetsWaitForEnoughExchanges() {
        let six = Array(repeating: -12.0, count: BotEngine.minimumOffsetSamples)
        #expect(BotEngine.offsets(from: ["coinbase": six, "kraken": six]).isEmpty)
        #expect(BotEngine.offsets(from: ["coinbase": six, "kraken": six, "gemini": [-12]]).isEmpty)
    }

    @Test func measuredExchangesUseTheirOwnMedianOthersTheTypical() {
        let samples: [String: [Double]] = [
            "coinbase": [-10, -11, -12, -13, -14, -15],
            "kraken": [-20, -20, -20, -20, -20, 500],     // one wild sample barely moves a median
            "bitstamp": [-5, -5, -5, -5, -5, -5],
        ]
        let offsets = BotEngine.offsets(from: samples)
        #expect(offsets["coinbase"] == -12.5)
        #expect(offsets["kraken"] == -20)
        #expect(offsets["bitstamp"] == -5)
        #expect(offsets["gemini"] == -12.5)                // median of the measured three
        #expect(offsets.count == CompositePriceClient.Exchange.allCases.count)
    }

    @Test func correctedMidAddsTheOffset() {
        let status = SourceStatus(source: .coinbase, mid: 80_000, state: .used, offset: -12.5)
        #expect(status.corrected == 79_987.5)
    }
}


struct RiskCalibrationTests {
    @Test func logisticFitRecoversAKnownRelationship() {
        // y ~ Bernoulli(σ(0.5 + 2x)) on a grid, generated deterministically.
        var rows: [(x: [Double], y: Bool)] = []
        for i in 0..<4000 {
            let x = Double(i % 200) / 100 - 1
            let p = 1 / (1 + exp(-(0.5 + 2 * x)))
            rows.append(([x], Double((i * 7919) % 1000) / 1000 < p))
        }
        let w = RiskCalibration.fitLogistic(rows)
        #expect(w != nil)
        if let w {
            #expect(abs(w[0] - 0.5) < 0.25)
            #expect(abs(w[1] - 2) < 0.4)
        }
    }

    @Test func ewmaVolatilityReactsToARecentBurst() {
        // A calm hour, then 10 volatile minutes at the end.
        var closes = [80_000.0]
        for i in 1...60 { closes.append(closes[i - 1] + (i > 50 ? (i.isMultiple(of: 2) ? 40 : -40) : (i.isMultiple(of: 2) ? 5 : -5))) }
        let equal = RiskCalibration.volatility(closes: closes, halfLife: nil)!
        let recent = RiskCalibration.volatility(closes: closes, halfLife: 15)!
        #expect(recent > equal)
    }

    @Test func riskLogScoresSettledWindowsIntoBands() {
        var log = RiskLog()
        log.append(.init(ticker: "A", time: .now, flip: 0.1, leaderUp: true))
        log.append(.init(ticker: "A", time: .now, flip: 0.4, leaderUp: false))
        log.append(.init(ticker: "B", time: .now, flip: 0.2, leaderUp: true))
        let first = log.resolve(ticker: "A", settledUp: true)
        let second = log.resolve(ticker: "A", settledUp: true)
        #expect(first)
        #expect(!second)                                           // already scored
        let bands = log.bands
        #expect(bands.map(\.label) == ["Under 15%", "35% or more"])  // B not settled yet
        #expect(bands[0].happened == 0)                            // Up led and won
        #expect(bands[1].happened == 1)                            // Down led and lost
    }
}
