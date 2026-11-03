//
//  StrategyCard.swift
//  KalshiBot
//

import SwiftUI

/// The recommended strategy for this window: what to do and why, the factors behind
/// the call, and entry/exit alerts — each with its justification.
struct StrategyCard: View {
    @Environment(BotEngine.self) private var engine
    let market: KalshiMarket
    let record: PredictionRecord?

    var body: some View {
        Panel(title: "Strategy", systemImage: "flag.checkered") {
            // A vertical sidebar: what to do, why, then the alerts. The sidebar's height is
            // pinned to the cards beside it, so everything scrolls together rather than clip.
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    recommendation
                    Divider().opacity(0.5)
                    positionSection
                    Divider().opacity(0.5)
                    factors
                    Divider().opacity(0.5)
                    alerts
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity)
            Text("Not financial advice. Fair value is the bot's trained model on live data; it only departs from Kalshi's odds after beating them on held-out windows. Fees use Kalshi's taker rate.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .infoTip("About these figures", "Kalshi Bot never places trades. Fair value is the bot's model on live data, which follows Kalshi's odds unless learned weights have beaten them on held-out windows. Profit figures include Kalshi's taker fee, which is highest for contracts near 50¢.")
        }
        .font(.callout)
    }

    // MARK: Position

    /// The user's stake on this window's call, and its profit or loss from the window's state now.
    @ViewBuilder
    private var positionSection: some View {
        @Bindable var engine = engine
        VStack(alignment: .leading, spacing: 8) {
            column("Your position")
            HStack(spacing: 8) {
                Text("Stake").foregroundStyle(.secondary)
                TextField("Stake", value: $engine.stake, format: .currency(code: "USD").precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .infoTip("Stake", "Dollars to put on each window's call. It's used only for the estimates below — the bot doesn't place trades. The position is the whole number of contracts this buys at the call-time price, fee included.")
                Text("per window").font(.caption).foregroundStyle(.secondary)
            }
            positionDetails
                .reservingSpace { positionGrid(Self.positionTemplate, upCall: false) }   // "No (Down)" is the longer side name
        }
    }

    /// The estimate, or why there isn't one yet.
    @ViewBuilder
    private var positionDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if engine.stake <= 0 {
                Text("Enter a stake to see what this window's call would make or lose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let position = engine.position(for: market, record: record) {
                positionGrid(position, upCall: record?.predictedUp == true)
            } else if record == nil {
                Text("The position opens at the call (+\(engine.callDelayMinutes) min).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Waiting for Kalshi's quotes, or the stake is less than one contract.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func positionGrid(_ position: PositionEstimate, upCall: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Position").foregroundStyle(.secondary)
                Text("\(position.contracts) × \(upCall ? "Yes (Up)" : "No (Down)") at \(StrategyAdvisor.cents(position.entry)) · cost \(BotEngine.usd(position.cost))")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .infoTip("Position", "The contracts your stake would have bought on the called side at the call: how many, at what price each (Kalshi's ask then), and the total cost including Kalshi's fee.")
            pnlRow("If sold now", position.profitNow,
                   help: "Selling every contract at the current bid, after Kalshi's fee.")
            pnlRow("If it settles \(upCall ? "Up" : "Down")", position.profitIfRight,
                   help: "Each contract pays $1 if the window settles on the called side.")
            pnlRow("If it settles \(upCall ? "Down" : "Up")", position.profitIfWrong,
                   help: "The contracts expire worthless; the whole stake is lost.")
            pnlRow("Expected at settlement", position.expectedProfit,
                   detail: "\(BotEngine.percent(position.chanceRight)) chance",
                   help: "Kalshi's current chance for the called side × the payout, minus the cost.")
            if let stop = position.profitAtStop {
                pnlRow("At stop-loss", stop, help: "Selling at the chart's stop-loss line.")
            }
            if let profit = position.profitAtTakeProfit {
                pnlRow("At take profit", profit, help: "Selling at the chart's take-profit line.")
            }
        }
        .monospacedDigit()
    }

    /// Every row present, with the widest amounts — the largest the estimate can be.
    private static let positionTemplate = PositionEstimate(
        contracts: 88_888, entry: 0.88, cost: 88_888.88, saleNow: 0.88, chanceRight: 0.88,
        profitAtStop: -88_888.88, profitAtTakeProfit: -88_888.88)

    private func pnlRow(_ label: String, _ amount: Double, detail: String? = nil, help: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("\(amount >= 0 ? "+" : "−")\(BotEngine.usd(abs(amount)))")
                    .fontWeight(.semibold)
                    .foregroundStyle(amount >= 0 ? .green : .red)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .infoTip(label, help)
    }

    // MARK: Call settings

    /// When the call locks, which calls count, and whether Kalshi's odds feed the model.
    @ViewBuilder
    private var callSettings: some View {
        @Bindable var engine = engine
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("Preset").foregroundStyle(.secondary)
                Menu(engine.activePreset?.title ?? "Custom") {
                    ForEach(BotEngine.CallPreset.allCases) { preset in
                        Button(preset.title) { engine.apply(preset) }
                    }
                }
                .menuStyle(.button)
                .fixedSize()
                .infoTip("Preset", "Sets the call time and the confidence threshold together. High hit rate calls later and counts only confident calls: right 88% of the time in 6,459 past windows, versus 73% for Standard, with 71% of windows called. It raises accuracy, not profit — those contracts cost correspondingly more. Changing the call time rebuilds the model's history at the new minute. Custom means the settings below don't match a preset.")
            }
            GridRow {
                Text("Call at").foregroundStyle(.secondary)
                Picker("Call at", selection: $engine.callDelayMinutes) {
                    ForEach(BotEngine.callTimeOptions, id: \.self) { minutes in
                        Text(callTimeLabel(minutes)).tag(minutes)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .infoTip("Call at", "When each window's call locks: any minute from +3 to +12. Later calls are right more often because more of the window has played out — but Kalshi's price has moved too. Each option shows how often Kalshi's favorite won at that minute in the history. Changing this rebuilds the model's history at the new time.")
            }
            GridRow {
                Text("Calls").foregroundStyle(.secondary)
                Picker("Calls", selection: $engine.minimumCallConfidence) {
                    ForEach(BotEngine.callConfidenceOptions, id: \.self) { threshold in
                        Text(threshold == 0 ? "All calls" : "Only ≥\(BotEngine.percent(threshold)) confident").tag(threshold)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .infoTip("Calls", "Confident calls only: windows whose call is below this confidence are marked “No call” and left out of accuracy and performance. Fewer calls, but historically far more of them right. Every window is still logged and trained on.")
            }
            GridRow {
                Text("Stop-loss").foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Toggle("Custom", isOn: Binding(
                        get: { engine.customStopLoss > 0 },
                        set: { engine.customStopLoss = $0 ? (engine.customStopLoss > 0 ? engine.customStopLoss : 0.10) : 0 }))
                        .toggleStyle(.checkbox)
                    Picker("Stop-loss", selection: $engine.customStopLoss) {
                        if engine.customStopLoss == 0 {
                            Text("\(engine.tradingStyle.title) default · \(BotEngine.percent(engine.tradingStyle.maxLoss))").tag(0.0)
                        }
                        ForEach(BotEngine.stopLossOptions, id: \.self) { loss in
                            Text("\(BotEngine.percent(loss)) of stake").tag(loss)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(engine.customStopLoss == 0)
                }
                .infoTip("Stop-loss", "How much of what you paid to risk before the stop-loss line: the chart's stop sits where selling would return (1 − this) of the entry price. Unchecked, the trading style's default applies. Very tight stops (5–10%) can sit inside the spread and fee, so they may say “Exit now” right after entry.")
            }
            GridRow {
                Text("Take profit").foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Toggle("Custom", isOn: Binding(
                        get: { engine.customTakeProfit > 0 },
                        set: { engine.customTakeProfit = $0 ? (engine.customTakeProfit > 0 ? engine.customTakeProfit : 0.20) : 0 }))
                        .toggleStyle(.checkbox)
                    Picker("Take profit", selection: $engine.customTakeProfit) {
                        if engine.customTakeProfit == 0 {
                            Text("\(engine.tradingStyle.title) default · \(BotEngine.percent(engine.tradingStyle.profitCapture)) of max").tag(0.0)
                        }
                        ForEach(BotEngine.takeProfitOptions, id: \.self) { gain in
                            Text("+\(BotEngine.percent(gain)) on stake").tag(gain)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(engine.customTakeProfit == 0)
                }
                .infoTip("Take profit", "The gain on what you paid to take profit at: the chart's take-profit line sits where selling would return the entry price plus this. Unchecked, the trading style's default applies. A contract can't sell for more than about 98¢ after the fee, so large gains on expensive entries can't be reached — the chart then shows no take-profit line.")
            }
            if let market = engine.currentMarket, let plan = engine.exitPlan(for: market, record: record), plan.takeProfitUnreachable {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text("+\(BotEngine.percent(engine.customTakeProfit)) isn't reachable from a \(StrategyAdvisor.cents(plan.entry)) entry (max sale ~98¢).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Toggle("Use Kalshi odds", isOn: $engine.useKalshiOdds)
                    .toggleStyle(.checkbox)
                    .infoTip("Use Kalshi odds", "Include Kalshi's own Yes price as one of the model's indicators, and anchor the model to it. On, the bot starts from the market's calibrated odds and only adjusts them when learned weights prove better. Off, it uses price signals alone, which tested much less accurate.")
            }
            if !engine.useKalshiOdds {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Label("Off: the model uses price signals alone, which is much less accurate and can disagree with the market for no good reason. Turn this on unless you're experimenting.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Toggle("Keep Mac awake", isOn: $engine.keepMacAwake)
                    .toggleStyle(.checkbox)
                    .infoTip("Keep Mac awake", "While the bot runs, stop the Mac from idle-sleeping so no window is missed. The display can still sleep. Off: the Mac can sleep, and the bot misses the windows while it's asleep.")
            }
        }
        .font(.callout)
    }

    /// e.g. "+3 min · 67% hist." — Kalshi's favorite accuracy at that time over the history.
    private func callTimeLabel(_ minutes: Int) -> String {
        let accuracy = engine.callTimeAccuracy[minutes].map { " · \(BotEngine.percent($0)) hist." } ?? ""
        return "+\(minutes) min\(accuracy)"
    }

    // MARK: Recommendation

    @ViewBuilder
    private var recommendation: some View {
        @Bindable var engine = engine
        VStack(alignment: .leading, spacing: 10) {
            column("Recommendation")
            Picker("Trading style", selection: $engine.tradingStyle) {
                ForEach(TradingStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .infoTip("Trading style", "How readily entries are suggested and how quickly to exit: the edge an entry needs after fees, the reversal risk that triggers an exit, and the default stop-loss and take-profit. No style has a proven edge over Kalshi's price.")
            Text(engine.tradingStyle.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                // Sized for the longest style's summary, so switching style doesn't resize the card.
                .reservingSpace {
                    ZStack(alignment: .topLeading) {
                        ForEach(TradingStyle.allCases) { style in
                            Text(style.summary).font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            callSettings
            // Sized for the longest recommendation it can show, so updates every second
            // never move anything below it.
            VStack(alignment: .leading, spacing: 10) {
                if let advice = engine.strategy {
                    adviceView(advice)
                } else {
                    Text("Waiting for live prices and Kalshi quotes…")
                        .foregroundStyle(.secondary)
                }
            }
            .reservingSpace {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(Self.adviceTemplates.enumerated()), id: \.offset) { _, advice in
                        VStack(alignment: .leading, spacing: 10) { adviceView(advice) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func adviceView(_ advice: StrategyAdvice) -> some View {
        Label(advice.headline, systemImage: symbol(for: advice.action))
            .font(.system(.title3, design: .rounded).weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(tint(for: advice.action)), in: .capsule)
            .infoTip("Recommendation", "What the trading style suggests right now, updated every second: buy Yes, buy No, or stand aside. An entry needs fair value to beat the price by the style's minimum edge after Kalshi's fee. The reason is given underneath.")
        Text(advice.justification)
            .fixedSize(horizontal: false, vertical: true)
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
            GridRow {
                metric("Fair Up", advice.fairUp.formatted(.percent.precision(.fractionLength(0))))
                    .infoTip("Fair Up", "The bot's live chance that the window settles Up — the price a Yes contract would be worth if the model is right. It follows Kalshi's odds unless learned weights have proven better.")
                metric("Yes bid/ask", quote(advice.yesBid, advice.yesAsk))
                    .infoTip("Yes bid/ask", "Kalshi's best bid and ask for Yes. You buy Yes at the ask and sell at the bid; No costs 1 − the Yes bid.")
            }
            GridRow {
                metric("Edge Yes", advice.edgeYes.map(StrategyAdvisor.signedCents) ?? "—")
                    .infoTip("Edge Yes", "Expected profit per Yes contract bought now: fair value minus the ask, minus Kalshi's fee. Negative means buying Yes is expected to lose.")
                metric("Edge No", advice.edgeNo.map(StrategyAdvisor.signedCents) ?? "—")
                    .infoTip("Edge No", "Expected profit per No contract bought now: the fair chance of Down minus No's price, minus Kalshi's fee. Negative means buying No is expected to lose.")
            }
        }
    }

    /// Every kind of recommendation (entry, no edge, too late), with each digit made an 8
    /// (the widest) and the longest style name — the largest the block can ever be.
    private static let adviceTemplates: [StrategyAdvice] = {
        let samples = [
            StrategyAdvisor.advise(fairUp: 0.12, yesBid: 0.40, yesAsk: 0.42, secondsRemaining: 600, style: .conservative),
            StrategyAdvisor.advise(fairUp: 0.75, yesBid: 0.40, yesAsk: 0.42, secondsRemaining: 600, style: .conservative),
            StrategyAdvisor.advise(fairUp: 0.50, yesBid: 0.49, yesAsk: 0.51, secondsRemaining: 600, style: .conservative),
            StrategyAdvisor.advise(fairUp: 0.50, yesBid: 0.49, yesAsk: 0.51, secondsRemaining: 30, style: .conservative),
            StrategyAdvisor.advise(fairUp: 0.12, yesBid: 0.40, yesAsk: 0.42, secondsRemaining: 600, style: .conservative, calledUp: true),
        ]
        return samples.map { a in
            StrategyAdvice(action: a.action, headline: a.headline, justification: widest(a.justification), fairUp: 0.88,
                           yesBid: 0.88, yesAsk: 0.88, edgeYes: -0.888, edgeNo: -0.888, signals: [])
        }
    }()

    /// Replaces every digit with 8, the widest digit, for sizing templates.
    static func widest(_ text: String) -> String {
        String(text.map { $0.isNumber ? "8" : $0 })
    }

    // MARK: Factors

    private var factors: some View {
        factorList
            .reservingSpace {
                VStack(alignment: .leading, spacing: 8) {
                    column("Factors behind the call")
                    Text("Called Down at 88.8% P(up), 88:88 PM").fontWeight(.medium)
                    ForEach(0..<5, id: \.self) { _ in
                        HStack(spacing: 8) {
                            DirectionPill(value: -1, verb: "", neutralBelow: 0.05)
                            Text("Last-60s tick momentum")
                            Spacer(minLength: 0)
                            Text("−88.8 pts").monospacedDigit()
                        }
                    }
                }
            }
    }

    @ViewBuilder
    private var factorList: some View {
        VStack(alignment: .leading, spacing: 8) {
            column("Factors behind the call")
            if let record {
                Text("Called \(record.predictedUp ? "Up" : "Down") at \(record.probabilityUp.formatted(.percent.precision(.fractionLength(1)))) P(up), \(record.predictedAt.formatted(date: .omitted, time: .shortened))")
                    .fontWeight(.medium)
                    .infoTip("Factors behind the call", "The indicators that moved this window's locked call the most, in percentage points of P(up), largest first. Green pushed toward Up, red toward Down. Indicators that moved it less than a tenth of a point aren't listed.")
                let contributions = record.contributions
                    .map { (key: $0.key, points: IndicatorEffect.points(probabilityUp: record.probabilityUp, contribution: $0.value)) }
                    .filter { abs($0.points) >= 0.05 }
                    .sorted { abs($0.points) > abs($1.points) }
                    .prefix(5)
                if contributions.isEmpty {
                    Text("No single indicator shifted the call by more than a tenth of a point.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(contributions), id: \.key) { item in
                    HStack(spacing: 8) {
                        DirectionPill(value: item.points, verb: "", neutralBelow: 0.05)
                        Text(item.key.title)
                        Spacer(minLength: 0)
                        Text("\(item.points >= 0 ? "+" : "−")\(abs(item.points).formatted(.number.precision(.fractionLength(1)))) pts")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .infoTip(item.key.title, "Moved this call \(item.points >= 0 ? "toward Up" : "toward Down") by \(abs(item.points).formatted(.number.precision(.fractionLength(1)))) percentage points of P(up), from its value at the call and its weight in the model. The Indicators tab explains what it measures.")
                }
            } else {
                Text("No call locked yet — the call locks \(engine.callDelayMinutes) min after the open.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Alerts

    @ViewBuilder
    private var alerts: some View {
        VStack(alignment: .leading, spacing: 8) {
            column("Entry & exit alerts")
            if engine.strategyAlerts.isEmpty {
                Text("No entry or exit conditions have triggered this window. With the \(engine.tradingStyle.title.lowercased()) style an entry needs an expected \(StrategyAdvisor.signedCents(engine.tradingStyle.minimumEdge)) per contract after fees; exits trigger at \(Int(engine.tradingStyle.exitRisk * 100))% reversal risk\(engine.tradingStyle.takeProfit.map { ", at a \(StrategyAdvisor.cents($0)) bid" } ?? ""), or when selling is worth as much as holding.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
            ForEach(engine.strategyAlerts) { alert in
                let isActive = engine.strategy?.signals.contains { $0.id == alert.signal.id } ?? false
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: alert.signal.kind == .entry ? "arrow.down.to.line" : "arrow.up.to.line")
                            .foregroundStyle(alert.signal.isYes ? .green : .red)
                        Text(alert.signal.title).fontWeight(.semibold)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Text(alert.time.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(alert.signal.justification)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !isActive {
                        Text("No longer active · last seen \(alert.lastSeen.formatted(date: .omitted, time: .standard))")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .opacity(isActive ? 1 : 0.6)
                .accessibilityElement(children: .combine)
                .infoTip(alert.signal.title, "\(alert.signal.kind == .entry ? "An entry" : "An exit") signal for \(alert.signal.isYes ? "Yes (Up)" : "No (Down)"), first triggered at \(alert.time.formatted(date: .omitted, time: .standard)). \(isActive ? "Still active now." : "No longer active; last seen at \(alert.lastSeen.formatted(date: .omitted, time: .standard)).") Signals are suggestions only — the bot doesn't trade.")
            }
            }
        }
    }

    // MARK: Helpers

    private func column(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.tint)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
    }

    private func quote(_ bid: Double?, _ ask: Double?) -> String {
        guard let bid, let ask else { return "—" }
        return "\(StrategyAdvisor.cents(bid)) / \(StrategyAdvisor.cents(ask))"
    }

    private func symbol(for action: StrategyAdvice.Action) -> String {
        switch action {
        case .buyYes: "arrow.up.circle.fill"
        case .buyNo: "arrow.down.circle.fill"
        case .standAside: "pause.circle.fill"
        }
    }

    private func tint(for action: StrategyAdvice.Action) -> Color? {
        switch action {
        case .buyYes: .green.opacity(0.5)
        case .buyNo: .red.opacity(0.5)
        case .standAside: nil
        }
    }

}
