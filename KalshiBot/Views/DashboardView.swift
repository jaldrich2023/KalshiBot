//
//  DashboardView.swift
//  KalshiBot
//

import SwiftUI
import AppKit

struct DashboardView: View {
    @Environment(BotEngine.self) private var engine
    let records: [PredictionRecord]

    /// Reads `settledCount` so the accuracy redraws as soon as a window settles, even
    /// before SwiftData's query notices the changed record.
    private var stats: AccuracyStats {
        _ = engine.settledCount
        return AccuracyStats(records: engine.calls(records))
    }

    private var currentRecord: PredictionRecord? {
        guard let ticker = engine.currentMarket?.ticker else { return nil }
        return records.first { $0.ticker == ticker }
    }

    /// Measured width of the dashboard content, for the shared column grid.
    @State private var contentWidth: CGFloat = 0
    /// Measured height of the dashboard content; the strategy sidebar matches it.
    @State private var contentHeight: CGFloat = 0
    /// Height the window needs to show the whole dashboard without scrolling
    /// (content + padding + the toolbar inset). The app window sizes itself to this.
    @AppStorage("dashboardRequiredHeight") private var requiredHeight: Double = 0
    @State private var topInset: CGFloat = 0
    /// Measured height of the candle chart's row; the 60s average chart matches it.
    @State private var candleRowHeight: CGFloat = 0

    /// One of five equal columns. The top-row cards each take one; the candle-pattern
    /// card beside the candle chart takes one too, so it lines up with the card above.
    private static let columns: CGFloat = 5
    private var columnWidth: CGFloat {
        max((contentWidth - (Self.columns - 1) * Theme.spacing) / Self.columns, 0)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            dashboard
            // The strategy sidebar stays pinned to the right edge while the dashboard scrolls.
            if let market = engine.currentMarket {
                StrategyCard(market: market, record: currentRecord)
                    // Exactly as tall as the cards on the left combined.
                    .frame(width: 400, height: contentHeight > 0 ? contentHeight : nil)
                    .padding([.top, .trailing], 20)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
        .onChange(of: contentHeight) { updateRequiredHeight() }
        .onChange(of: topInset) { updateRequiredHeight() }
    }

    private func updateRequiredHeight() {
        guard contentHeight > 0 else { return }
        let needed = Double((contentHeight + 40 + topInset).rounded(.up))
        // Ignore sub-point jitter so the window doesn't resize for nothing.
        if abs(needed - requiredHeight) >= 1 { requiredHeight = needed }
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                // fixedSize + maxHeight: .infinity stretches each card to the tallest in its row.
                HStack(alignment: .top, spacing: Theme.spacing) {
                    windowPanel.frame(width: columnWidth)
                    predictionPanel.frame(width: columnWidth)
                    Group {
                        if let market = engine.currentMarket {
                            ReversalRiskCard(market: market)
                        } else {
                            Panel(title: "Reversal Risk", systemImage: "arrow.triangle.2.circlepath") {
                                Text("Waiting for the current window…").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: columnWidth)
                    AccuracyPanel(stats: stats, skipped: records.filter { $0.isResolved && engine.isNoCall($0) }.count)
                        .frame(width: columnWidth)
                    ModelPanel(stats: stats, records: records).frame(width: columnWidth)
                }
                .fixedSize(horizontal: false, vertical: true)
                if let market = engine.currentMarket {
                    // As tall as the candle row below, so the two charts match.
                    WindowPriceChart(market: market, record: currentRecord)
                        .frame(height: candleRowHeight > 0 ? candleRowHeight : nil)
                        .fixedSize(horizontal: false, vertical: candleRowHeight == 0)
                    HStack(alignment: .top, spacing: Theme.spacing) {
                        WindowCandleChart(market: market)
                        CandlePatternCard(market: market)
                            .frame(width: columnWidth)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { candleRowHeight = $0 }
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: {
                contentWidth = $0.width
                contentHeight = $0.height
            }
            .padding(20)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Panels

    private var windowPanel: some View {
        Panel(title: "Current Window", systemImage: "clock") {
            if let spot = engine.spot {
                VStack(alignment: .leading, spacing: 2) {
                    Text(BotEngine.usd(spot))
                        .heroNumber()
                    if let strike = engine.currentMarket?.floorStrike {
                        let diff = spot - strike
                        Label((diff >= 0 ? "+" : "") + BotEngine.usd(diff) + " vs. target",
                              systemImage: diff >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.callout.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(diff >= 0 ? .green : .red)
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                Text("Fetching prices…").foregroundStyle(.secondary)
            }

            Divider().opacity(0.5)

            if let market = engine.currentMarket {
                Group {
                    LabeledContent("Window") {
                        Text("\(market.openTime.formatted(date: .omitted, time: .shortened)) – \(market.closeTime.formatted(date: .omitted, time: .shortened))")
                    }
                    LabeledContent("Closes in") {
                        Text(timerInterval: Date.now...max(market.closeTime, .now), countsDown: true)
                            .monospacedDigit()
                    }
                    LabeledContent("Target") {
                        HStack(spacing: 4) {
                            Text(market.floorStrike.map(BotEngine.usd) ?? "TBD")
                            if market.strikeIsEstimate {
                                Text("est.")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 5)
                                    .background(.white.opacity(0.12), in: .capsule)
                            }
                        }
                    }
                    .help(market.strikeIsEstimate
                          ? "The bot's own 60-second average before the open, shown until Kalshi publishes the official target"
                          : "The official 60-second CF Benchmarks BRTI average before the open")
                    if let yesMid = market.yesMid {
                        LabeledContent("Kalshi Yes", value: BotEngine.percent(yesMid))
                    }
                    LabeledContent("Sources", value: "\(engine.spotSources) of \(LivePriceFeed.sourceCount) · \(engine.isStreaming ? "live" : "polling")")
                        .help(engine.isStreaming
                              ? "Exchanges agreeing on price right now: Coinbase, Kraken and Bitstamp stream live; Gemini, Crypto.com, Binance.US and the Deribit and Kraken USDC books are polled every 1–2 s. A book off by more than 0.05% from the rest is left out."
                              : "Live sources unavailable; polling exchange APIs every second")
                    SourceList(statuses: engine.sourceStatuses, calibration: engine.priceCalibration)
                    if engine.calibrationSampleCount > 0 {
                        LabeledContent("BRTI calibration") {
                            Text("\(engine.priceCalibration >= 0 ? "+" : "−")\(BotEngine.usd(abs(engine.priceCalibration)))")
                        }
                        .help("Added to the exchange composite so it tracks CF Benchmarks' BRTI: the median gap over the last \(engine.calibrationSampleCount) window opens")
                    }
                    if let error = engine.trackingError {
                        LabeledContent("Tracking error") {
                            Text("±\(BotEngine.usd(error))")
                        }
                        .help("How far the index estimate was from Kalshi's official target, typically (median), over the last \(engine.trackingErrors.count) window opens. \(engine.sourceOffsets.isEmpty ? "Per-exchange offsets switch on once \(BotEngine.minimumMeasuredSources) exchanges have been measured at \(BotEngine.minimumOffsetSamples) opens." : "Per-exchange offsets are on for \(engine.sourceOffsets.count) exchanges.") Only windows that finish within about this much of their target are at risk of being misjudged.")
                    }
                }
                .font(.callout)
                .monospacedDigit()
                Text(market.ticker)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            } else {
                Text("Waiting for an open KXBTC15M market…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var predictionPanel: some View {
        Panel(title: "Prediction", systemImage: "scope") {
            if let record = currentRecord, engine.isNoCall(record) {
                Label("NO CALL", systemImage: "minus.circle")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                Text("Leaning \(record.predictedUp ? "Up" : "Down") at only \(BotEngine.percent(record.confidence)) confidence — below the \(BotEngine.percent(engine.minimumCallConfidence)) needed for a call.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let record = currentRecord {
                PredictionBadge(probabilityUp: record.probabilityUp)
                Text("Locked \(record.predictedAt.formatted(date: .omitted, time: .standard)) · \(Int(record.predictedAt.timeIntervalSince(record.openTime)))s after open")
                    .help("Calls lock \(engine.callDelayMinutes) min after the open — the same moment the model's history is built at")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No prediction locked for this window")
                    .foregroundStyle(.secondary)
                Text("The call locks \(engine.callDelayMinutes) min after each window opens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let market = engine.currentMarket {
                Divider().opacity(0.5)
                LiveOddsView(market: market, liveProbability: engine.liveProbability)
            }
        }
    }
}

// MARK: - Components

/// Every price source: its latest mid, how far it is from the combined price, and
/// whether it's in the average right now.
struct SourceList: View {
    let statuses: [SourceStatus]
    /// Offset added to the composite to track CF Benchmarks' BRTI.
    let calibration: Double

    /// Used sources share the average equally; everything else carries no weight.
    private var usedCount: Int { statuses.count { $0.state == .used } }

    private func weight(_ status: SourceStatus) -> Double {
        status.state == .used && usedCount > 0 ? 1 / Double(usedCount) : 0
    }

    /// Weighted average of the used sources, each with its offset — the same quotes the list shows.
    private var composite: Double? {
        let used = statuses.compactMap { $0.state == .used ? $0.corrected : nil }
        return used.isEmpty ? nil : used.reduce(0, +) / Double(used.count)
    }

    var body: some View {
        // Four narrow columns plus a status icon, so the list fits a quarter-width card.
        VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                ForEach(statuses) { status in
                    GridRow {
                        Image(systemName: symbol(status.state))
                            .foregroundStyle(color(status.state))
                            .accessibilityLabel(label(status.state))
                        Text(status.source.title)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(status.state == .used ? .primary : .secondary)
                        Text(status.mid.map(BotEngine.usd) ?? "—")
                            .gridColumnAlignment(.trailing)
                        Text(gap(status.corrected))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        // Out-of-use sources show how long they've been out instead of 0%.
                        Text(isOut(status.state) ? duration(status) : BotEngine.percent(weight(status)))
                            .foregroundStyle(status.state == .used ? AnyShapeStyle(.primary)
                                             : isOut(status.state) ? AnyShapeStyle(color(status.state)) : AnyShapeStyle(.tertiary))
                            .gridColumnAlignment(.trailing)
                    }
                    .help(detail(status))
                    .accessibilityElement(children: .combine)
                }
                Divider().gridCellColumns(5)
                GridRow {
                    Image(systemName: "sum").foregroundStyle(.tint)
                    Text("Composite").fontWeight(.semibold)
                    Text(composite.map(BotEngine.usd) ?? "—").fontWeight(.semibold)
                    Text("")
                    Text("100%").fontWeight(.semibold)
                }
                .help("Equal-weight average of the sources marked Used: \(usedCount) of \(statuses.count) right now.")
                GridRow {
                    Image(systemName: "scope").foregroundStyle(.tint)
                    Text("Index est.").fontWeight(.semibold)
                    Text(composite.map { BotEngine.usd($0 + calibration) } ?? "—").fontWeight(.semibold)
                    Text("\(calibration >= 0 ? "+" : "−")\(BotEngine.usd(abs(calibration)))")
                        .foregroundStyle(.secondary)
                    Text("")
                }
                .help("The composite plus the BRTI calibration offset — the price the bot uses for Kalshi's settlement index (CF Benchmarks BRTI).")
            }
            .monospacedDigit()
            Text("✓ used · ↔ trimmed (highest/lowest) · ⚠︎ off-market · clock stale, with time out. Gaps include each exchange's BRTI offset. Composite = average of \(usedCount) used.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
    }

    private func isOut(_ state: SourceStatus.State) -> Bool {
        state == .stale || state == .outlier || state == .waiting
    }

    /// Time in the current state, e.g. "45s" or "3m".
    private func duration(_ status: SourceStatus) -> String {
        guard let since = status.since else { return "—" }
        let seconds = max(Int(Date.now.timeIntervalSince(since)), 0)
        return seconds < 60 ? "\(seconds)s" : seconds < 3600 ? "\(seconds / 60)m" : "\(seconds / 3600)h"
    }

    private func detail(_ status: SourceStatus) -> String {
        var parts = ["\(status.source.title): \(label(status.state))" + (isOut(status.state) ? " for \(duration(status))." : "."),
                     help(status.state)]
        if status.offset != 0 {
            parts.append("BRTI offset \(status.offset >= 0 ? "+" : "−")\(BotEngine.usd(abs(status.offset))), measured against Kalshi's official targets, is added before averaging.")
        }
        if status.reconnects > 0 {
            parts.append("Stream reconnected \(status.reconnects) time\(status.reconnects == 1 ? "" : "s") since the bot started.")
        }
        return parts.joined(separator: " ")
    }

    private func gap(_ mid: Double?) -> String {
        guard let mid, let composite else { return "" }
        let diff = mid - composite
        return "\(diff >= 0 ? "+" : "−")\(BotEngine.usd(abs(diff)))"
    }

    private func label(_ state: SourceStatus.State) -> String {
        switch state {
        case .used: "Used"
        case .trimmed: "Trimmed"
        case .outlier: "Off-market"
        case .stale: "Stale"
        case .waiting: "Waiting"
        }
    }

    private func symbol(_ state: SourceStatus.State) -> String {
        switch state {
        case .used: "checkmark.circle.fill"
        case .trimmed: "arrow.left.and.right.circle"
        case .outlier: "exclamationmark.triangle.fill"
        case .stale: "clock.badge.exclamationmark"
        case .waiting: "ellipsis.circle"
        }
    }

    private func color(_ state: SourceStatus.State) -> Color {
        switch state {
        case .used: .green
        case .trimmed: .secondary
        case .outlier: .orange
        case .stale: .red
        case .waiting: .secondary
        }
    }

    private func help(_ state: SourceStatus.State) -> String {
        switch state {
        case .used: "Averaged into the combined price."
        case .trimmed: "In line with the others but the highest or lowest right now, so left out of the average to keep any one book from dragging it."
        case .outlier: "More than 0.05% from the other books, so left out as off-market."
        case .stale: "No fresh quote in the last 10 seconds, so left out until it updates. A stream that stays silent for 30 seconds is reconnected automatically."
        case .waiting: "Not connected yet, or no quote received. Dropped streams reconnect automatically."
        }
    }
}

/// Kalshi's live Yes and No prices next to the bot's live call and confidence,
/// refreshed every second from the order book.
struct LiveOddsView: View {
    let market: KalshiMarket
    let liveProbability: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("LIVE").font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)

            HStack(spacing: 10) {
                // Buying Yes pays the Yes ask; buying No pays 1 − the Yes bid.
                side("Yes · Up", chance: market.yesMid, price: market.yesAsk, sell: market.yesBid, color: .green, symbol: "arrow.up")
                side("No · Down", chance: market.yesMid.map { 1 - $0 }, price: market.yesBid.map { 1 - $0 },
                     sell: market.yesAsk.map { 1 - $0 }, color: .red, symbol: "arrow.down")
            }

            if let p = liveProbability {
                let up = p >= 0.5
                HStack {
                    Label("Bot now: \(up ? "Up" : "Down")", systemImage: up ? "arrow.up.right" : "arrow.down.right")
                        .foregroundStyle(up ? .green : .red)
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(BotEngine.percent(max(p, 1 - p))) confidence").monospacedDigit()
                }
                .font(.callout)
                .help("The model on live data right now. The logged prediction is the one locked at the call time.")
                if let mid = market.yesMid {
                    let gap = (p - mid) * 100
                    Text(abs(gap) < 1 ? "In line with Kalshi's price." :
                            "\(abs(gap).formatted(.number.precision(.fractionLength(1)))) pts \(gap > 0 ? "more" : "less") bullish than Kalshi's price.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Live call appears once prices and the target are in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One side's tile: Kalshi's implied chance (big), then the prices to buy and sell.
    private func side(_ title: String, chance: Double?, price: Double?, sell: Double?, color: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(chance.map(BotEngine.percent) ?? "—")
                .heroNumber(size: 22)
                .help("Kalshi's implied chance: the midpoint of the bid and ask")
            Text("Buy \(price.map(StrategyAdvisor.cents) ?? "—") · sell \(sell.map(StrategyAdvisor.cents) ?? "—")")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): Kalshi \(chance.map(BotEngine.percent) ?? "unavailable"), buy \(price.map(StrategyAdvisor.cents) ?? "unavailable"), sell \(sell.map(StrategyAdvisor.cents) ?? "unavailable")")
    }
}

struct PredictionBadge: View {
    let probabilityUp: Double

    var body: some View {
        let up = probabilityUp >= 0.5
        let color: Color = up ? .green : .red
        VStack(alignment: .leading, spacing: 10) {
            // The call itself is the one element that earns tinted glass.
            Label(up ? "UP" : "DOWN", systemImage: up ? "arrow.up" : "arrow.down")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .glassEffect(.regular.tint(color.opacity(0.55)), in: .capsule)
            HStack(spacing: 18) {
                metric("P(up)", BotEngine.percent(probabilityUp))
                metric("Confidence", BotEngine.percent(max(probabilityUp, 1 - probabilityUp)))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).heroNumber(size: 20)
        }
    }
}

struct AccuracyPanel: View {
    @Environment(BotEngine.self) private var engine
    let stats: AccuracyStats
    /// Settled windows marked "No call" by the confidence threshold.
    var skipped = 0

    var body: some View {
        Panel(title: "Accuracy", systemImage: "target") {
            VStack(alignment: .leading, spacing: 10) {
                if stats.total == 0 {
                    Text("No settled windows yet.").foregroundStyle(.secondary)
                } else {
                    AccuracyDetails(stats: stats)
                }
                if engine.minimumCallConfidence > 0 {
                    Text("Confident calls only (≥\(BotEngine.percent(engine.minimumCallConfidence))): \(skipped) low-confidence window\(skipped == 1 ? "" : "s") skipped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let settled = engine.lastSettledAt {
                    Text("Updated \(settled.formatted(date: .omitted, time: .standard)) · model retrained after each settlement")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .reservingSpace { AccuracyDetails(stats: .layoutTemplate) }
        }
        .font(.callout)
    }
}

/// How many correct calls it takes for overall accuracy to reach `ModelPanel.targetAccuracy`.
private struct TargetAccuracyDetails: View {
    let path: AccuracyStats.TargetPath
    let stats: AccuracyStats

    var body: some View {
        let target = "\(Int((path.target * 100).rounded()))%"
        VStack(alignment: .leading, spacing: 8) {
            if stats.total == 0 {
                Text("No settled calls yet.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(path.isReached ? "Reached" : "\(path.correctInARow) in a row")
                        .heroNumber(size: 24)
                        .foregroundStyle(path.isReached ? .green : .primary)
                    Text("Now \(stats.correct) of \(stats.total) correct (\(stats.accuracy.map(BotEngine.percent) ?? "—"))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(path.isReached
                     ? "At or above \(target). \(path.missesToSpare) miss\(path.missesToSpare == 1 ? "" : "es") in a row would still leave it there."
                     : "Needs \(path.correctInARow) correct call\(path.correctInARow == 1 ? "" : "s") in a row to reach \(target); each miss along the way adds about \(missCost) more.")
                    .fixedSize(horizontal: false, vertical: true)
                if let average = path.averageConfidence {
                    Text(outlook(average))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Extra correct calls one miss costs: target / (1 − target).
    private var missCost: String {
        (path.target / (1 - path.target)).formatted(.number.precision(.fractionLength(1)))
    }

    private func outlook(_ average: Double) -> String {
        let avg = BotEngine.percent(average)
        let target = "\(Int((path.target * 100).rounded()))%"
        if path.isReached {
            return average >= path.target
                ? "Calls average \(avg) confidence, so accuracy should hold near there."
                : "Calls average \(avg) confidence, so expect accuracy to drift back toward \(avg) over time."
        }
        if let calls = path.expectedCalls {
            return "Calls average \(avg) confidence; at that hit rate, about \(calls) more calls to reach \(target)."
        }
        return "Calls average \(avg) confidence, so accuracy tends toward \(avg), not \(target). Getting there takes better-than-expected luck, or setting Calls to ≥\(target) so only those calls count."
    }
}

private struct AccuracyDetails: View {
    let stats: AccuracyStats

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(stats.accuracy.map(BotEngine.percent) ?? "—")
                    .heroNumber()
                Text("\(stats.correct) correct of \(stats.total) settled" + (stats.accuracyMargin.map { " · ±\(points($0)) pts" } ?? ""))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("95% margin of error")
            }
            Divider().opacity(0.5)
            LabeledContent("Expected correct") {
                Text("\(stats.expectedCorrect.formatted(.number.precision(.fractionLength(1)))) ± \(stats.expectedCorrectMargin.formatted(.number.precision(.fractionLength(1)))) · actual \(stats.correct)")
                    .monospacedDigit()
            }
            .help("How many calls the bot's own probabilities said should be right, with a 95% range. Actual inside the range is ordinary luck; well below it would mean a real problem.")
            if let brier = stats.brierScore {
                LabeledContent("Brier score", value: brier.formatted(.number.precision(.fractionLength(4))))
                    .help("Lower is better; 0.25 is a coin flip")
            }
            if let market = stats.marketAccuracy {
                LabeledContent("Kalshi favorite accuracy", value: BotEngine.percent(market))
            }
            if let marketBrier = stats.marketBrierScore {
                LabeledContent("Kalshi Brier score", value: marketBrier.formatted(.number.precision(.fractionLength(4))))
            }
            if let edge = stats.edgeVsMarket {
                LabeledContent("Edge vs. Kalshi") {
                    Text("\(edge.accuracy >= 0 ? "+" : "−")\(points(abs(edge.accuracy))) ± \(points(edge.accuracyMargin)) pts")
                        .monospacedDigit()
                }
                .help("Bot accuracy minus Kalshi-favorite accuracy on the same \(edge.windows) windows, with a 95% margin of error")
                Text(edgeVerdict(edge))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("When ≥\(Int(AccuracyStats.confidentThreshold * 100))% confident") {
            Text(stats.confidentAccuracy.map { "\(BotEngine.percent($0)) (\(stats.confidentCorrect)/\(stats.confidentTotal))" } ?? "—")
                .monospacedDigit()
        }
        .help("Accuracy on calls where the bot gave one side at least \(Int(AccuracyStats.confidentThreshold * 100))%")
        LabeledContent("Kalshi when ≥\(Int(AccuracyStats.confidentThreshold * 100))%") {
            Text(stats.marketConfidentAccuracy.map { "\(BotEngine.percent($0)) (\(stats.marketConfidentCorrect)/\(stats.marketConfidentTotal))" } ?? "—")
                .monospacedDigit()
        }
        LabeledContent("Called Up / settled Up", value: "\(stats.predictedUp) / \(stats.actualUp)")
            LabeledContent("Current streak", value: stats.currentStreak >= 0 ? "\(stats.currentStreak) W" : "\(-stats.currentStreak) L")
            LabeledContent("Longest win streak", value: "\(stats.longestWinStreak)")
            LabeledContent("Longest losing streak", value: "\(stats.longestLosingStreak)")
            Divider()
            Text("By confidence").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(stats.buckets) { bucket in
                LabeledContent(bucket.label) {
                    Text(bucket.accuracy.map { "\(BotEngine.percent($0)) (\(bucket.correct)/\(bucket.total))" } ?? "—")
                        .monospacedDigit()
                }
            }
        }
    }
}

private extension AccuracyStats {
    /// Every row populated, with the longer "not yet significant" verdict — the
    /// card's largest possible layout.
    static var layoutTemplate: AccuracyStats {
        AccuracyStats((0..<12).map { i in
            Outcome(probabilityUp: [0.52, 0.57, 0.65, 0.8][i % 4], actualUp: i % 3 == 0,
                    marketYesMid: [0.48, 0.6][i % 2])
        })
    }
}

/// Percentage points, e.g. 0.079 → "7.9".
private func points(_ fraction: Double) -> String {
    (fraction * 100).formatted(.number.precision(.fractionLength(1)))
}

private func edgeVerdict(_ edge: AccuracyStats.Edge) -> String {
    if edge.isSignificant {
        return edge.accuracy > 0 ? "The bot is beating Kalshi by more than chance." : "Kalshi is beating the bot by more than chance."
    }
    let needed = AccuracyStats.windowsNeeded(forMargin: 0.05)
    return "Not yet distinguishable from chance — about \(needed) windows give a ±5 pt margin."
}

private func baselineName(_ model: PredictionModel) -> String {
    model.marketAnchored ? "Kalshi market" : "Starting weights"
}

/// The baseline as it reads mid-sentence (keeps "Kalshi" capitalized).
private func baselinePhrase(_ model: PredictionModel) -> String {
    model.marketAnchored ? "Kalshi's market odds" : "the starting weights"
}

struct ModelPanel: View {
    @Environment(BotEngine.self) private var engine
    let stats: AccuracyStats
    /// For the CSV copy offered before a full reset.
    let records: [PredictionRecord]
    @State private var isConfirmingReset = false
    static let targetAccuracy = 0.70

    var body: some View {
        let model = engine.model

        Panel(title: "Model", systemImage: "brain") {
            if model.trainingCount == 0 {
                Text("Using starting weights — no settled windows learned from yet.")
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Trained on", value: "\(model.trainingCount) windows")
                LabeledContent("Live / rebuilt", value: "\(engine.liveExampleCount) / \(engine.historyExampleCount)")
                    .help("Live windows have every indicator; windows rebuilt from history lack tick momentum, and Kalshi odds where Kalshi has no price history")
                if let trainedAt = model.trainedAt {
                    LabeledContent("Last trained", value: trainedAt.formatted(date: .omitted, time: .standard))
                }
                LabeledContent("Predicting with", value: model.usesLearnedWeights ? "Learned weights" : baselineName(model))
                    .help("Learned weights are only used once they beat \(baselinePhrase(model)) on windows they weren't trained on")
            }

            if let evaluation = model.evaluation {
                Divider()
                Text("Holdout test (newest \(evaluation.holdoutCount) windows)")
                    .font(.subheadline.bold())
                    .help("Walk-forward: the newest 40% is split into blocks in time order, and each is scored by a model fitted only on the windows before it")
                if let folds = evaluation.folds, folds > 1 {
                    LabeledContent("Learned weights won") {
                        Text("\(evaluation.foldsWon ?? 0) of \(folds) blocks")
                            .monospacedDigit()
                    }
                    .help("Learned weights are used only if they beat \(baselinePhrase(model)) in at least \(folds - 1) of \(folds) blocks and overall")
                }
                LabeledContent("Trained model") {
                    Text("\(BotEngine.percent(evaluation.accuracy)) · Brier \(evaluation.brierScore.formatted(.number.precision(.fractionLength(4))))")
                        .monospacedDigit()
                }
                LabeledContent(baselineName(model)) {
                    Text("\(BotEngine.percent(evaluation.priorAccuracy)) · Brier \(evaluation.priorBrierScore.formatted(.number.precision(.fractionLength(4))))")
                        .monospacedDigit()
                }
                if !model.usesLearnedWeights {
                    Text("Learned adjustments haven't beaten \(baselinePhrase(model)) yet, so the bot follows \(model.marketAnchored ? "Kalshi's odds" : "the starting weights"). It re-tests after every window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if model.trainingCount > 0 {
                Text("Holdout test runs once \(ModelTrainer.minimumForEvaluation) windows are available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if engine.isBackfilling || engine.isTraining {
                Divider()
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(engine.isBackfilling ? (engine.backfillStatus ?? "Rebuilding past windows…") : "Training…")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
            Text("Path to \(Int(Self.targetAccuracy * 100))% accuracy")
                .font(.subheadline.bold())
                .help("Correct calls needed for overall accuracy to reach \(Int(Self.targetAccuracy * 100))%")
            TargetAccuracyDetails(path: stats.path(to: Self.targetAccuracy), stats: stats)
                .reservingSpace {
                    // The longest wording: not reached, with an expected-calls estimate.
                    TargetAccuracyDetails(path: .init(target: Self.targetAccuracy, correctInARow: 888, missesToSpare: 0,
                                                      averageConfidence: 0.888, expectedCalls: 8888),
                                          stats: AccuracyStats((0..<888).map { _ in .init(probabilityUp: 0.6, actualUp: true, marketYesMid: nil) }))
                }

            Spacer(minLength: 0)
            if let lastReset = engine.lastResetAt {
                Text("Last reset \(lastReset.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Reset Model…", systemImage: "arrow.counterclockwise", role: .destructive) { isConfirmingReset = true }
                .buttonStyle(.glass)
                .confirmationDialog("Reset the model?", isPresented: $isConfirmingReset) {
                    Button("Reset Model, Keep Data") { engine.resetModelKeepingData() }
                    Button("Copy Log, Then Clear All Data", role: .destructive) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(PredictionLogView.csv(for: records), forType: .string)
                        engine.resetModel()
                    }
                } message: {
                    Text("Reset Model, Keep Data returns the weights, promotions and trials to their starting point and retrains on the data already collected. The prediction log, accuracy and history are kept.\n\nClear All Data copies the prediction log to the clipboard as CSV, then permanently deletes the log and accuracy history, the training history, the price calibration and exchange offsets, call-time statistics, alerts and the activity log. Settings and the saved market download are kept, so the rebuild takes seconds.")
                }
        }
        .font(.callout)
    }
}
