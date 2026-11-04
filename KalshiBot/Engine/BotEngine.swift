//
//  BotEngine.swift
//  KalshiBot
//
//  Runs the polling loops, locks in one prediction per 15-minute window at the
//  open, and resolves each prediction against Kalshi's official settlement.
//

import Foundation
import Observation
import SwiftData

@Observable
final class BotEngine {

    struct Tick: Sendable {
        let time: Date
        /// Median of the exchanges, as fetched.
        let rawPrice: Double
        /// Calibrated toward CF Benchmarks' BRTI (raw + the offset in effect at the time).
        let price: Double
    }

    /// An entry or exit signal for this window: when it first appeared, and when it was
    /// last seen (a signal that comes and goes updates its alert instead of adding more).
    struct StrategyAlert: Identifiable {
        let id = UUID()
        let time: Date
        var lastSeen: Date
        var signal: StrategySignal
    }

    struct ActivityEntry: Identifiable {
        let id = UUID()
        let time: Date
        let message: String
    }

    // MARK: Live state

    private(set) var isRunning = false
    private(set) var spot: Double?
    private(set) var spotSources = 0
    /// Each price source's latest quote and whether it's in the composite.
    private(set) var sourceStatuses: [SourceStatus] = []
    /// Bumped each time windows settle; when the last result landed.
    private(set) var settledCount = 0
    private(set) var lastSettledAt: Date?
    private var watchedSettlement: String?
    private var isResolving = false
    /// `true` when the last price came from the live WebSocket streams, `false` if from REST polling.
    private(set) var isStreaming = false
    private(set) var ticks: [Tick] = []
    private(set) var currentMarket: KalshiMarket?
    private(set) var candles: [Candle] = []
    private(set) var liveFeatures: [FeatureKey: Double] = [:]
    private(set) var liveProbability: Double?
    /// Recommendation for the current window, re-evaluated every second.
    private(set) var strategy: StrategyAdvice?
    /// Alerts raised in the current window, newest first.
    private(set) var strategyAlerts: [StrategyAlert] = []
    private var activeSignalIDs: Set<String> = []
    private var alertsTicker: String?
    private(set) var activity: [ActivityEntry] = []
    private(set) var model: PredictionModel
    private(set) var isTraining = false
    private(set) var isBackfilling = false
    /// Progress text while past windows are being rebuilt.
    private(set) var backfillStatus: String?
    /// Dollars added to the exchange composite so it tracks the official BRTI: the
    /// median of (official target − our raw 60s average) over recent window opens.
    private(set) var priceCalibration: Double = 0
    private(set) var calibrationSampleCount = 0
    /// Per-exchange corrections toward the official BRTI (by exchange raw value): the
    /// median of (official target − that exchange's 60s average) over recent window
    /// opens. Empty until enough exchanges have been measured.
    private(set) var sourceOffsets: [String: Double] = [:]
    /// How far the index estimate was from Kalshi's official target at recent opens
    /// (official − estimate), newest last.
    private(set) var trackingErrors: [Double] = []

    /// The Reversal Risk card's corrections, refitted from the saved history (nil = fixed ones).
    private(set) var riskCalibration: RiskCalibration?
    /// The card's flip chance logged once a minute, scored at settlement.
    private(set) var riskLog = RiskLog()
    private var lastRiskLogMinute: Int?

    /// Median size of the recent tracking errors, once there are a few.
    var trackingError: Double? {
        trackingErrors.count >= 3 ? Self.median(trackingErrors.map(abs)) : nil
    }
    /// Settled windows available to learn from, split by source.
    private(set) var liveExampleCount = 0
    private(set) var historyExampleCount = 0

    /// Minutes after the open the call can lock at: any whole minute except the first
    /// and last three. Later calls are right more often — more of the window has played
    /// out — but Kalshi's price has moved too.
    nonisolated static let callTimeOptions = Array(3...12)

    /// When the call locks, in minutes after the open. The model's history is rebuilt
    /// at the same moment (from Kalshi's 1-minute candles), so live calls match training.
    var callDelayMinutes: Int {
        didSet {
            guard callDelayMinutes != oldValue else { return }
            UserDefaults.standard.set(callDelayMinutes, forKey: Keys.callDelayMinutes)
            Task { await callTimeChanged() }
        }
    }

    var callDelay: TimeInterval { Double(callDelayMinutes) * 60 }

    /// One-click combinations of call time and confidence threshold.
    enum CallPreset: String, CaseIterable, Identifiable {
        case standard, highHitRate
        var id: String { rawValue }
        var title: String {
            switch self {
            case .standard: "Standard (+3 min, ≥60%)"
            case .highHitRate: "High hit rate (+9 min, ≥70%)"
            }
        }
        var minutes: Int { self == .standard ? 3 : 9 }
        var confidence: Double { self == .standard ? 0.60 : 0.70 }
    }

    func apply(_ preset: CallPreset) {
        minimumCallConfidence = preset.confidence
        if callDelayMinutes != preset.minutes { callDelayMinutes = preset.minutes }
        log("Preset: \(preset.title)")
    }

    var activePreset: CallPreset? {
        CallPreset.allCases.first { $0.minutes == callDelayMinutes && $0.confidence == minimumCallConfidence }
    }

    /// Calls are skipped if the bot can't make one within 30s of the call time (e.g. it
    /// launched mid-window), so every logged call is made at the same moment.
    var maxPredictionDelay: TimeInterval { callDelay + 30 }

    /// How often Kalshi's favorite won at each call time, over the rebuilt history.
    private(set) var callTimeAccuracy: [Int: Double] = [:]
    /// Past windows by call minute and 5-point confidence band ("3:70" = +3 min, 70–75%):
    /// how many there were and how many the favorite won. Shown as "calls like this".
    private(set) var confidenceHistory: [String: (won: Int, total: Int)] = [:]
    nonisolated static let confidenceBandWidth = 0.05

    /// The band a confidence falls in, e.g. 0.74 → 70.
    nonisolated static func confidenceBand(_ confidence: Double) -> Int {
        // The tiny nudge keeps exact edges (0.70) in their own band despite rounding.
        min(Int((confidence / confidenceBandWidth + 1e-9).rounded(.down)) * Int(confidenceBandWidth * 100), 95)
    }

    /// How past calls at this confidence and call minute did.
    func callsLikeThis(confidence: Double) -> (band: Int, won: Int, total: Int)? {
        let band = Self.confidenceBand(confidence)
        guard let entry = confidenceHistory["\(callDelayMinutes):\(band)"], entry.total >= 20 else { return nil }
        return (band, entry.won, entry.total)
    }

    /// Context signals promoted into the model by the trials.
    private(set) var promoted: Set<FeatureKey> = []
    /// Consecutive trial outcomes per signal: +n = n significant gains in a row,
    /// −n = n non-gains in a row. Three in a row promotes or demotes.
    private var trialStreaks: [String: Int] = [:]
    /// Per signal, the trial-pool size at its last counted result; the next counted result
    /// needs `ModelTrainer.freshWindowsPerTrial` more windows, so a streak is built from
    /// separate evidence rather than the same windows judged again.
    private var trialMarks: [String: Int] = [:]
    static let trialStreakToChange = 3

    /// Where a context signal stands on its way to promotion (or, if promoted, demotion).
    struct PromotionProgress: Equatable {
        /// Settled windows that have this signal.
        let windows: Int
        let isLiveOnly: Bool
        let isPromoted: Bool
        /// Consecutive counted results in the direction that would change its status.
        let streak: Int
        /// Settled windows until its next result can count (0 = the next retrain).
        let windowsToNextTrial: Int
        /// The fewest settled windows before it could change status, if every counted
        /// result from here goes its way.
        let windowsNeeded: Int
    }

    func promotionProgress(for key: FeatureKey) -> PromotionProgress? {
        guard !key.isBaseInput, let trial = model.trial(for: key) else { return nil }
        let raw = key.rawValue
        let liveOnly = trial.liveOnly == true
        let pool = liveOnly ? (trial.liveWindows ?? 0) : Int((trial.coverage * Double(model.trainingCount)).rounded())
        let fresh = ModelTrainer.freshWindowsPerTrial
        // A first counted result judges the newest 20%, so it needs that to be ≥ `fresh`.
        let firstCounted = max(liveOnly ? ModelTrainer.minimumLiveTrialWindows : 0, fresh * 5)
        let nextCountedAt = trialMarks[raw].map { $0 + fresh } ?? firstCounted
        let untilNext = max(nextCountedAt - pool, 0)
        let isPromoted = promoted.contains(key)
        let streak = trialStreaks[raw] ?? 0
        let soFar = isPromoted ? max(-streak, 0) : max(streak, 0)
        let remaining = max(Self.trialStreakToChange - soFar, 1)
        return PromotionProgress(windows: pool, isLiveOnly: liveOnly, isPromoted: isPromoted, streak: soFar,
                                 windowsToNextTrial: untilNext, windowsNeeded: untilNext + fresh * (remaining - 1))
    }

    /// Keeps the Mac from idle-sleeping while the bot runs, so no window is missed.
    var keepMacAwake: Bool {
        didSet {
            UserDefaults.standard.set(keepMacAwake, forKey: Keys.keepMacAwake)
            if keepAwake != nil { endActivity() }
            updateActivity()
        }
    }

    /// "Confident calls only": windows whose call is less confident than this are marked
    /// "No call" and left out of accuracy (they're still logged and trained on). 0 = off.
    var minimumCallConfidence: Double {
        didSet { UserDefaults.standard.set(minimumCallConfidence, forKey: Keys.minimumCallConfidence) }
    }
    static let callConfidenceOptions: [Double] = [0, 0.60, 0.65, 0.70, 0.75, 0.80]
    /// New installs skip calls under 60%: in 6,400 past windows, 50–55% calls were right
    /// half the time — a coin flip — so counting them only adds noise.
    static let defaultCallConfidence = 0.60

    /// True if this window's call falls below the confidence threshold.
    func isNoCall(_ record: PredictionRecord) -> Bool {
        minimumCallConfidence > 0 && record.confidence < minimumCallConfidence
    }

    /// The records that count as calls under the current threshold.
    func calls(_ records: [PredictionRecord]) -> [PredictionRecord] {
        minimumCallConfidence > 0 ? records.filter { !isNoCall($0) } : records
    }

    /// Custom stop-loss: share of the stake to risk before the stop line, instead of the
    /// trading style's default. 0 = use the style's.
    var customStopLoss: Double {
        didSet { UserDefaults.standard.set(customStopLoss, forKey: Keys.customStopLoss) }
    }
    static let stopLossOptions: [Double] = [0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.40, 0.50, 0.60, 0.70]
    /// Custom take-profit: gain on the stake to take profit at, instead of the trading
    /// style's default. 0 = use the style's.
    var customTakeProfit: Double {
        didSet { UserDefaults.standard.set(customTakeProfit, forKey: Keys.customTakeProfit) }
    }
    static let takeProfitOptions: [Double] = [0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.40, 0.50, 0.75, 1.00]

    /// The stop-loss in effect: the custom one if set, else the style's.
    var effectiveStopLoss: Double { customStopLoss > 0 ? customStopLoss : tradingStyle.maxLoss }

    /// Dollars the user puts on each window's call, for the profit/loss estimate. 0 = not set.
    var stake: Double {
        didSet { UserDefaults.standard.set(stake, forKey: Keys.stake) }
    }

    /// Profit and loss for the stake on this window's call, from the window's state now.
    func position(for market: KalshiMarket, record: PredictionRecord?) -> PositionEstimate? {
        guard stake > 0, let record, let plan = exitPlan(for: market, record: record), let mid = market.yesMid else { return nil }
        return PositionEstimate.estimate(stake: stake, plan: plan, chanceRight: record.predictedUp ? mid : 1 - mid)
    }

    /// How much risk the strategy recommendations take.
    var tradingStyle: TradingStyle {
        didSet {
            UserDefaults.standard.set(tradingStyle.rawValue, forKey: Keys.tradingStyle)
            // A new style judges this window afresh.
            strategyAlerts = []
            activeSignalIDs = []
            if let market = currentMarket { updateStrategy(for: market) }
        }
    }

    /// Whether Kalshi's own Yes price is fed to the model as an indicator.
    var useKalshiOdds: Bool {
        didSet {
            UserDefaults.standard.set(useKalshiOdds, forKey: Keys.useKalshiOdds)
            Task { await retrain() }
        }
    }

    var excludedFeatures: Set<FeatureKey> { useKalshiOdds ? [] : [.kalshiImplied] }

    // MARK: Dependencies

    private let kalshi = KalshiClient()
    private let coinbase = CoinbaseClient()
    private let composite = CompositePriceClient()
    /// Streaming top-of-book; REST `composite` is the fallback if every stream drops.
    private let liveFeed = LivePriceFeed()
    /// The window after the current one, fetched ahead so the switch happens on the second.
    private var nextMarket: KalshiMarket?
    private var isRefreshingMarket = false
    private var isFallbackPolling = false
    private var modelContext: ModelContext?
    private var tasks: [Task<Void, Never>] = []
    /// Keeps the Mac from idle-sleeping (and the app from App Nap) while the bot runs;
    /// a sleeping Mac missed 8 windows overnight on Oct 29.
    private var keepAwake: NSObjectProtocol?
    private var isPredicting = false
    private var lastSkippedTicker: String?
    private var retrainRequested = false
    private var lastCalibratedTicker: String?
    /// Bumped by a reset so an in-flight history rebuild discards its results.
    private var historyGeneration = 0
    /// A rebuild was asked for while one was running; run again when it finishes.
    private var catchUpRequested = false
    private var calibrationSamples: [Double] = []
    private var sourceOffsetSamples: [String: [Double]] = [:]
    /// Each exchange's own mid, per second, for the last few minutes.
    private var sourceTicks: [String: [(time: Date, mid: Double)]] = [:]

    private enum Keys {
        // v2: market-anchored model; older saved weights don't apply.
        // v3: promotions and trials added.
        static let model = "predictionModel.v3"
        static let useKalshiOdds = "useKalshiOdds"
        static let tradingStyle = "tradingStyle"
        static let minimumCallConfidence = "minimumCallConfidence"
        static let customStopLoss = "customStopLoss"
        static let customTakeProfit = "customTakeProfit"
        static let stake = "stake"
        // v2: trimmed-mean composite (v1 was a plain median). v4: eight sources.
        static let calibration = "brtiCalibrationSamples.v4"
        static let sourceOffsets = "sourceOffsetSamples.v1"
        static let trackingErrors = "brtiTrackingErrors.v1"
        static let keepMacAwake = "keepMacAwake"
        static let riskCalibration = "riskCalibration.v1"
        static let historyFeatureVersion = "historyFeatureVersion"
        static let historyCallDelay = "historyCallDelay"
        static let lastResetAt = "lastResetAt"
        static let callDelayMinutes = "callDelayMinutes"
        static let callTimeAccuracy = "callTimeAccuracy"
        static let confidenceHistory = "confidenceHistory"
        static let promoted = "promotedFeatures"
        static let trialStreaks = "trialStreaks"
        static let trialMarks = "trialMarks"
        /// Written by the dashboard; kept through a reset as a display setting.
        static let dashboardRequiredHeight = "dashboardRequiredHeight"
    }

    /// When the model was last reset. Stored outside the logs a reset clears, so
    /// it's always clear whether an empty log came from a reset.
    var lastResetAt: Date? { UserDefaults.standard.object(forKey: Keys.lastResetAt) as? Date }

    /// How far back past windows are rebuilt for training. Kalshi's KXBTC15M history
    /// starts Aug 24, 2026 (~68 days, ~6,400 windows on Oct 31), so today this takes
    /// all of it; the window keeps growing to 180 days as the series ages.
    private static let historyWindow: TimeInterval = 180 * 24 * 3600
    /// Bump when rebuilt-history features change meaning, so old ones are redone.
    /// v2: features at open + call delay. v3: adds the Deribit futures features (since
    /// removed; their stored values are ignored, so no rebuild was needed).
    private static let historyFeatureVersion = 3
    /// Recent window opens used for the BRTI calibration and per-exchange offsets.
    private static let calibrationSampleLimit = 48
    /// Opens an exchange must be measured at before its own offset is used, and how many
    /// exchanges must be measured before any offsets are applied.
    nonisolated static let minimumOffsetSamples = 6
    nonisolated static let minimumMeasuredSources = 3

    init() {
        let defaults = UserDefaults.standard
        let useKalshiOdds = defaults.object(forKey: Keys.useKalshiOdds) as? Bool ?? true
        self.useKalshiOdds = useKalshiOdds
        tradingStyle = defaults.string(forKey: Keys.tradingStyle).flatMap(TradingStyle.init(rawValue:)) ?? .neutral
        if defaults.object(forKey: Keys.minimumCallConfidence) == nil {
            minimumCallConfidence = Self.defaultCallConfidence
        } else {
            let savedConfidence = defaults.double(forKey: Keys.minimumCallConfidence)
            minimumCallConfidence = Self.callConfidenceOptions.contains(savedConfidence) ? savedConfidence : 0
        }
        keepMacAwake = defaults.object(forKey: Keys.keepMacAwake) as? Bool ?? true
        let savedStop = defaults.double(forKey: Keys.customStopLoss)
        customStopLoss = Self.stopLossOptions.contains(savedStop) ? savedStop : 0
        let savedProfit = defaults.double(forKey: Keys.customTakeProfit)
        customTakeProfit = Self.takeProfitOptions.contains(savedProfit) ? savedProfit : 0
        stake = max(defaults.double(forKey: Keys.stake), 0)
        let minutes = defaults.integer(forKey: Keys.callDelayMinutes)
        callDelayMinutes = Self.callTimeOptions.contains(minutes) ? minutes : 3
        let savedPromotions = Set((defaults.stringArray(forKey: Keys.promoted) ?? []).compactMap(FeatureKey.init(rawValue:)))
        promoted = savedPromotions
        trialStreaks = defaults.dictionary(forKey: Keys.trialStreaks) as? [String: Int] ?? [:]
        trialMarks = defaults.dictionary(forKey: Keys.trialMarks) as? [String: Int] ?? [:]
        if let stored = defaults.dictionary(forKey: Keys.confidenceHistory) as? [String: [Int]] {
            confidenceHistory = stored.compactMapValues { $0.count == 2 ? (won: $0[0], total: $0[1]) : nil }
        }
        if let stored = defaults.dictionary(forKey: Keys.callTimeAccuracy) as? [String: Double] {
            callTimeAccuracy = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in Int(key).map { ($0, value) } })
        }
        if let data = UserDefaults.standard.data(forKey: Keys.model),
           let saved = try? JSONDecoder().decode(PredictionModel.self, from: data) {
            model = saved
        } else {
            model = .starting(excluding: useKalshiOdds ? [] : [.kalshiImplied], promoted: savedPromotions)
        }
        calibrationSamples = UserDefaults.standard.array(forKey: Keys.calibration) as? [Double] ?? []
        updateCalibration()
        sourceOffsetSamples = defaults.dictionary(forKey: Keys.sourceOffsets) as? [String: [Double]] ?? [:]
        updateSourceOffsets()
        trackingErrors = defaults.array(forKey: Keys.trackingErrors) as? [Double] ?? []
        if let data = defaults.data(forKey: Keys.riskCalibration) {
            riskCalibration = try? JSONDecoder().decode(RiskCalibration.self, from: data)
        }
        riskLog = RiskLog.load()
    }

    // MARK: Lifecycle

    func start(context: ModelContext) {
        guard !isRunning else { return }
        modelContext = context
        isRunning = true
        updateActivity()
        log("Bot started")
        discardOutdatedHistory(in: context)

        let offsets = sourceOffsets, weights = trackingWeights
        Task {
            await liveFeed.setOffsets(offsets, weights: weights)
            await liveFeed.start()
        }
        tasks = [
            // One price sample per wall-clock second, like the BRTI itself.
            onEverySecond {
                $0.sampleSpot()
                $0.logRiskIfDue()
            },
            repeating(every: .seconds(1)) { await $0.pollMarket() },
            repeating(every: .seconds(15)) { await $0.pollIndicators() },
            repeating(every: .seconds(15)) { await $0.resolvePending() },
            // Learn from any windows the bot didn't predict live (app closed, joined late).
            repeating(every: .seconds(15 * 60)) { await $0.catchUpHistory() },
        ]
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        Task { await liveFeed.stop() }
        isRunning = false
        endActivity()
        log("Bot stopped")
    }

    /// While running, holds off App Nap so prices are sampled every second, and — if
    /// `keepMacAwake` — idle sleep too.
    private func updateActivity() {
        guard isRunning, keepAwake == nil else { return }
        keepAwake = ProcessInfo.processInfo.beginActivity(
            options: keepMacAwake ? [.userInitiated, .idleSystemSleepDisabled] : [.userInitiatedAllowingIdleSystemSleep],
            reason: "Collecting prices and calling each 15-minute Kalshi window")
    }

    private func endActivity() {
        if let keepAwake { ProcessInfo.processInfo.endActivity(keepAwake) }
        keepAwake = nil
    }

    /// Files the app writes outside SwiftData and UserDefaults.
    nonisolated static var storedFiles: [URL] {
        [HistoryCache.fileURL, RiskLog.fileURL, CrashCapture.defaultDirectory, AppLog.defaultDirectory]
    }

    /// Erase everything: stops the bot and deletes the prediction log, training history,
    /// every setting, calibration and statistic, the saved market download and the risk
    /// log — as if the app were freshly installed. The caller relaunches the app so every
    /// setting starts again from its default.
    func eraseEverything() {
        stop()
        if let context = modelContext {
            for record in (try? context.fetch(FetchDescriptor<PredictionRecord>())) ?? [] { context.delete(record) }
            for example in (try? context.fetch(FetchDescriptor<TrainingExample>())) ?? [] { context.delete(example) }
            try? context.save()
        }
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard.synchronize()
        }
        for url in Self.storedFiles { try? FileManager.default.removeItem(at: url) }
    }

    /// Model-only reset: starting weights, and promotions and trials cleared, then a
    /// retrain on the data already collected. The prediction log, accuracy, training
    /// history, calibration and activity are kept.
    func resetModelKeepingData() {
        let defaults = UserDefaults.standard
        for key in [Keys.model, Keys.promoted, Keys.trialStreaks, Keys.trialMarks] { defaults.removeObject(forKey: key) }
        defaults.set(Date.now, forKey: Keys.lastResetAt)
        promoted = []
        trialStreaks = [:]
        trialMarks = [:]
        model = .starting(excluding: excludedFeatures)
        recomputeLive()
        log("Model reset: starting weights, promotions and trials cleared; retraining on the data already collected")
        Task { await retrain() }
    }

    /// Full reset: starting weights, and every log cleared — training history, the
    /// prediction/accuracy log, and the activity log. The past 30 days are then
    /// rebuilt from public Kalshi and Coinbase history so the model can relearn at once.
    /// (The BRTI price calibration is kept; it's a measurement, not a log.)
    func resetModel() {
        guard let context = modelContext else { return }
        // Delete object by object (not a batch delete) so every @Query view empties at once.
        for record in (try? context.fetch(FetchDescriptor<PredictionRecord>())) ?? [] { context.delete(record) }
        for example in (try? context.fetch(FetchDescriptor<TrainingExample>())) ?? [] { context.delete(example) }
        try? context.save()

        // Everything the app has stored, including keys left by older builds — except the
        // user's settings, which are written back.
        let defaults = UserDefaults.standard
        let kept: [String: Any] = [Keys.callDelayMinutes, Keys.useKalshiOdds, Keys.dashboardRequiredHeight, Keys.tradingStyle,
                                   Keys.minimumCallConfidence, Keys.customStopLoss, Keys.customTakeProfit, Keys.stake,
                                   Keys.keepMacAwake]
            .reduce(into: [:]) { kept, key in kept[key] = defaults.object(forKey: key) }
        if let domain = Bundle.main.bundleIdentifier { defaults.removePersistentDomain(forName: domain) }
        for (key, value) in kept { defaults.set(value, forKey: key) }
        defaults.set(Self.historyFeatureVersion, forKey: Keys.historyFeatureVersion)
        defaults.set(callDelay, forKey: Keys.historyCallDelay)
        defaults.set(Date.now, forKey: Keys.lastResetAt)

        activity.removeAll()
        strategyAlerts = []
        activeSignalIDs = []
        calibrationSamples = []
        updateCalibration()
        sourceOffsetSamples = [:]
        updateSourceOffsets()
        trackingErrors = []
        riskLog = RiskLog()
        saveRiskLog()
        riskCalibration = nil
        let offsets = sourceOffsets, weights = trackingWeights
        Task { await liveFeed.setOffsets(offsets, weights: weights) }
        callTimeAccuracy = [:]
        promoted = []
        trialStreaks = [:]
        trialMarks = [:]
        model = .starting(excluding: excludedFeatures)
        liveExampleCount = 0
        historyExampleCount = 0
        historyGeneration += 1
        recomputeLive()
        log("Reset: all predictions, training data, calibration and stats cleared; rebuilding market history")
        Task { await catchUpHistory() }
    }

    private func repeating(every interval: Duration, _ body: @escaping @MainActor (BotEngine) async -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await body(self)
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Runs `body` just after every whole second of wall-clock time.
    private func onEverySecond(_ body: @escaping @MainActor (BotEngine) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                let now = Date.now.timeIntervalSince1970
                let wait = (now.rounded(.down) + 1.02) - now
                try? await Task.sleep(for: .seconds(wait))
                guard let self else { return }
                body(self)
            }
        }
    }

    // MARK: Polling

    /// Samples the streaming composite on the second; falls back to REST if no stream
    /// is fresh. Also switches to the next window the instant the current one closes.
    private func sampleSpot() {
        let now = Date.now
        advanceWindowIfNeeded(at: now)
        Task {
            sourceStatuses = await liveFeed.statuses(at: now)
            recordSourceTicks(sourceStatuses, at: now)
            if let live = await liveFeed.composite(at: now) {
                isStreaming = true
                record(price: live.price, sources: live.sources, at: now)
            } else if !isFallbackPolling {
                isStreaming = false
                isFallbackPolling = true
                defer { isFallbackPolling = false }
                if let polled = await composite.compositeMid() {
                    // The REST fallback has no per-exchange detail; use the typical offset.
                    let offset = sourceOffsets.isEmpty ? 0 : Self.median(Array(sourceOffsets.values))
                    record(price: polled.price + offset, sources: polled.sources, at: now)
                }
            }
        }
    }

    /// Keeps each exchange's own mid per second while its quote is fresh, for measuring
    /// its offset at the next window open.
    private func recordSourceTicks(_ statuses: [SourceStatus], at time: Date) {
        for status in statuses {
            let id = status.source.rawValue
            if let mid = status.mid, [.used, .trimmed, .outlier].contains(status.state) {
                sourceTicks[id, default: []].append((time, mid))
            }
            sourceTicks[id]?.removeAll { time.timeIntervalSince($0.time) > 3 * 60 }
        }
    }

    private func record(price: Double, sources: Int, at time: Date) {
        guard price.isFinite, price > 0 else { return }
        let calibrated = price + priceCalibration
        spot = calibrated
        spotSources = sources
        ticks.append(Tick(time: time, rawPrice: price, price: calibrated))
        ticks.removeAll { time.timeIntervalSince($0.time) > 20 * 60 }
    }

    /// Windows run back-to-back on the quarter hour. At the close of the current one,
    /// switch to the next immediately, with our own 60s average standing in for the
    /// target until Kalshi publishes the official one.
    private func advanceWindowIfNeeded(at now: Date) {
        guard let current = currentMarket, now >= current.closeTime else { return }
        // Settle the window that just closed right away, not on the next 15s sweep.
        if watchedSettlement != current.ticker {
            watchedSettlement = current.ticker
            Task { await watchSettlement(of: current.ticker) }
        }
        if let next = nextMarket, next.openTime <= now, now < next.closeTime {
            activate(next, at: now)
            nextMarket = nil
        }
    }

    private func activate(_ market: KalshiMarket, at now: Date) {
        var market = market
        if market.floorStrike == nil, let estimate = estimatedTarget(opening: market.openTime) {
            market.floorStrike = estimate
            market.strikeIsEstimate = true
        }
        currentMarket = market
        let target = market.floorStrike.map { Self.usd($0) + (market.strikeIsEstimate ? " (est.)" : "") } ?? "TBD"
        log("Window \(market.ticker) open, target \(target)")
        recomputeLive()
    }

    /// Our calibrated 60s average before `open` — the same construction as Kalshi's target.
    private func estimatedTarget(opening open: Date) -> Double? {
        let window = ticks.filter { $0.time < open && open.timeIntervalSince($0.time) <= 60 }
        guard window.count >= 40 else { return nil }
        return window.map(\.price).reduce(0, +) / Double(window.count)
    }

    /// Every second: refresh the current window (odds, official target), and fetch the
    /// next window ahead of its open so the switch can happen on the second.
    private func pollMarket() async {
        guard !isRefreshingMarket else { return }
        isRefreshingMarket = true
        defer { isRefreshingMarket = false }
        let now = Date.now
        do {
            // Window boundaries are fixed quarter hours, so the current ticker is known.
            let quarter: TimeInterval = 15 * 60
            let open = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / quarter).rounded(.down) * quarter)
            let close = open.addingTimeInterval(quarter)

            if currentMarket.map({ now >= $0.closeTime }) ?? true {
                activate(try await kalshi.market(ticker: KalshiClient.ticker(closingAt: close)), at: now)
            } else if let current = currentMarket {
                // The market record (target, status) every second until the official
                // target is in, then every 10s; the order book (odds) every second.
                var refreshed = current
                if current.strikeIsEstimate || current.floorStrike == nil || Int(now.timeIntervalSince1970) % 10 == 0 {
                    refreshed = try await kalshi.market(ticker: current.ticker)
                    if refreshed.floorStrike == nil {
                        // Not published yet: keep our estimate.
                        refreshed.floorStrike = current.floorStrike
                        refreshed.strikeIsEstimate = current.strikeIsEstimate
                    } else if current.strikeIsEstimate, let estimate = current.floorStrike, let official = refreshed.floorStrike {
                        log("Official target \(Self.usd(official)) published \(Int(now.timeIntervalSince(refreshed.openTime)))s after open (our estimate was \(Self.usd(estimate)), off by \(Self.usd(abs(official - estimate))))")
                    }
                }
                if let book = try? await kalshi.topOfBook(ticker: current.ticker) {
                    refreshed.liveYesBid = book.yesBid
                    refreshed.liveYesAsk = book.yesAsk
                } else {
                    refreshed.liveYesBid = current.liveYesBid
                    refreshed.liveYesAsk = current.liveYesAsk
                }
                currentMarket = refreshed
            }

            // Fetch the next window during the last minute of this one.
            let nextTicker = KalshiClient.ticker(closingAt: close.addingTimeInterval(quarter))
            if close.timeIntervalSince(now) <= 60, nextMarket?.ticker != nextTicker {
                nextMarket = try? await kalshi.market(ticker: nextTicker)
            }

            if let market = currentMarket {
                recordCalibrationSample(for: market)
                await predictIfNeeded(for: market)
            }
            recomputeLive()
        } catch {
            log("Kalshi: \(error.localizedDescription)")
        }
    }

    private func pollIndicators() async {
        await refreshIndicatorData()
        recomputeLive()
    }

    private func refreshIndicatorData() async {
        if let newCandles = try? await coinbase.oneMinuteCandles(), !newCandles.isEmpty { candles = newCandles }
    }

    // MARK: Prediction

    private func snapshot(for market: KalshiMarket, at date: Date = .now) -> MarketSnapshot? {
        guard let spot, let strike = market.floorStrike, strike > 0, !candles.isEmpty else { return nil }
        let recent = ticks.filter { date.timeIntervalSince($0.time) <= 60 }.map(\.price)
        return MarketSnapshot(
            candles: candles,
            spot: spot,
            recentTicks: recent,
            strike: strike,
            kalshiYesMid: market.yesMid,
            minutesRemaining: max(market.closeTime.timeIntervalSince(date) / 60, 0)
        )
    }

    private func recomputeLive() {
        guard let market = currentMarket, let snap = snapshot(for: market) else {
            liveFeatures = [:]
            liveProbability = nil
            return
        }
        liveFeatures = FeatureExtractor.features(from: snap)
        liveProbability = liveFeatures.isEmpty ? nil : model.probabilityUp(liveFeatures, excluding: excludedFeatures)
        updateStrategy(for: market)
    }

    /// Stop-loss and take-profit levels for this window's locked call, under the current
    /// trading style and market conditions. Nil before the call or without Kalshi quotes.
    func exitPlan(for market: KalshiMarket, record: PredictionRecord?) -> ExitPlan? {
        guard let record, record.ticker == market.ticker, let spot, let strike = market.floorStrike,
              let volatility = volatilityPerRootSecond, let yesBid = market.yesBid, let yesAsk = market.yesAsk,
              yesAsk >= yesBid else { return nil }
        // Entry: what the called side cost at the call (the ask), else its mid then.
        let entry: Double? = record.predictedUp
            ? (record.marketYesAsk ?? record.marketYesMid)
            : (record.marketYesBid.map { 1 - $0 } ?? record.marketYesMid.map { 1 - $0 })
        guard let entry else { return nil }
        let settlementStart = market.closeTime.addingTimeInterval(-60)
        let settling = ticks.filter { $0.time >= settlementStart && $0.time < market.closeTime }.map(\.price)
        let conditions = ExitPlan.Market(
            strike: strike, price: spot, secondsRemaining: market.closeTime.timeIntervalSinceNow, volatility: volatility,
            settlementAverageSoFar: settling.isEmpty ? nil : settling.reduce(0, +) / Double(settling.count),
            yesBid: yesBid, yesAsk: yesAsk)
        // Best selling value since the call, for the trailing stop (every 5th second is plenty).
        let since = ticks.filter { $0.time >= record.predictedAt && $0.time < market.closeTime }
        let peak = stride(from: 0, to: since.count, by: 5).map { since[$0] }.map { tick in
            ExitPlan.sale(at: tick.price, seconds: market.closeTime.timeIntervalSince(tick.time),
                          calledUp: record.predictedUp, market: conditions)
        }.max()
        return ExitPlan.compute(calledUp: record.predictedUp, entry: entry, market: conditions, peakSale: peak,
                                style: tradingStyle, maxLoss: effectiveStopLoss,
                                takeProfitGain: customTakeProfit > 0 ? customTakeProfit : nil)
    }

    /// The window's locked call (true = Up), if it has been made.
    private func lockedCall(for market: KalshiMarket) -> Bool? {
        guard let context = modelContext else { return nil }
        let ticker = market.ticker
        let descriptor = FetchDescriptor<PredictionRecord>(predicate: #Predicate { $0.ticker == ticker })
        return (try? context.fetch(descriptor))?.first?.predictedUp
    }

    /// Calibrated P(up) from the current price — the same odds as the Reversal Risk card.
    func priceOddsUp(for market: KalshiMarket) -> Double? {
        guard let spot, let strike = market.floorStrike, let volatility = volatilityPerRootSecond else { return nil }
        let settlementStart = market.closeTime.addingTimeInterval(-60)
        let settling = ticks.filter { $0.time >= settlementStart && $0.time < market.closeTime }.map(\.price)
        return SettlementOdds.estimate(price: spot, strike: strike, secondsRemaining: market.closeTime.timeIntervalSinceNow,
                                       volatility: volatility,
                                       settlementAverageSoFar: settling.isEmpty ? nil : settling.reduce(0, +) / Double(settling.count)).probabilityUp
    }

    /// Re-evaluates the recommendation and raises an alert for each signal that's new.
    private func updateStrategy(for market: KalshiMarket) {
        if market.ticker != alertsTicker {
            alertsTicker = market.ticker
            strategyAlerts = []
            activeSignalIDs = []
        }
        guard let fair = liveProbability else { strategy = nil; return }
        let advice = StrategyAdvisor.advise(fairUp: fair, yesBid: market.yesBid, yesAsk: market.yesAsk,
                                            secondsRemaining: market.closeTime.timeIntervalSinceNow,
                                            style: tradingStyle, priceOddsUp: priceOddsUp(for: market),
                                            calledUp: lockedCall(for: market))
        strategy = advice
        let now = Date.now
        for signal in advice.signals {
            if let index = strategyAlerts.firstIndex(where: { $0.signal.id == signal.id }) {
                // Same signal again this window: refresh it rather than adding another alert.
                strategyAlerts[index].lastSeen = now
                strategyAlerts[index].signal = signal
            } else {
                strategyAlerts.insert(StrategyAlert(time: now, lastSeen: now, signal: signal), at: 0)
                log("Alert: \(signal.title) — \(signal.justification)")
            }
        }
        activeSignalIDs = Set(advice.signals.map(\.id))
    }

    private func predictIfNeeded(for market: KalshiMarket) async {
        // Only call against Kalshi's official target, never our estimate.
        guard !isPredicting, let context = modelContext, market.floorStrike != nil, !market.strikeIsEstimate else { return }
        let ticker = market.ticker
        let existing = FetchDescriptor<PredictionRecord>(predicate: #Predicate { $0.ticker == ticker })
        guard (try? context.fetchCount(existing)) == 0 else { return }

        let elapsed = Date.now.timeIntervalSince(market.openTime)
        // Not yet time: the call locks at open + callDelay.
        guard elapsed >= callDelay else { return }
        guard elapsed <= maxPredictionDelay else {
            if lastSkippedTicker != ticker {
                lastSkippedTicker = ticker
                log("Joined \(ticker) \(Int(elapsed))s after open — waiting for the next window")
            }
            return
        }

        isPredicting = true
        defer { isPredicting = false }

        // Use fresh candles and book for the locked-in call.
        await refreshIndicatorData()
        let now = Date.now
        guard let snap = snapshot(for: market, at: now) else { return }
        let features = FeatureExtractor.features(from: snap)
        guard !features.isEmpty else { return }

        let excluded = excludedFeatures
        let probability = model.probabilityUp(features, excluding: excluded)
        // Raw (uncalibrated) average, so the log shows the composite's true drift from BRTI.
        let openWindow = ticks.filter { $0.time < market.openTime && market.openTime.timeIntervalSince($0.time) <= 60 }
        let proxyAverage = openWindow.count >= 30 ? openWindow.map(\.rawPrice).reduce(0, +) / Double(openWindow.count) : nil

        let record = PredictionRecord(
            ticker: ticker,
            openTime: market.openTime,
            closeTime: market.closeTime,
            predictedAt: now,
            strike: snap.strike,
            spotAtPrediction: snap.spot,
            proxyOpenAverage: proxyAverage,
            probabilityUp: probability,
            marketYesMid: market.yesMid,
            marketYesBid: market.yesBid,
            marketYesAsk: market.yesAsk,
            features: features,
            contributions: model.contributions(features, excluding: excluded),
            excludedFeatures: excluded
        )
        context.insert(record)
        try? context.save()
        log("Predicted \(record.predictedUp ? "UP" : "DOWN") for \(ticker) — P(up) \(Self.percent(probability))")
    }

    // MARK: Resolution

    /// Polls a just-closed window every 2 seconds until Kalshi publishes its result
    /// (usually 5–20s after the close), so accuracy and the model update at once.
    private func watchSettlement(of ticker: String) async {
        for _ in 0..<90 {
            try? await Task.sleep(for: .seconds(2))
            await resolvePending()
            let open = FetchDescriptor<PredictionRecord>(predicate: #Predicate { $0.ticker == ticker && $0.actualUp == nil })
            if ((try? modelContext?.fetchCount(open)) ?? 0) == 0 { return }
        }
    }

    private func resolvePending() async {
        guard let context = modelContext, !isResolving else { return }
        isResolving = true
        defer { isResolving = false }
        let cutoff = Date.now.addingTimeInterval(-3)
        let pending = FetchDescriptor<PredictionRecord>(
            predicate: #Predicate { $0.actualUp == nil && $0.closeTime < cutoff },
            sortBy: [SortDescriptor(\.closeTime)]
        )
        guard let records = try? context.fetch(pending), !records.isEmpty else { return }

        var resolvedAny = false
        for record in records {
            do {
                let market = try await kalshi.market(ticker: record.ticker)
                guard let wentUp = market.settledUp else { continue }
                record.actualUp = wentUp
                if riskLog.resolve(ticker: record.ticker, settledUp: wentUp) { saveRiskLog() }
                record.settlementValue = market.settlementValue
                record.resolvedAt = .now
                addLiveExample(from: record, wentUp: wentUp, in: context)
                resolvedAny = true
                log("\(record.ticker) settled \(wentUp ? "UP" : "DOWN") — prediction \(record.isCorrect == true ? "✓ correct" : "✗ wrong")")
            } catch {
                log("Resolve \(record.ticker): \(error.localizedDescription)")
            }
        }
        try? context.save()
        if resolvedAny {
            // Observed by the dashboard, so accuracy redraws the moment a result lands.
            settledCount += 1
            lastSettledAt = .now
            await retrain()
        }
    }

    // MARK: BRTI calibration

    /// At each window open, compares Kalshi's official target (the 60s BRTI average
    /// before the open) with our raw composite's average over the same 60 seconds.
    private func recordCalibrationSample(for market: KalshiMarket) {
        guard market.ticker != lastCalibratedTicker, !market.strikeIsEstimate, let strike = market.floorStrike else { return }
        let window = ticks.filter { $0.time < market.openTime && market.openTime.timeIntervalSince($0.time) <= 60 }
        guard window.count >= 40, let first = window.first, market.openTime.timeIntervalSince(first.time) >= 55 else { return }
        lastCalibratedTicker = market.ticker

        // What the index estimate was off by at this open, before learning from it.
        let estimate = window.map(\.price).reduce(0, +) / Double(window.count)
        if abs(strike - estimate) < 100 {
            trackingErrors.append(strike - estimate)
            if trackingErrors.count > 96 { trackingErrors.removeFirst(trackingErrors.count - 96) }
            UserDefaults.standard.set(trackingErrors, forKey: Keys.trackingErrors)
        }

        // Per-exchange offsets first: if they've just switched on, the composite's level
        // changes, so the old calibration (and this open's sample) no longer apply.
        let wereActive = !sourceOffsets.isEmpty
        recordSourceOffsets(strike: strike, open: market.openTime)
        if !wereActive && !sourceOffsets.isEmpty {
            calibrationSamples = []
            UserDefaults.standard.set(calibrationSamples, forKey: Keys.calibration)
            updateCalibration()
            log("Per-exchange BRTI offsets now active (\(sourceOffsets.count) exchanges); calibration restarted on the corrected composite")
            return
        }

        let rawAverage = window.map(\.rawPrice).reduce(0, +) / Double(window.count)
        let sample = strike - rawAverage
        guard abs(sample) < 100 else { return }   // a data glitch, not drift
        calibrationSamples.append(sample)
        if calibrationSamples.count > Self.calibrationSampleLimit {
            calibrationSamples.removeFirst(calibrationSamples.count - Self.calibrationSampleLimit)
        }
        UserDefaults.standard.set(calibrationSamples, forKey: Keys.calibration)
        updateCalibration()
        log("BRTI calibration: composite was \(Self.usd(-sample)) vs. official; offset now \(Self.usd(priceCalibration))")
    }

    /// Each exchange's gap to the official target at this open: official − its own 60s
    /// average, from the same seconds Kalshi averages.
    private func recordSourceOffsets(strike: Double, open: Date) {
        for (id, ticks) in sourceTicks {
            let window = ticks.filter { $0.time < open && open.timeIntervalSince($0.time) <= 60 }
            guard window.count >= 40, let first = window.first, open.timeIntervalSince(first.time) >= 55 else { continue }
            let sample = strike - window.map(\.mid).reduce(0, +) / Double(window.count)
            guard abs(sample) < 150 else { continue }   // a frozen or broken quote
            sourceOffsetSamples[id, default: []].append(sample)
            if let count = sourceOffsetSamples[id]?.count, count > Self.calibrationSampleLimit {
                sourceOffsetSamples[id]?.removeFirst(count - Self.calibrationSampleLimit)
            }
        }
        UserDefaults.standard.set(sourceOffsetSamples, forKey: Keys.sourceOffsets)
        updateSourceOffsets()
        let offsets = sourceOffsets, weights = trackingWeights
        Task { await liveFeed.setOffsets(offsets, weights: weights) }
    }

    private func updateSourceOffsets() {
        sourceOffsets = Self.offsets(from: sourceOffsetSamples)
        trackingWeights = sourceOffsets.isEmpty ? [:] : Self.trackingWeights(from: sourceOffsetSamples)
    }

    /// Relative composite weight per exchange: 1 / (variance of its offset + $4²). An
    /// exchange whose gap to the official index is steady counts more than one whose gap
    /// wanders; the $4² floor stops a short lucky run from earning an outsized weight.
    /// Exchanges with too few samples are left out (they get the median weight).
    private(set) var trackingWeights: [String: Double] = [:]

    nonisolated static func trackingWeights(from samples: [String: [Double]]) -> [String: Double] {
        samples.compactMapValues { values -> Double? in
            guard values.count >= minimumOffsetSamples else { return nil }
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count - 1)
            return 1 / (variance + 16)
        }
    }

    /// Median offset per exchange with enough samples; exchanges not yet measured get the
    /// median of the measured ones. Empty until `minimumMeasuredSources` are measured, so
    /// a single exchange's quirks never set the level.
    nonisolated static func offsets(from samples: [String: [Double]]) -> [String: Double] {
        let measured = samples.filter { $0.value.count >= minimumOffsetSamples }
            .mapValues { min(max(median($0), -100), 100) }
        guard measured.count >= minimumMeasuredSources else { return [:] }
        let typical = median(Array(measured.values))
        return Dictionary(uniqueKeysWithValues: CompositePriceClient.Exchange.allCases.map { exchange in
            (exchange.rawValue, measured[exchange.rawValue] ?? typical)
        })
    }

    nonisolated static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Median is robust to the occasional odd window; capped so a bad run can't run away.
    private func updateCalibration() {
        calibrationSampleCount = calibrationSamples.count
        guard !calibrationSamples.isEmpty else { priceCalibration = 0; return }
        let sorted = calibrationSamples.sorted()
        let mid = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        priceCalibration = min(max(median, -50), 50)
    }

    // MARK: Learning

    private func addLiveExample(from record: PredictionRecord, wentUp: Bool, in context: ModelContext) {
        let ticker = record.ticker
        // A live example has the full feature set, so it replaces a rebuilt one.
        let existing = FetchDescriptor<TrainingExample>(predicate: #Predicate { $0.ticker == ticker })
        for example in (try? context.fetch(existing)) ?? [] { context.delete(example) }
        // The call time it was actually made at, to the nearest minute.
        let delay = (record.predictedAt.timeIntervalSince(record.openTime) / 60).rounded() * 60
        context.insert(TrainingExample(ticker: ticker, openTime: record.openTime, wentUp: wentUp,
                                       isLive: true, callDelay: delay, features: record.features))
    }

    /// Rebuilds features for settled windows from Kalshi's full history (up to 180 days) that the bot has no
    /// complete training example for at the current call time: Kalshi settlements and
    /// odds, and Coinbase 1-minute candles for the price indicators.
    private func catchUpHistory() async {
        guard let context = modelContext else { return }
        guard !isBackfilling else {
            catchUpRequested = true
            return
        }
        isBackfilling = true
        let generation = historyGeneration
        let delay = callDelay
        defer {
            isBackfilling = false
            backfillStatus = nil
            if catchUpRequested {
                catchUpRequested = false
                Task { await catchUpHistory() }
            }
        }

        do {
            // Complete = has Kalshi odds and was built at the current call time. Anything
            // else for the same window is replaced.
            let existing = (try? context.fetch(FetchDescriptor<TrainingExample>())) ?? []
            let complete = Set(existing.filter {
                abs($0.callDelay - delay) < 1 && ($0.isLive || $0.sample.features[.kalshiImplied] != nil)
            }.map(\.ticker))
            let incomplete = Dictionary(existing.filter { !complete.contains($0.ticker) }.map { ($0.ticker, $0) },
                                        uniquingKeysWith: { first, _ in first })

            // Public market history, rebuilt in full even after a reset: a reset clears the
            // bot's own logs and learning, not what the market did. Downloads are cached on
            // disk, so only windows and candles newer than the cache are fetched.
            backfillStatus = "Fetching settled windows…"
            let since = Date.now.addingTimeInterval(-Self.historyWindow)
            var cache = await Task.detached { HistoryCache.load() }.value
            let newestCached = cache.markets.values.map(\.closeTime).max()
            // An hour of overlap catches windows that settled late.
            let fetchFrom = max(since, newestCached?.addingTimeInterval(-3600) ?? since)
            cache.merge(markets: try await kalshi.settledMarkets(closedAfter: fetchFrom))
            cache.prune(before: since)
            let all = cache.markets.values
                .filter { $0.settledUp != nil && ($0.floorStrike ?? 0) > 0 && $0.openTime >= since }
                .sorted { $0.openTime < $1.openTime }

            // Odds at every call-time option, so each option's accuracy can be shown.
            let unchecked = all.filter { !cache.oddsChecked.contains($0.ticker) }
            if !unchecked.isEmpty {
                backfillStatus = "Fetching Kalshi odds for \(unchecked.count) windows…"
                let offsets = Self.callTimeOptions.map { TimeInterval($0 * 60) }
                let (fresh, checked, failedBatches, oddsError) = await kalshi.yesMids(unchecked, at: offsets)
                cache.merge(mids: fresh, checked: checked)
                if failedBatches > 0 {
                    log("Kalshi odds: \(failedBatches) batch(es) failed (\(oddsError?.localizedDescription ?? "unknown error")); those windows retry on the next catch-up")
                }
            }
            updateCallTimeAccuracy(markets: all, cache: cache)

            let markets = all.filter { !complete.contains($0.ticker) }
            guard let earliest = markets.first?.openTime, let latest = markets.last?.openTime else {
                let saved = cache
                await Task.detached { saved.save() }.value
                await refitRiskCalibration(from: saved)
                await retrain()
                return
            }

            // Candles from 160 min before the earliest window to the latest call time.
            let needed = cache.missingCandleRanges(from: earliest.addingTimeInterval(-160 * 60),
                                                   to: latest.addingTimeInterval(delay))
            if !needed.isEmpty {
                log("Rebuilding \(markets.count) past windows for training…")
                backfillStatus = "Fetching price history for \(markets.count) windows…"
                for range in needed {
                    cache.merge(candles: try await coinbase.oneMinuteCandles(from: range.start, to: range.end))
                }
            } else {
                log("Rebuilding \(markets.count) past windows for training (from saved history)…")
            }
            let saved = cache
            await Task.detached { saved.save() }.value
            await refitRiskCalibration(from: saved)
            let history = cache.candles
            let mids: [TimeInterval: [String: Double]] = [delay: cache.mids(at: delay)]

            // A reset or call-time change happened mid-rebuild: its own rebuild runs instead.
            guard generation == historyGeneration, delay == callDelay else {
                catchUpRequested = true
                return
            }

            let callMids = mids[delay] ?? [:]
            var added = 0, withOdds = 0
            for market in markets {
                guard let wentUp = market.settledUp, let strike = market.floorStrike,
                      var features = FeatureExtractor.historicalFeatures(
                        candles: history, at: market.openTime.addingTimeInterval(delay), strike: strike,
                        minutesRemaining: (market.closeTime.timeIntervalSince(market.openTime) - delay) / 60)
                else { continue }
                if let mid = callMids[market.ticker] {
                    features[.kalshiImplied] = FeatureExtractor.kalshiFeature(yesMid: mid)
                    withOdds += 1
                }
                if let old = incomplete[market.ticker] { context.delete(old) }
                context.insert(TrainingExample(ticker: market.ticker, openTime: market.openTime, wentUp: wentUp,
                                               isLive: false, callDelay: delay, features: features))
                added += 1
            }
            try? context.save()
            log("Added \(added) past windows at +\(callDelayMinutes) min (\(withOdds) with Kalshi odds)")
        } catch {
            log("History: \(error.localizedDescription)")
        }
        await retrain()
    }

    /// Kalshi-favorite accuracy at each call time, over every cached window with odds.
    private func updateCallTimeAccuracy(markets: [KalshiMarket], cache: HistoryCache) {
        guard markets.count >= 500 else { return }
        for minutes in Self.callTimeOptions {
            let atOffset = cache.mids(at: TimeInterval(minutes * 60))
            guard atOffset.count >= 500 else { continue }
            let outcomes = markets.compactMap { market -> Bool? in
                guard let mid = atOffset[market.ticker], let up = market.settledUp else { return nil }
                return (mid >= 0.5) == up
            }
            callTimeAccuracy[minutes] = Double(outcomes.count(where: \.self)) / Double(outcomes.count)
        }
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: callTimeAccuracy.map { (String($0.key), $0.value) }),
                                  forKey: Keys.callTimeAccuracy)
        confidenceHistory = Self.confidenceHistory(markets: markets, cache: cache)
        UserDefaults.standard.set(confidenceHistory.mapValues { [$0.won, $0.total] }, forKey: Keys.confidenceHistory)
    }

    /// Tallies past windows by call minute and confidence band: how often Kalshi's
    /// favorite — the side the bot calls when following Kalshi's odds — won.
    nonisolated static func confidenceHistory(markets: [KalshiMarket], cache: HistoryCache) -> [String: (won: Int, total: Int)] {
        var result: [String: (won: Int, total: Int)] = [:]
        for minutes in callTimeOptions {
            let mids = cache.mids(at: TimeInterval(minutes * 60))
            for market in markets {
                guard let mid = mids[market.ticker], let up = market.settledUp else { continue }
                let key = "\(minutes):\(confidenceBand(max(mid, 1 - mid)))"
                var entry = result[key] ?? (0, 0)
                entry.total += 1
                if (mid >= 0.5) == up { entry.won += 1 }
                result[key] = entry
            }
        }
        return result
    }

    /// A new call time: rebuilt history is redone at the new moment. Live examples made
    /// at other call times are kept but not trained on.
    private func callTimeChanged() async {
        log("Call time set to +\(callDelayMinutes) min; rebuilding history at the new call time")
        model = .starting(excluding: excludedFeatures, promoted: promoted)
        recomputeLive()
        historyGeneration += 1
        if let context = modelContext { discardOutdatedHistory(in: context) }
        await catchUpHistory()
    }

    /// Rebuilt windows from an older feature definition or another call time are deleted
    /// so the next catch-up redoes them. Live examples are kept — they're real calls.
    private func discardOutdatedHistory(in context: ModelContext) {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: Keys.historyFeatureVersion) != Self.historyFeatureVersion
                || defaults.double(forKey: Keys.historyCallDelay) != callDelay else { return }
        let rebuilt = FetchDescriptor<TrainingExample>(predicate: #Predicate { !$0.isLive })
        for example in (try? context.fetch(rebuilt)) ?? [] { context.delete(example) }
        try? context.save()
        defaults.set(Self.historyFeatureVersion, forKey: Keys.historyFeatureVersion)
        defaults.set(callDelay, forKey: Keys.historyCallDelay)
        log("Training history cleared for rebuilding (format or call time changed)")
    }

    /// Refits the model on every stored example at the current call time, off the main actor.
    private func retrain() async {
        guard let context = modelContext else { return }
        guard !isTraining else {
            retrainRequested = true
            return
        }
        let delay = callDelay
        let examples = ((try? context.fetch(FetchDescriptor<TrainingExample>())) ?? []).filter { abs($0.callDelay - delay) < 1 }
        liveExampleCount = examples.count(where: \.isLive)
        historyExampleCount = examples.count - liveExampleCount
        guard !examples.isEmpty else { return }

        isTraining = true
        defer {
            isTraining = false
            // Something changed mid-fit (new example, settings toggle, promotion) — fit again.
            if retrainRequested {
                retrainRequested = false
                Task { await retrain() }
            }
        }
        let samples = examples.map(\.sample)
        let excluded = excludedFeatures
        let promotedNow = promoted
        let marks = trialMarks
        // Learned weights switched on before 2.22 (with no significance check) are judged
        // afresh, as if off; the "stay on" allowance applies only to a significant switch.
        let usingLearned = model.usesLearnedWeights && model.evaluation?.gainMargin != nil
        let trained = await Task.detached(priority: .utility) {
            ModelTrainer.train(samples, excluding: excluded, promoted: promotedNow, lastTrialMarks: marks,
                               usingLearned: usingLearned)
        }.value

        model = trained
        saveModel()
        recomputeLive()
        if let evaluation = trained.evaluation {
            let baseline = trained.marketAnchored ? "Kalshi" : "starting weights"
            let blocks = evaluation.folds.map { "won \(evaluation.foldsWon ?? 0) of \($0) blocks, " } ?? ""
            log("Retrained on \(trained.trainingCount) windows — learned weights \(blocks)\(Self.percent(evaluation.accuracy)) vs. \(Self.percent(evaluation.priorAccuracy)) \(baseline) on \(evaluation.holdoutCount) held-out windows; using \(trained.usesLearnedWeights ? "learned weights" : baseline)")
        } else {
            log("Retrained on \(trained.trainingCount) windows")
        }
        applyTrials(trained.trials)
    }

    /// Promotes a context signal after `trialStreakToChange` consecutive significant gains;
    /// demotes a promoted one after as many consecutive trials without one. Only results
    /// judged on fresh windows count (see `trialMarks`).
    private func applyTrials(_ trials: [String: TrialResult]) {
        var changed = false
        for (raw, result) in trials {
            guard let key = FeatureKey(rawValue: raw), result.counts else { continue }
            if let mark = result.mark { trialMarks[raw] = mark }
            let streak = trialStreaks[raw] ?? 0
            trialStreaks[raw] = result.isSignificantGain ? max(streak, 0) + 1 : min(streak, 0) - 1
            let current = trialStreaks[raw] ?? 0
            if !promoted.contains(key), current >= Self.trialStreakToChange {
                promoted.insert(key)
                changed = true
                log("Promoted \(key.title) into the model: it improved predictions on \(current) separate sets of fresh windows in a row")
            } else if promoted.contains(key), current <= -Self.trialStreakToChange {
                promoted.remove(key)
                changed = true
                log("Demoted \(key.title): it stopped improving held-out predictions")
            }
        }
        savePromotions()
        if changed {
            trialStreaks = trialStreaks.mapValues { _ in 0 }
            savePromotions()
            Task { await retrain() }
        }
    }

    private func savePromotions() {
        UserDefaults.standard.set(promoted.map(\.rawValue).sorted(), forKey: Keys.promoted)
        UserDefaults.standard.set(trialStreaks, forKey: Keys.trialStreaks)
        UserDefaults.standard.set(trialMarks, forKey: Keys.trialMarks)
    }

    // MARK: Helpers

    /// Price volatility in dollars per √second, from the last hour of 1-minute candles —
    /// the measure a 30-day backtest found well calibrated (≈95% of settlements inside
    /// ±2σ). Sampling the 1-second composite understates it: the price can sit still for
    /// several seconds between quote changes. Falls back to the ticks without candles.
    /// Weighted as the latest risk calibration chose (equally over the hour, or toward the
    /// last 15–30 minutes), so the card reacts to a sudden change in pace as fast as the
    /// history showed is useful.
    var volatilityPerRootSecond: Double? {
        let closes = candles.map(\.close)
        if closes.count >= 31,
           let volatility = RiskCalibration.volatility(closes: Array(closes.suffix(61)), halfLife: riskCalibration?.volatilityHalfLife) {
            return volatility
        }
        return Indicators.realizedVolatility(ticks.map { (time: $0.time, price: $0.price) })
    }

    /// The Reversal Risk card's assessment for `market` right now.
    func reversalRisk(for market: KalshiMarket, at now: Date = .now) -> ReversalRisk? {
        guard let strike = market.floorStrike, let price = spot, let volatility = volatilityPerRootSecond else { return nil }
        let samples = ticks.map { (time: $0.time, price: $0.price) }
        // Prices already inside the settlement minute, once it has begun.
        let settlementStart = market.closeTime.addingTimeInterval(-60)
        let settling = samples.filter { $0.time >= settlementStart && $0.time < market.closeTime }.map(\.price)
        let extremes = WindowChart.extremes(windowPrices(for: market), from: market.openTime, to: market.closeTime)
        return ReversalRisk.assess(.init(
            price: price,
            strike: strike,
            secondsRemaining: market.closeTime.timeIntervalSince(now),
            volatility: volatility,
            settlementAverageSoFar: settling.isEmpty ? nil : settling.reduce(0, +) / Double(settling.count),
            windowHigh: extremes?.high.price,
            windowLow: extremes?.low.price,
            // The sample closest to 3 minutes ago (within a few seconds).
            priceEarlier: samples.last(where: { now.timeIntervalSince($0.time) >= 180 })
                .flatMap { now.timeIntervalSince($0.time) <= 185 ? $0.price : nil },
            // Median absolute error → 1σ, for a normal error.
            priceUncertainty: trackingError.map { $0 / 0.6745 } ?? 0,
            kalshiYesMid: market.yesMid,
            calibration: riskCalibration))
    }

    /// Logs the card's flip chance at :30 past each minute of the window, for its live check.
    private func logRiskIfDue(at now: Date = .now) {
        let minute = Int(now.timeIntervalSince1970 / 60)
        guard Int(now.timeIntervalSince1970) % 60 >= 30, minute != lastRiskLogMinute,
              let market = currentMarket, !market.strikeIsEstimate, now >= market.openTime, now < market.closeTime,
              let risk = reversalRisk(for: market, at: now) else { return }
        lastRiskLogMinute = minute
        riskLog.append(.init(ticker: market.ticker, time: now, flip: risk.flipProbability, leaderUp: risk.currentlyUp))
        saveRiskLog()
    }

    private func saveRiskLog() {
        let log = riskLog
        Task.detached { log.save() }
    }

    /// Refits the card's corrections from the saved history, at most hourly.
    private func refitRiskCalibration(from cache: HistoryCache) async {
        if let fitted = riskCalibration?.fittedAt, Date.now.timeIntervalSince(fitted) < 3600 { return }
        guard let calibration = await Task.detached(operation: { RiskCalibration.best(from: cache) }).value else { return }
        riskCalibration = calibration
        if let data = try? JSONEncoder().encode(calibration) {
            UserDefaults.standard.set(data, forKey: Keys.riskCalibration)
        }
        let e = calibration.evaluation
        let weighting = calibration.volatilityHalfLife.map { "\(Int($0))-min half-life" } ?? "last hour, equal"
        log("Reversal risk recalibrated on \(calibration.windows) windows (\(weighting) volatility): held-out Brier \(String(format: "%.4f", calibration.score)) vs. Kalshi \(String(format: "%.4f", e.kalshi)) and fixed \(String(format: "%.4f", e.fixedFlip))\(calibration.blend != nil ? "; blending Kalshi's price" : "")")
    }

    /// Completed 1-minute candles from the 1-second ticks. Starts at the first full
    /// minute of data and stops before the minute still forming.
    /// Prices actually reached in `market`'s window, oldest first: the bot's 1-second
    /// index samples, plus — for minutes before the bot had samples (it started or
    /// restarted mid-window) — the exchange's traded 1-minute highs and lows, shifted to
    /// the index's level so both read on the same scale.
    func windowPrices(for market: KalshiMarket) -> [(time: Date, price: Double)] {
        let live = ticks.filter { $0.time >= market.openTime && $0.time < market.closeTime }
        var prices = live.map { (time: $0.time, price: $0.price) }
        let firstLive = live.first?.time ?? market.closeTime
        guard firstLive.timeIntervalSince(market.openTime) >= 60 else { return prices }
        // Level offset: the index's first sample against the exchange's close that minute.
        let offset: Double = {
            guard let first = live.first,
                  let candle = candles.last(where: { $0.time <= first.time && first.time < $0.time.addingTimeInterval(60) })
            else { return priceCalibration }
            return first.price - candle.close
        }()
        let missed = candles.filter { $0.time >= market.openTime && $0.time.addingTimeInterval(60) <= firstLive }
        let backfill = missed.flatMap { candle in
            [(time: candle.time.addingTimeInterval(20), price: candle.high + offset),
             (time: candle.time.addingTimeInterval(40), price: candle.low + offset)]
        }
        prices.insert(contentsOf: backfill, at: 0)
        return prices
    }

    var completedMinuteCandles: [Candle] {
        guard let first = ticks.first?.time else { return [] }
        let start = Date(timeIntervalSince1970: (first.timeIntervalSince1970 / 60).rounded(.up) * 60)
        let currentMinute = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        return Indicators.minuteCandles(ticks.map { (time: $0.time, price: $0.price) }, from: start, to: currentMinute)
    }

    private func saveModel() {
        if let data = try? JSONEncoder().encode(model) {
            UserDefaults.standard.set(data, forKey: Keys.model)
        }
    }

    private func log(_ message: String) {
        AppLog.shared.append(message)
        activity.insert(ActivityEntry(time: .now, message: message), at: 0)
        if activity.count > 100 { activity.removeLast(activity.count - 100) }
    }

    /// The settings in effect, for crash reports — nothing personal (the stake is left out).
    var crashReportSettings: [String: String] {
        [
            "call_delay_minutes": "\(callDelayMinutes)",
            "minimum_call_confidence": "\(minimumCallConfidence)",
            "trading_style": tradingStyle.title,
            "use_kalshi_odds": "\(useKalshiOdds)",
            "keep_mac_awake": "\(keepMacAwake)",
            "custom_stop_loss": "\(customStopLoss)",
            "custom_take_profit": "\(customTakeProfit)",
            "is_running": "\(isRunning)",
        ]
    }

    nonisolated static func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    nonisolated static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(1)))
    }
}
