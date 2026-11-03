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
                .infoTip("Bitcoin price", "The bot's live estimate of CF Benchmarks' Real-Time Index (BRTI), the index Kalshi settles these windows on: a weighted average of the exchanges listed below plus the BRTI calibration offset. Updated several times a second. The line underneath is how far it is above (green) or below (red) this window's target — if it's above the target at the close, the window settles Up.")
            } else {
                Text("Fetching prices…").foregroundStyle(.secondary)
            }

            Divider().opacity(0.5)

            if let market = engine.currentMarket {
                Group {
                    LabeledContent("Window") {
                        Text("\(market.openTime.formatted(date: .omitted, time: .shortened)) – \(market.closeTime.formatted(date: .omitted, time: .shortened))")
                    }
                    .infoTip("Window", "This 15-minute window's open and close, in your local time. Kalshi lists a new KXBTC15M market every quarter hour; the bot moves to the next one the second this one closes.")
                    LabeledContent("Closes in") {
                        Text(timerInterval: Date.now...max(market.closeTime, .now), countsDown: true)
                            .monospacedDigit()
                    }
                    .infoTip("Closes in", "Time left until settlement. At the close Kalshi compares the 60-second BRTI average before the close with the target: at or above settles Up (Yes pays $1), below settles Down (No pays $1).")
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
                    .infoTip("Target", market.strikeIsEstimate
                          ? "The price Bitcoin must be at or above at the close for the window to settle Up. Marked est.: this is the bot's own 60-second average before the open, shown until Kalshi publishes the official target a few seconds into the window."
                          : "The price Bitcoin must be at or above at the close for the window to settle Up: Kalshi's official 60-second CF Benchmarks BRTI average before the open.")
                    if let yesMid = market.yesMid {
                        LabeledContent("Kalshi Yes", value: BotEngine.percent(yesMid))
                            .infoTip("Kalshi Yes", "The market's implied chance that this window settles Up: the midpoint of the best Yes bid and ask in Kalshi's order book, refreshed every second. Kalshi's price has been well calibrated in the history — a 60% price has won about 60% of the time.")
                    }
                    LabeledContent("Sources", value: "\(engine.spotSources) of \(LivePriceFeed.sourceCount) · \(engine.isStreaming ? "live" : "polling")")
                        .infoTip("Sources", engine.isStreaming
                              ? "Exchanges agreeing on price right now, of the \(LivePriceFeed.sourceCount) the bot reads. Coinbase, Kraken and Bitstamp stream live; the others are polled every 1–2 seconds. A book more than 0.05% from the rest is left out as off-market, and one with no fresh quote for 10 seconds is left out as stale. Hover over any exchange below for its own status."
                              : "Live streams are unavailable, so the bot is polling the exchanges' APIs every second instead. Prices update a little less often until the streams reconnect, which happens automatically.")
                    SourceList(statuses: engine.sourceStatuses, calibration: engine.priceCalibration)
                    if engine.calibrationSampleCount > 0 {
                        LabeledContent("BRTI calibration") {
                            Text("\(engine.priceCalibration >= 0 ? "+" : "−")\(BotEngine.usd(abs(engine.priceCalibration)))")
                        }
                        .infoTip("BRTI calibration", "Added to the exchange composite so it tracks CF Benchmarks' BRTI, which Kalshi settles on. It's the median gap between the composite and Kalshi's official target over the last \(engine.calibrationSampleCount) window opens, and it updates at each new open.")
                    }
                    if let error = engine.trackingError {
                        LabeledContent("Tracking error") {
                            Text("±\(BotEngine.usd(error))")
                        }
                        .infoTip("Tracking error", "How far the index estimate was from Kalshi's official target, typically (median), over the last \(engine.trackingErrors.count) window opens. \(engine.sourceOffsets.isEmpty ? "Per-exchange offsets switch on once \(BotEngine.minimumMeasuredSources) exchanges have been measured at \(BotEngine.minimumOffsetSamples) opens." : "Per-exchange offsets are on for \(engine.sourceOffsets.count) exchanges.") Only windows that finish within about this much of their target are at risk of being misjudged.")
                    }
                }
                .font(.callout)
                .monospacedDigit()
                Text(market.ticker)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .infoTip("Market ticker", "Kalshi's identifier for this window's market: the series (KXBTC15M), the close date and time in US Eastern time, and the window number. Selectable, so you can copy it to find the market on Kalshi.")
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
                    .infoTip("No call", "This window's call was below the confidence threshold set under Calls in the Strategy card, so it isn't counted in accuracy or performance. It's still logged and the model still trains on it.")
                Text("Leaning \(record.predictedUp ? "Up" : "Down") at only \(BotEngine.percent(record.confidence)) confidence — below the \(BotEngine.percent(engine.minimumCallConfidence)) needed for a call.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let record = currentRecord {
                PredictionBadge(probabilityUp: record.probabilityUp)
                Text("Locked \(record.predictedAt.formatted(date: .omitted, time: .standard)) · \(Int(record.predictedAt.timeIntervalSince(record.openTime)))s after open")
                    .infoTip("Call time", "Calls lock \(engine.callDelayMinutes) min after the open — the same moment the model's history is built at, so live calls and training examples are like for like. After it locks, the call never changes; the live figures below keep updating. Change the minute under Call at in the Strategy card.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let like = engine.callsLikeThis(confidence: record.confidence) {
                    Label("Calls like this (\(like.band)–\(like.band + 5)% at +\(engine.callDelayMinutes) min) won \(BotEngine.percent(Double(like.won) / Double(like.total))) of \(like.total.formatted()) past windows.",
                          systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .infoTip("Calls like this", "How often Kalshi's favorite won in past windows priced in the same 5-point confidence band at the same call time — what this confidence has been worth historically. Because Kalshi's price is well calibrated, expect a 60% call to be wrong about 4 times in 10.")
                }
            } else {
                Text("No prediction locked for this window")
                    .foregroundStyle(.secondary)
                    .infoTip("No prediction yet", "The bot calls each window once, \(engine.callDelayMinutes) min after it opens. If the bot started after that moment, this window is skipped and the next one is called on time.")
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

    private var usedCount: Int { statuses.count { $0.state == .used } }

    /// Each used source's share, as the composite weighted it (by how steadily it tracks
    /// the official index once measured, capped at 25%); everything else carries none.
    private func weight(_ status: SourceStatus) -> Double {
        status.state == .used ? status.weight : 0
    }

    /// Weighted average of the used sources, each with its offset — the same quotes the list shows.
    private var composite: Double? {
        let used = statuses.compactMap { s in s.state == .used ? s.corrected.map { ($0, s.weight) } : nil }
        let total = used.map(\.1).reduce(0, +)
        return total > 0 ? used.map { $0.0 * $0.1 }.reduce(0, +) / total : nil
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
                    .infoTip(status.source.title, detail(status))
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
                .infoTip("Composite", "Weighted average of the sources marked Used (\(usedCount) of \(statuses.count) right now), each with its own BRTI offset. Once each exchange's gap to the official index has been measured, the exchanges that track it most steadily count more, up to 25% each; until then, or with four or fewer sources, they count equally.")
                GridRow {
                    Image(systemName: "scope").foregroundStyle(.tint)
                    Text("Index est.").fontWeight(.semibold)
                    Text(composite.map { BotEngine.usd($0 + calibration) } ?? "—").fontWeight(.semibold)
                    Text("\(calibration >= 0 ? "+" : "−")\(BotEngine.usd(abs(calibration)))")
                        .foregroundStyle(.secondary)
                    Text("")
                }
                .infoTip("Index estimate", "The composite plus the BRTI calibration offset (shown beside it) — the price the bot uses for Kalshi's settlement index, CF Benchmarks' BRTI. This is the big price at the top of the card.")
            }
            .monospacedDigit()
            Text("✓ used · ↔ trimmed (highest/lowest) · ⚠︎ off-market · clock stale, with time out. Gaps include each exchange's BRTI offset. Composite = weighted average of \(usedCount) used.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .infoTip("Reading the list", "Columns: status, exchange, its latest mid price, its gap to the composite (after its BRTI offset), and its share of the composite. A source out of use shows how long it's been out instead of a share. Used sources are averaged; the highest and lowest are trimmed; off-market and stale sources are left out until they come back in line.")
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
            .infoTip("Live", "Everything below refreshes every second from Kalshi's order book and the live price feed, unlike the locked call above.")

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
                .infoTip("Bot now", "What the model would call if the window were called this second, and how confident it would be. It moves with the price and time left. The logged prediction — the one scored for accuracy — is the one locked at the call time.")
                if let mid = market.yesMid {
                    let gap = (p - mid) * 100
                    Text(abs(gap) < 1 ? "In line with Kalshi's price." :
                            "\(abs(gap).formatted(.number.precision(.fractionLength(1)))) pts \(gap > 0 ? "more" : "less") bullish than Kalshi's price.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .infoTip("Bot vs. Kalshi", "The gap between the bot's live chance of Up and Kalshi's. While the model follows Kalshi's odds (see Predicting with in the Model card), the two match. A gap appears only once learned weights have beaten Kalshi's price on held-out windows.")
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
            Text("Buy \(price.map(StrategyAdvisor.cents) ?? "—") · sell \(sell.map(StrategyAdvisor.cents) ?? "—")")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .infoTip(title, "The big figure is Kalshi's implied chance for this side: the midpoint of the bid and ask. Buy is what one contract costs now (the ask) and sell is what it would fetch now (the bid), before Kalshi's fee. Each contract pays $1 if the window settles this way, and nothing otherwise.")
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
                .infoTip("The call", "The side the bot called for this window, locked at the call time: Up if its chance of Up is 50% or more, otherwise Down. It's scored when the window settles.")
            HStack(spacing: 18) {
                metric("P(up)", BotEngine.percent(probabilityUp))
                    .infoTip("P(up)", "The model's probability, at the call, that this window settles Up. Below 50% is a Down call.")
                metric("Confidence", BotEngine.percent(max(probabilityUp, 1 - probabilityUp)))
                    .infoTip("Confidence", "The probability of the side called: P(up) for an Up call, 1 − P(up) for a Down call. It's a calibrated chance, not a guarantee — a 65% call should be wrong about a third of the time.")
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
                        .infoTip("Skipped windows", "Settled windows whose call was below the threshold set under Calls in the Strategy card. They're marked No call and left out of every figure on this card, but kept in the log and used for training.")
                }
                if let settled = engine.lastSettledAt {
                    Text("Updated \(settled.formatted(date: .omitted, time: .standard)) · model retrained after each settlement")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .infoTip("Last update", "When the most recent window settled and was scored. Each settlement is added to the training data and the model is retrained and re-tested straight away.")
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
                .infoTip("Correct in a row", "The fewest consecutive correct calls that would lift overall accuracy to \(target), from \(stats.correct) of \(stats.total) now. Once it's reached, the card shows how many misses in a row it could absorb and stay there.")
                Text(path.isReached
                     ? "At or above \(target). \(path.missesToSpare) miss\(path.missesToSpare == 1 ? "" : "es") in a row would still leave it there."
                     : "Needs \(path.correctInARow) correct call\(path.correctInARow == 1 ? "" : "s") in a row to reach \(target); each miss along the way adds about \(missCost) more.")
                    .fixedSize(horizontal: false, vertical: true)
                if let average = path.averageConfidence {
                    Text(outlook(average))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .infoTip("Outlook", "Over many windows, accuracy tends toward the calls' average confidence, because the confidences are calibrated chances. So a target above the average confidence is reached only by luck — or by counting only calls at or above it.")
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
            }
            .infoTip("Accuracy", "The share of settled, counted calls that were right. The ± figure is the 95% margin of error: with few windows it's wide, so differences of a few points are usually luck.")
            Divider().opacity(0.5)
            LabeledContent("Expected correct") {
                Text("\(stats.expectedCorrect.formatted(.number.precision(.fractionLength(1)))) ± \(stats.expectedCorrectMargin.formatted(.number.precision(.fractionLength(1)))) · actual \(stats.correct)")
                    .monospacedDigit()
            }
            .infoTip("Expected correct", "How many calls the bot's own probabilities said should be right — the sum of each call's confidence — with a 95% range. Actual inside the range is ordinary luck; well below it would mean the probabilities are overconfident.")
            if let brier = stats.brierScore {
                LabeledContent("Brier score", value: brier.formatted(.number.precision(.fractionLength(4))))
                    .infoTip("Brier score", "The average squared gap between the bot's probability and what happened (1 for Up, 0 for Down). Lower is better: 0 is perfect and 0.25 is a coin flip. Unlike accuracy, it rewards confident calls that were right and penalizes confident calls that were wrong.")
            }
            if let market = stats.marketAccuracy {
                LabeledContent("Kalshi favorite accuracy", value: BotEngine.percent(market))
                    .infoTip("Kalshi favorite accuracy", "How often the side Kalshi priced above 50% at the call time won, on the same windows. This is the benchmark: the bot adds value only if it beats it.")
            }
            if let marketBrier = stats.marketBrierScore {
                LabeledContent("Kalshi Brier score", value: marketBrier.formatted(.number.precision(.fractionLength(4))))
                    .infoTip("Kalshi Brier score", "The same score for Kalshi's price at the call time, on the same windows. A lower Brier score than this means the bot's probabilities were closer to the outcomes than the market's.")
            }
            if let edge = stats.edgeVsMarket {
                LabeledContent("Edge vs. Kalshi") {
                    Text("\(edge.accuracy >= 0 ? "+" : "−")\(points(abs(edge.accuracy))) ± \(points(edge.accuracyMargin)) pts")
                        .monospacedDigit()
                }
                .infoTip("Edge vs. Kalshi", "Bot accuracy minus Kalshi-favorite accuracy on the same \(edge.windows) windows, with a 95% margin of error. Only an edge whose margin doesn't cross zero is more than chance.")
                Text(edgeVerdict(edge))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .infoTip("Verdict", "Whether the edge above is bigger than its margin of error. Distinguishing a small edge from luck takes many windows: the margin shrinks with the square root of the window count.")
            }
            LabeledContent("When ≥\(Int(AccuracyStats.confidentThreshold * 100))% confident") {
            Text(stats.confidentAccuracy.map { "\(BotEngine.percent($0)) (\(stats.confidentCorrect)/\(stats.confidentTotal))" } ?? "—")
                .monospacedDigit()
        }
        .infoTip("Confident calls", "Accuracy on calls where the bot gave one side at least \(Int(AccuracyStats.confidentThreshold * 100))%, with the count right of those calls. Confident calls are right more often, but there are fewer of them.")
        LabeledContent("Kalshi when ≥\(Int(AccuracyStats.confidentThreshold * 100))%") {
            Text(stats.marketConfidentAccuracy.map { "\(BotEngine.percent($0)) (\(stats.marketConfidentCorrect)/\(stats.marketConfidentTotal))" } ?? "—")
                .monospacedDigit()
        }
        .infoTip("Kalshi when confident", "How often Kalshi's favorite won when its price gave one side at least \(Int(AccuracyStats.confidentThreshold * 100))% at the call time — the benchmark for the row above.")
        LabeledContent("Called Up / settled Up", value: "\(stats.predictedUp) / \(stats.actualUp)")
            .infoTip("Called Up / settled Up", "How many counted calls were Up, next to how many of those windows actually settled Up. Close numbers mean the bot isn't leaning to one side more than the market did.")
            LabeledContent("Current streak", value: stats.currentStreak >= 0 ? "\(stats.currentStreak) W" : "\(-stats.currentStreak) L")
                .infoTip("Current streak", "Consecutive right (W) or wrong (L) calls up to the latest settled window. Streaks of several losses happen by chance even with a sound model.")
            LabeledContent("Longest win streak", value: "\(stats.longestWinStreak)")
                .infoTip("Longest win streak", "The most consecutive right calls so far.")
            LabeledContent("Longest losing streak", value: "\(stats.longestLosingStreak)")
                .infoTip("Longest losing streak", "The most consecutive wrong calls so far. With 65% calls, a run of 4 or 5 misses turns up every few hundred windows by chance alone.")
            Divider()
            Text("By confidence").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .infoTip("By confidence", "Accuracy split by how confident each call was. If the probabilities are calibrated, each band's accuracy lands close to its confidence — 55–60% calls right a bit under 60% of the time, and so on. Small bands are noisy.")
            ForEach(stats.buckets) { bucket in
                LabeledContent(bucket.label) {
                    Text(bucket.accuracy.map { "\(BotEngine.percent($0)) (\(bucket.correct)/\(bucket.total))" } ?? "—")
                        .monospacedDigit()
                }
                .infoTip("Calls at \(bucket.label)", "Accuracy on calls with confidence in this band, with how many were right of how many. A calibrated band is right about as often as its confidence.")
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

/// Erases all stored data, then starts a fresh copy of the app and quits this one, so
/// every setting comes back at its default.
@MainActor private func eraseAndRelaunch(_ engine: BotEngine) {
    engine.eraseEverything()
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
        Task { @MainActor in NSApplication.shared.terminate(nil) }
    }
}

struct ModelPanel: View {
    @Environment(BotEngine.self) private var engine
    let stats: AccuracyStats
    /// For the CSV copy offered before a full reset.
    let records: [PredictionRecord]
    @State private var isConfirmingReset = false
    @State private var isConfirmingErase = false

    private func eraseAndRelaunch() { KalshiBot.eraseAndRelaunch(engine) }
    static let targetAccuracy = 0.70

    var body: some View {
        let model = engine.model

        Panel(title: "Model", systemImage: "brain") {
            if model.trainingCount == 0 {
                Text("Using starting weights — no settled windows learned from yet.")
                    .foregroundStyle(.secondary)
                    .infoTip("Starting weights", "Until windows settle or history is rebuilt, the model predicts with its built-in starting weights, which follow Kalshi's price.")
            } else {
                LabeledContent("Trained on", value: "\(model.trainingCount) windows")
                    .infoTip("Trained on", "Settled windows in the model's training data: windows the bot called live, plus past windows rebuilt from Kalshi and Coinbase market history. The model is retrained on all of them after every settlement.")
                LabeledContent("Live / rebuilt", value: "\(engine.liveExampleCount) / \(engine.historyExampleCount)")
                    .infoTip("Live / rebuilt", "Windows the bot saw live, next to windows rebuilt from market history. Live windows have every indicator; rebuilt ones lack tick momentum, and Kalshi's odds where Kalshi has no price history. Live-only indicators can't be tested until enough live windows build up.")
                if let trainedAt = model.trainedAt {
                    LabeledContent("Last trained", value: trainedAt.formatted(date: .omitted, time: .standard))
                        .infoTip("Last trained", "When the model was last refitted and re-tested. It retrains after every settled window.")
                }
                LabeledContent("Predicting with", value: model.usesLearnedWeights ? "Learned weights" : baselineName(model))
                    .infoTip("Predicting with", "What sets the live probability. Learned weights are used only once they beat \(baselinePhrase(model)) on windows they weren't trained on, by more than the margin of error, in most test blocks. Until then the bot follows \(baselinePhrase(model)). The Indicators tab lists the exact conditions.")
            }

            if let evaluation = model.evaluation {
                Divider()
                Text("Holdout test (newest \(evaluation.holdoutCount) windows)")
                    .font(.subheadline.bold())
                    .infoTip("Holdout test", "Walk-forward: the newest 40% of windows (\(evaluation.holdoutCount)) is split into blocks in time order, and each block is scored by a model fitted only on the windows before it — just as it would have run live. This keeps the test honest: no window is scored by a model that saw it.")
                if let folds = evaluation.folds, folds > 1 {
                    LabeledContent("Learned weights won") {
                        Text("\(evaluation.foldsWon ?? 0) of \(folds) blocks")
                            .monospacedDigit()
                    }
                    .infoTip("Learned weights won", "In how many of the \(folds) test blocks learned weights beat \(baselinePhrase(model)). They're switched on only if they win at least \(folds - 1) of \(folds) and the overall gain is beyond its margin of error; once on, they stay on unless they win fewer than half the blocks or fall significantly behind.")
                }
                LabeledContent("Trained model") {
                    Text("\(BotEngine.percent(evaluation.accuracy)) · Brier \(evaluation.brierScore.formatted(.number.precision(.fractionLength(4))))")
                        .monospacedDigit()
                }
                .infoTip("Trained model", "The learned weights' accuracy and Brier score on the held-out windows. Compare with the row below: a lower Brier score is better.")
                LabeledContent(baselineName(model)) {
                    Text("\(BotEngine.percent(evaluation.priorAccuracy)) · Brier \(evaluation.priorBrierScore.formatted(.number.precision(.fractionLength(4))))")
                        .monospacedDigit()
                }
                .infoTip(baselineName(model), "The baseline — \(baselinePhrase(model)) — on the same held-out windows. The learned weights have to beat this to be used.")
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
                    .infoTip("Holdout test", "Fewer windows than this can't give a test that tells skill from luck, so the bot keeps following the baseline until there are enough.")
            }

            if engine.isBackfilling || engine.isTraining {
                Divider()
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(engine.isBackfilling ? (engine.backfillStatus ?? "Rebuilding past windows…") : "Training…")
                        .foregroundStyle(.secondary)
                }
                .infoTip(engine.isBackfilling ? "Rebuilding history" : "Training", engine.isBackfilling
                         ? "Downloading Kalshi and Coinbase market history and rebuilding past windows as training examples, as they looked at the call time. The first run takes a few minutes; later runs use the saved download and take seconds."
                         : "Refitting the model on every settled window and re-running the holdout test. Calls keep working meanwhile.")
            }

            Divider()
            Text("Path to \(Int(Self.targetAccuracy * 100))% accuracy")
                .font(.subheadline.bold())
                .infoTip("Path to \(Int(Self.targetAccuracy * 100))%", "How many correct calls it would take for overall accuracy to reach \(Int(Self.targetAccuracy * 100))%, and whether the calls' confidence makes that realistic.")
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
                    .infoTip("Last reset", "When the model or data was last reset. Accuracy and training count from this point.")
            }
            Button("Reset Model…", systemImage: "arrow.counterclockwise", role: .destructive) { isConfirmingReset = true }
                .buttonStyle(.glass)
                .infoTip("Reset Model", "Offers three choices: reset the model but keep the data; copy the log, then clear all data but keep settings; or erase everything, including settings, and relaunch. You confirm before anything is deleted.")
                .confirmationDialog("Reset the model?", isPresented: $isConfirmingReset) {
                    Button("Reset Model, Keep Data") { engine.resetModelKeepingData() }
                    Button("Copy Log, Then Clear All Data", role: .destructive) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(PredictionLogView.csv(for: records), forType: .string)
                        engine.resetModel()
                    }
                    Button("Erase Everything, Including Settings…", role: .destructive) { isConfirmingErase = true }
                } message: {
                    Text("Reset Model, Keep Data returns the weights, promotions and trials to their starting point and retrains on the data already collected. The prediction log, accuracy and history are kept.\n\nClear All Data copies the prediction log to the clipboard as CSV, then permanently deletes the log and accuracy history, the training history, the price calibration and exchange offsets, call-time statistics, alerts and the activity log. Settings and the saved market download are kept, so the rebuild takes seconds.\n\nErase Everything also deletes all settings and the saved market download, then relaunches the app as if newly installed.")
                }
                .alert("Erase everything?", isPresented: $isConfirmingErase) {
                    Button("Copy Log, Erase and Relaunch", role: .destructive) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(PredictionLogView.csv(for: records), forType: .string)
                        eraseAndRelaunch()
                    }
                    Button("Erase and Relaunch", role: .destructive) { eraseAndRelaunch() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This permanently deletes the prediction log and accuracy history, the training history, every setting (trading style, call time, stake, stop-loss and take-profit, and the rest), the price calibration and exchange offsets, the Reversal Risk calibration and live check, and the saved market download. The app then relaunches with default settings and downloads Kalshi's full market history again, which takes a few minutes. This can't be undone.")
                }
        }
        .font(.callout)
    }
}
