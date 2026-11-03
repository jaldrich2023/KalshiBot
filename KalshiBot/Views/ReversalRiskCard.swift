//
//  ReversalRiskCard.swift
//  KalshiBot
//

import SwiftUI

/// Chance the window flips to the other side of the target before it settles,
/// with the signals that make a flip more or less likely.
struct ReversalRiskCard: View {
    @Environment(BotEngine.self) private var engine
    let market: KalshiMarket

    private var assessment: ReversalRisk? {
        guard let strike = market.floorStrike, let price = engine.spot,
              let volatility = engine.volatilityPerRootSecond else { return nil }
        let samples = engine.ticks.map { (time: $0.time, price: $0.price) }
        // Prices already inside the settlement minute, once it has begun.
        let settlementStart = market.closeTime.addingTimeInterval(-60)
        let settling = samples.filter { $0.time >= settlementStart && $0.time < market.closeTime }.map(\.price)
        let extremes = WindowChart.extremes(engine.windowPrices(for: market), from: market.openTime, to: market.closeTime)

        return ReversalRisk.assess(.init(
            price: price,
            strike: strike,
            secondsRemaining: market.closeTime.timeIntervalSinceNow,
            volatility: volatility,
            settlementAverageSoFar: settling.isEmpty ? nil : settling.reduce(0, +) / Double(settling.count),
            windowHigh: extremes?.high.price,
            windowLow: extremes?.low.price,
            // The sample closest to 3 minutes ago (within a few seconds).
            priceEarlier: samples.last(where: { Date.now.timeIntervalSince($0.time) >= 180 })
                .flatMap { Date.now.timeIntervalSince($0.time) <= 185 ? $0.price : nil }
        ))
    }

    var body: some View {
        Panel(title: "Reversal Risk", systemImage: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: 10) {
                if let risk = assessment {
                    content(risk)
                } else {
                    Text("Collecting prices…")
                        .foregroundStyle(.secondary)
                }
            }
            .reservingSpace {
                VStack(alignment: .leading, spacing: 10) { content(Self.layoutTemplate) }
            }
        }
        .font(.callout)
    }

    /// Every factor present with its longest wording — the card's largest layout.
    private static let layoutTemplate = ReversalRisk(
        currentlyUp: true, cushion: 88_888.88, cushionSigma: 8.8, flipProbability: 0.488,
        breakoutUpProbability: 0.888, breakoutDownProbability: 0.888,
        momentum: .init(strength: 0.888, up: true, withLeader: false, change: 888.88, seconds: 180),
        factors: [
            .init(title: "Settlement average underway", detail: "88% of the final average is already in, at $88,888.88.", raisesRisk: false),
            .init(title: "Close to the target", detail: "The cushion is under half of the price movement still expected before the close.", raisesRisk: true),
        ])

    @ViewBuilder
    private func content(_ risk: ReversalRisk) -> some View {
        let color = color(for: risk.level)

        HStack(alignment: .firstTextBaseline) {
            Text(BotEngine.percent(risk.riskScore))
                .heroNumber()
            Spacer()
            // Status color always ships with an icon and a label.
            Label(risk.level.title, systemImage: symbol(for: risk.level))
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reversal risk \(BotEngine.percent(risk.riskScore)), \(risk.level.title)")
        .help("0% = current side effectively locked in · 100% = sitting on the target, a coin flip")

        Gauge(value: risk.riskScore) { EmptyView() }
            .gaugeStyle(.linearCapacity)
            .tint(color)
            .accessibilityHidden(true)

        HStack {
            Text("0%")
            Spacer()
            Text("Coin flip · 100%")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)

        Divider().opacity(0.5)

        LabeledContent("Chance of flipping \(risk.currentlyUp ? "to Down" : "to Up")") {
            Text(BotEngine.percent(risk.flipProbability)).monospacedDigit()
        }
        LabeledContent("Currently") {
            Text("\(risk.currentlyUp ? "Up" : "Down") by \(BotEngine.usd(risk.cushion))")
                .monospacedDigit()
        }
        LabeledContent("Cushion") {
            Text(risk.cushionSigma.isFinite ? "\(risk.cushionSigma.formatted(.number.precision(.fractionLength(1))))σ" : "—")
                .monospacedDigit()
        }
        .help("How many standard deviations of remaining price movement the cushion covers")
        if let momentum = risk.momentum {
            Divider().opacity(0.5)
            momentumRow(momentum)
        }
        if let up = risk.breakoutUpProbability, let down = risk.breakoutDownProbability {
            Divider().opacity(0.5)
            LabeledContent {
                Text(BotEngine.percent(up)).monospacedDigit()
            } label: {
                Label("Breaks above window high", systemImage: "arrow.up.to.line")
                    .foregroundStyle(.green)
            }
            .help("Chance the price trades above this window's high before the close")
            LabeledContent {
                Text(BotEngine.percent(down)).monospacedDigit()
            } label: {
                Label("Breaks below window low", systemImage: "arrow.down.to.line")
                    .foregroundStyle(.red)
            }
            .help("Chance the price trades below this window's low before the close")
        }

        if !risk.factors.isEmpty {
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(risk.factors) { factor in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: factor.raisesRisk ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                            .foregroundStyle(factor.raisesRisk ? .orange : .green)
                            .accessibilityLabel(factor.raisesRisk ? "Raises risk" : "Lowers risk")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(factor.title).fontWeight(.medium)
                            Text(factor.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }

        Spacer(minLength: 0)
        Text("From the current price, time left and volatility, calibrated on 30 days of windows. Momentum and chart patterns were tested and added nothing.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Momentum strength: percent, direction, and whether it's with or against the leader.
    @ViewBuilder
    private func momentumRow(_ m: ReversalRisk.Momentum) -> some View {
        let color: Color = m.up ? .green : .red
        LabeledContent {
            Label(BotEngine.percent(m.strength), systemImage: m.up ? "arrow.up.right" : "arrow.down.right")
                .monospacedDigit()
                .foregroundStyle(color)
        } label: {
            Text("Momentum strength")
        }
        .help("How strong the last \(Int(m.seconds / 60)) minutes' move is next to typical volatility: 0% flat, ~50% ordinary, near 100% unusually strong. Context only — in backtests it didn't predict reversals beyond the flip chance above.")
        Gauge(value: m.strength) { EmptyView() }
            .gaugeStyle(.linearCapacity)
            .tint(color)
            .accessibilityHidden(true)
        Text("\(m.up ? "Up" : "Down") \(BotEngine.usd(abs(m.change))) in \(Int(m.seconds / 60)) min — \(m.withLeader ? "with" : "against") the side that's winning.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func color(for level: ReversalRisk.Level) -> Color {
        switch level {
        case .low: .green
        case .moderate: .yellow
        case .high: .red
        }
    }

    private func symbol(for level: ReversalRisk.Level) -> String {
        switch level {
        case .low: "checkmark.shield.fill"
        case .moderate: "exclamationmark.triangle.fill"
        case .high: "exclamationmark.octagon.fill"
        }
    }
}
