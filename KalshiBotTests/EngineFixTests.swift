//
//  EngineFixTests.swift
//  KalshiBotTests
//
//  The engine's bookkeeping that doesn't need the network: trial marks, the call time
//  stored with a live call, which examples a catch-up may replace, and voided windows.
//

import Foundation
import SwiftData
import Testing
@testable import KalshiBot

struct TrialMarkTests {
    /// Windows `range` (15 minutes apart) where the EMA trend truly drives outcomes.
    private func samples(_ range: Range<Int>, seed: UInt64 = 11) -> [TrainingSample] {
        var rng = SeededGenerator(seed: seed)
        return range.map { i in
            let ema = Double.random(in: -2...2, using: &rng)
            return TrainingSample(features: [.kalshiImplied: 0, .emaTrend: ema],
                                  wentUp: Double.random(in: 0...1, using: &rng) < 1 / (1 + exp(-1.2 * ema)),
                                  time: Date(timeIntervalSince1970: Double(i) * 900))
        }
    }

    @Test func markIsTheTimeOfTheNewestJudgedWindow() throws {
        let data = samples(300..<1800)
        let first = try #require(ModelTrainer.train(data, excluding: []).trial(for: .emaTrend))
        #expect(first.counted == true)
        #expect(first.markTime == data.last?.time)
        #expect(first.windowsSinceMark == 0)
    }

    @Test func olderWindowsAddedLaterAreNotJudgedAgain() throws {
        let data = samples(300..<1800)
        let markTime = try #require(ModelTrainer.train(data, excluding: []).trial(for: .emaTrend)?.markTime)
        // 300 older windows rebuilt afterwards (e.g. a longer history download).
        let grown = samples(0..<300, seed: 5) + data
        let marks = ["emaTrend": markTime]
        let again = try #require(ModelTrainer.train(grown, excluding: [], lastTrialMarkTimes: marks).trial(for: .emaTrend))
        #expect(again.counted == false && !again.counts)
        #expect(again.windowsSinceMark == 0)
        #expect(again.markTime == markTime)
        // A position mark would have taken the last 300 already-judged windows as fresh.
        let byIndex = try #require(ModelTrainer.train(grown, excluding: [], lastTrialMarks: ["emaTrend": 1500]).trial(for: .emaTrend))
        #expect(byIndex.counted == true)
        // Windows that settle after the mark are the fresh ones.
        let later = try #require(ModelTrainer.train(grown + samples(1800..<2050, seed: 3), excluding: [],
                                                    lastTrialMarkTimes: marks).trial(for: .emaTrend))
        #expect(later.counted == true && later.windows == 250)
        #expect(later.markTime == Date(timeIntervalSince1970: 2049 * 900))
    }

    @Test func oldPositionMarkBecomesATimeMark() throws {
        let data = samples(0..<1500)
        let trial = try #require(ModelTrainer.train(data, excluding: [], lastTrialMarks: ["emaTrend": 1400]).trial(for: .emaTrend))
        #expect(trial.counted == false)
        #expect(trial.markTime == data[1399].time)
        #expect(trial.windowsSinceMark == 100)
        // The same mark as a time judges the same windows.
        let byTime = try #require(ModelTrainer.train(data, excluding: [], lastTrialMarkTimes: ["emaTrend": data[1249].time])
            .trial(for: .emaTrend))
        let byIndex = try #require(ModelTrainer.train(data, excluding: [], lastTrialMarks: ["emaTrend": 1250]).trial(for: .emaTrend))
        #expect(byTime.counted == true && byTime.windows == 250)
        #expect(byTime.gain == byIndex.gain)
    }

    @Test func markBeforeTheWholePoolStartsOver() throws {
        let data = samples(300..<1800)
        let trial = try #require(ModelTrainer.train(data, excluding: [], lastTrialMarkTimes: ["emaTrend": .distantPast])
            .trial(for: .emaTrend))
        // As if there were no mark: the newest 20%.
        #expect(trial.counted == true && trial.windows == 300)
    }
}

struct LiveCallDelayTests {
    private let open = Date(timeIntervalSince1970: 1_793_156_400)

    @Test func lateCallIsStoredUnderTheConfiguredCallTime() {
        // Locked for +3 min, but the data fetch ran 40s long.
        #expect(BotEngine.storedCallDelay(configured: 180, predictedAt: open.addingTimeInterval(220), openTime: open) == 180)
    }

    @Test func olderRecordsFallBackToWholeMinutes() {
        // No stored call time: 3m40s after the open was a +3 min call, not +4.
        #expect(BotEngine.storedCallDelay(configured: 0, predictedAt: open.addingTimeInterval(220), openTime: open) == 180)
        #expect(BotEngine.storedCallDelay(configured: 0, predictedAt: open.addingTimeInterval(541), openTime: open) == 540)
    }

    @MainActor @Test func recordKeepsItsCallTime() throws {
        let container = try ModelContainer(for: PredictionRecord.self, TrainingExample.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let record = PredictionRecord(ticker: "KXBTC15M-TEST", openTime: open, closeTime: open.addingTimeInterval(900),
                                      predictedAt: open.addingTimeInterval(205), strike: 80_000, spotAtPrediction: 80_010,
                                      proxyOpenAverage: nil, probabilityUp: 0.6, marketYesMid: 0.6,
                                      features: [.kalshiImplied: 0.4], contributions: [:], excludedFeatures: [],
                                      callDelay: 180)
        context.insert(record)
        try context.save()
        let fetched = try #require(try context.fetch(FetchDescriptor<PredictionRecord>()).first)
        #expect(fetched.callDelay == 180)
        #expect(!fetched.isVoid)
    }
}

struct CatchUpReplacementTests {
    @Test func liveExamplesAreNeverReplaced() {
        for delay in [180.0, 540] {
            for odds in [true, false] {
                #expect(!BotEngine.catchUpMayReplace(isLive: true, callDelay: delay, hasKalshiOdds: odds, at: 180))
            }
        }
    }

    @Test func rebuiltExamplesAreRedoneUnlessCompleteAtThisCallTime() {
        #expect(!BotEngine.catchUpMayReplace(isLive: false, callDelay: 180, hasKalshiOdds: true, at: 180))
        #expect(BotEngine.catchUpMayReplace(isLive: false, callDelay: 180, hasKalshiOdds: false, at: 180))
        #expect(BotEngine.catchUpMayReplace(isLive: false, callDelay: 540, hasKalshiOdds: true, at: 180))
    }
}

struct VoidWindowTests {
    private func market(status: String, result: String, closedHoursAgo: Double = 1) throws -> KalshiMarket {
        let close = Date.now.addingTimeInterval(-closedHoursAgo * 3600)
        let formatter = ISO8601DateFormatter()
        let json = """
        {"ticker":"KXBTC15M-TEST","status":"\(status)","open_time":"\(formatter.string(from: close.addingTimeInterval(-900)))",
         "close_time":"\(formatter.string(from: close))","floor_strike":80000,"result":"\(result)"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(KalshiMarket.self, from: Data(json.utf8))
    }

    @Test func finalWithoutAResultIsVoid() throws {
        #expect(BotEngine.isVoid(try market(status: "finalized", result: "")))
        #expect(BotEngine.isVoid(try market(status: "voided", result: "")))
    }

    @Test func settledOrStillPendingIsNotVoid() throws {
        #expect(!BotEngine.isVoid(try market(status: "finalized", result: "yes")))
        #expect(!BotEngine.isVoid(try market(status: "closed", result: "")))
    }

    @Test func longPastItsCloseIsVoid() throws {
        #expect(BotEngine.isVoid(try market(status: "closed", result: "", closedHoursAgo: 25)))
    }
}
