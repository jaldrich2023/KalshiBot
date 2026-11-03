//
//  IndicatorsView.swift
//  KalshiBot
//

import SwiftUI
import SwiftData

/// The Indicators tab: one pane per indicator with its value when the call locked and
/// now, what it measures, what the current reading means, and how it's moving the call.
struct IndicatorsView: View {
    @Environment(BotEngine.self) private var engine
    let records: [PredictionRecord]

    private static let columns = 3

    var body: some View {
        let ticker = engine.currentMarket?.ticker
        let record = ticker.flatMap { ticker in records.first { $0.ticker == ticker } }
        // Decode the locked snapshot once per render rather than per pane.
        let open = OpenSnapshot(record: record)
        let liveContributions = engine.model.contributions(engine.liveFeatures, excluding: engine.excludedFeatures)

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                PredictionSummary(record: record)
                LearnedWeightsConditions()

                section("Model inputs", detail: "The only signals that can move the call. Each starts at zero weight and has to earn it on held-out windows.")
                grid(FeatureKey.allCases.filter(engine.model.isActive), open: open, liveContributions: liveContributions)

                section("Context only", detail: "Each moves closely with a model input, so it isn't counted — unless it wins promotion: on every retrain it's trialled, and three significant wins in a row promote it.")
                grid(FeatureKey.allCases.filter { !engine.model.isActive($0) }, open: open, liveContributions: liveContributions)
            }
            .padding(20)
        }
        .scrollContentBackground(.hidden)
    }

    private func section(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.top, 6)
        .accessibilityAddTraits(.isHeader)
    }

    /// Fixed three-column grid; panes in a row share the row's height.
    private func grid(_ keys: [FeatureKey], open: OpenSnapshot, liveContributions: [FeatureKey: Double]) -> some View {
        let rows = stride(from: 0, to: keys.count, by: Self.columns).map { Array(keys[$0..<min($0 + Self.columns, keys.count)]) }
        return Grid(horizontalSpacing: Theme.spacing, verticalSpacing: Theme.spacing) {
            ForEach(rows, id: \.self) { row in
                GridRow {
                    ForEach(row) { key in
                        IndicatorPane(key: key, open: open, liveValue: engine.liveFeatures[key],
                                      liveContribution: liveContributions[key])
                    }
                    // Keep the last row's panes the same width as the rest.
                    ForEach(0..<(Self.columns - row.count), id: \.self) { _ in
                        Color.clear.gridCellUnsizedAxes(.vertical)
                    }
                }
            }
        }
    }
}

/// The call locked for this window (at open + the engine's call delay), decoded once.
private struct OpenSnapshot {
    let record: PredictionRecord?
    let features: [FeatureKey: Double]
    let contributions: [FeatureKey: Double]
    let excluded: Set<FeatureKey>

    init(record: PredictionRecord?) {
        self.record = record
        features = record?.features ?? [:]
        contributions = record?.contributions ?? [:]
        excluded = record?.excluded ?? []
    }
}

/// P(up) at the call vs. now, and what the model is anchored to.
private struct PredictionSummary: View {
    @Environment(BotEngine.self) private var engine
    let record: PredictionRecord?

    var body: some View {
        Panel(title: "Current Window", systemImage: "scope") {
            HStack(alignment: .top, spacing: 40) {
                metric("P(up) at call", record.map { BotEngine.percent($0.probabilityUp) } ?? "—",
                       detail: record.map { "Called \($0.predictedUp ? "Up" : "Down") at \($0.predictedAt.formatted(date: .omitted, time: .shortened))" } ?? "No call locked this window")
                metric("P(up) now", engine.liveProbability.map(BotEngine.percent) ?? "—", detail: "Live, informational only")
                metric("Kalshi Yes now", engine.currentMarket?.yesMid.map(BotEngine.percent) ?? "—", detail: "The market's own odds")
                metric("Predicting with", engine.model.usesLearnedWeights ? "Learned weights" : (engine.model.marketAnchored ? "Kalshi's odds" : "Starting weights"),
                       detail: "Trained on \(engine.model.trainingCount.formatted()) windows")
                Spacer(minLength: 0)
            }
        }
        .font(.callout)
    }

    private func metric(_ label: String, _ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).heroNumber(size: 24)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The three conditions for predicting with learned weights instead of Kalshi's odds
/// (or the starting weights), and where each one stands after the latest retrain.
private struct LearnedWeightsConditions: View {
    @Environment(BotEngine.self) private var engine

    var body: some View {
        let model = engine.model
        let baseline = model.marketAnchored ? "Kalshi's odds" : "the starting weights"
        let e = model.evaluation
        let folds = e?.folds ?? ModelTrainer.walkForwardFolds
        let won = e?.foldsWon ?? 0
        let needed = max(folds - 1, 1)
        let enough = model.trainingCount >= ModelTrainer.minimumForEvaluation
        let mostBlocks = e != nil && won >= needed
        let overall = e?.isSignificantGain ?? false

        Panel(title: "Switching to learned weights", systemImage: "checklist") {
            Text(model.usesLearnedWeights
                 ? "The model is predicting with learned weights. They stay on unless they fall clearly behind \(baseline) — winning fewer than half the blocks, or doing significantly worse overall — so a small dip doesn't flip the model back and forth."
                 : "The model predicts with \(baseline) until learned weights meet all three conditions. They're re-checked after every settled window, so there's no fixed number of windows to wait for — only the evidence.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                condition(met: enough, "Enough history",
                          enough ? "\(model.trainingCount.formatted()) settled windows with Kalshi's odds (needs \(ModelTrainer.minimumForEvaluation))."
                                 : "\(model.trainingCount.formatted()) of the \(ModelTrainer.minimumForEvaluation) settled windows needed — \(ModelTrainer.minimumForEvaluation - model.trainingCount) more.")
                condition(met: mostBlocks, "Win most walk-forward blocks",
                          e == nil ? "Not scored yet."
                                   : "Won \(won) of \(folds); needs \(needed). The newest \(Int(ModelTrainer.walkForwardShare * 100))% of windows (\(e!.holdoutCount.formatted())) is split into \(folds) blocks, each predicted by a model fitted only on the windows before it.")
                condition(met: overall, "A real gain over \(baseline)",
                          overallDetail(e, baseline: baseline))
            }
        }
        .font(.callout)
    }

    private func overallDetail(_ e: ModelEvaluation?, baseline: String) -> String {
        guard let e else { return "Not scored yet." }
        func f(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(4))) }
        guard let learned = e.logLoss, let prior = e.priorLogLoss, let gain = e.gain, let margin = e.gainMargin else {
            return "Brier \(f(e.brierScore)) learned vs. \(f(e.priorBrierScore)) \(baseline) (the full check appears after the next retrain)."
        }
        let milli = { (x: Double) in (x * 1000).formatted(.number.precision(.fractionLength(2))) }
        let verdict = e.isSignificantGain ? "bigger than its margin, as needed"
                    : gain > 0 ? "smaller than its margin, so it could be chance"
                    : "no gain"
        return "Log-loss across those blocks: \(f(learned)) learned vs. \(f(prior)) \(baseline). Gain \(gain >= 0 ? "+" : "−")\(milli(abs(gain))) ± \(milli(margin)) milli per window — \(verdict). Accuracy \(BotEngine.percent(e.accuracy)) vs. \(BotEngine.percent(e.priorAccuracy))."
    }

    private func condition(met: Bool, _ title: String, _ detail: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(met ? .green : .secondary)
                .accessibilityLabel(met ? "Met" : "Not met")
            Text(title).fontWeight(.semibold)
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One indicator: value at the call and now, what it measures, what the current
/// reading means, and how it's moving the prediction.
private struct IndicatorPane: View {
    @Environment(BotEngine.self) private var engine
    let key: FeatureKey
    let open: OpenSnapshot
    let liveValue: Double?
    let liveContribution: Double?

    var body: some View {
        Panel(title: key.title, systemImage: engine.model.isActive(key) ? "function" : "info.circle") {
            VStack(alignment: .leading, spacing: 10) {
                content(openText: open.features[key].map(key.displayValue),
                        nowText: liveValue.map(key.displayValue),
                        weightText: weightText,
                        reading: liveValue.map(key.interpretation) ?? "Waiting for live data…",
                        effect: effectText)
            }
            .reservingSpace {
                // Worst case: the longest reading and effect this indicator can produce.
                VStack(alignment: .leading, spacing: 10) {
                    content(openText: "−8.88 ATR", nowText: "−8.88 ATR", weightText: "Not used", reading: key.longestInterpretation,
                            effect: IndicatorEffect.longestDescription(key) + " At the call it shifted P(up) −88.8 pts.")
                }
            }
        }
        .font(.callout)
    }

    /// Green/red: which way this indicator points now. If it carries weight, the way it
    /// actually pushes the prediction; otherwise the way its reading leans.
    @ViewBuilder
    private var direction: some View {
        if let liveContribution, abs(liveContribution) > 0.0005 {
            DirectionPill(value: liveContribution, verb: "Pushing", neutralBelow: 0.0005)
        } else if let liveValue {
            DirectionPill(value: key.lean(liveValue), verb: "Favors")
        } else {
            DirectionPill(value: 0)
        }
    }

    /// The model's current weight on this indicator (log-odds per unit of its signal).
    private var weightText: String {
        if engine.excludedFeatures.contains(key) { return "Off" }
        guard engine.model.isActive(key) else { return "Not used" }
        let w = engine.model.weight(for: key)
        return "\(w >= 0 ? "+" : "−")\(abs(w).formatted(.number.precision(.fractionLength(3))))"
    }

    private var weightHelp: String {
        if engine.excludedFeatures.contains(key) { return "Turned off: “Use Kalshi odds” is unchecked." }
        guard engine.model.isActive(key) else {
            return "Context only: this indicator carries no weight unless it's promoted by winning held-out trials."
        }
        let source = engine.model.usesLearnedWeights ? "learned on held-out windows" : "the starting weight (learned weights haven't beaten it yet)"
        let trained = engine.model.trainedAt.map { ", last retrained \($0.formatted(date: .omitted, time: .standard))" } ?? ""
        return "How strongly this input moves the call, in log-odds per unit of its signal — \(source)\(trained). Updates after each settled window."
    }

    private var badgeText: String {
        if key.isBaseInput { return "Model input" }
        return engine.model.isActive(key) ? "Promoted" : "Context"
    }

    private var effectText: String {
        var text = IndicatorEffect.describe(key, model: engine.model, excluded: engine.excludedFeatures,
                                            probabilityUp: engine.liveProbability, contribution: liveContribution,
                                            kalshiYes: engine.currentMarket?.yesMid)
        // How it moved the call that was actually locked in.
        if engine.model.isActive(key), !open.excluded.contains(key), let record = open.record,
           let contribution = open.contributions[key], abs(contribution) > 0.0005 {
            let pts = IndicatorEffect.points(probabilityUp: record.probabilityUp, contribution: contribution)
            text += " At the call it shifted P(up) \(pts >= 0 ? "+" : "−")\(abs(pts).formatted(.number.precision(.fractionLength(1)))) pts."
        }
        return text
    }

    @ViewBuilder
    private func content(openText: String?, nowText: String?, weightText: String, reading: String, effect: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            value("At call", openText)
            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            value("Now", nowText)
            value("Weight", weightText)
                .help(weightHelp)
            value("Windows", windowsText)
                .help(key.isBaseInput ? "Settled windows the model is trained on; this input is in every one."
                                      : "Settled windows that have this signal, out of the \(engine.model.trainingCount.formatted()) the model is trained on.")
            Spacer(minLength: 0)
            direction
            Text(badgeText)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.white.opacity(engine.model.isActive(key) ? 0.16 : 0.07), in: .capsule)
        }

        Text(key.summary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        labeled("Reading now", reading)
        labeled("Effect on prediction", effect)
        if !key.isBaseInput {
            labeled(engine.promotionProgress(for: key)?.isPromoted == true ? "Demotion" : "Promotion", promotionText)
        }
    }

    private var windowsText: String {
        if key.isBaseInput { return engine.model.trainingCount.formatted() }
        return engine.promotionProgress(for: key).map { $0.windows.formatted() } ?? "—"
    }

    /// How far this context signal is from changing status, in settled windows.
    private var promotionText: String {
        guard let p = engine.promotionProgress(for: key) else { return "Not trialled yet." }
        let goal = Self.goal(p)
        let count = "\(p.streak) of \(BotEngine.trialStreakToChange) \(p.isPromoted ? "trials without a gain" : "significant wins") in a row so far."
        if p.isLiveOnly && p.windows < ModelTrainer.minimumLiveTrialWindows {
            return "Live windows only: \(p.windows.formatted()) of the \(ModelTrainer.minimumLiveTrialWindows) needed to start trials. At least \(p.windowsNeeded.formatted()) more live windows before it could \(goal)."
        }
        let next = p.windowsToNextTrial == 0 ? "its next result counts at the next retrain" : "its next result counts after \(p.windowsToNextTrial.formatted()) more settled windows"
        return "\(count) \(next.prefix(1).uppercased() + next.dropFirst()); at least \(p.windowsNeeded.formatted()) more windows before it could \(goal), if every counted result goes its way."
    }

    private static func goal(_ p: BotEngine.PromotionProgress) -> String {
        p.isPromoted ? "be demoted" : "be promoted"
    }

    private func value(_ label: String, _ text: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(text ?? "—").heroNumber(size: 20)
        }
        .accessibilityElement(children: .combine)
    }

    private func labeled(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    @Previewable @State var engine = BotEngine()
    let container = try! ModelContainer(for: PredictionRecord.self, TrainingExample.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    IndicatorsView(records: [])
        .environment(engine)
        .frame(width: 1819, height: 1500)
        .background(AppBackground())
        .preferredColorScheme(.dark)
        .task { engine.start(context: container.mainContext) }
        .modelContainer(container)
}
