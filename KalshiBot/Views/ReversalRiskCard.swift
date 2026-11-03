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

    private var assessment: ReversalRisk? { engine.reversalRisk(for: market) }

    var body: some View {
        Panel(title: "Reversal Risk", systemImage: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: 10) {
                if let risk = assessment {
                    content(risk, bands: engine.riskLog.bands, calibration: engine.riskCalibration)
                } else {
                    Text("Collecting prices…")
                        .foregroundStyle(.secondary)
                }
            }
            .reservingSpace {
                VStack(alignment: .leading, spacing: 10) {
                    content(Self.layoutTemplate, bands: Self.bandTemplate, calibration: Self.calibrationTemplate)
                }
            }
        }
        .font(.callout)
    }

    /// Every factor present with its longest wording — the card's largest layout.
    private static let layoutTemplate = ReversalRisk(
        currentlyUp: true, cushion: 88_888.88, cushionSigma: 8.8, flipProbability: 0.488,
        kalshiFlipProbability: 0.488, blendsKalshi: true,
        breakoutUpProbability: 0.888, breakoutDownProbability: 0.888,
        momentum: .init(strength: 0.888, up: true, withLeader: false, change: 888.88, seconds: 180),
        factors: [
            .init(title: "Settlement average underway", detail: "88% of the final average is already in, at $88,888.88.", raisesRisk: false),
            .init(title: "Close to the target", detail: "The cushion is under half of the price movement still expected before the close.", raisesRisk: true),
        ])

    private static let bandTemplate = ["Under 15%", "15–35%", "35% or more"].map {
        RiskLog.Band(label: $0, count: 8888, said: 0.888, happened: 0.888)
    }
    private static let calibrationTemplate = RiskCalibration(
        flip: [0, 1], blend: [0, 1, 1], breakout: nil, volatilityHalfLife: 88,
        evaluation: .init(), windows: 88_888, fittedAt: .now)

    @ViewBuilder
    private func content(_ risk: ReversalRisk, bands: [RiskLog.Band], calibration: RiskCalibration?) -> some View {
        let color = color(for: risk.level)
        let leader = risk.currentlyUp ? "Up" : "Down"

        HStack(alignment: .firstTextBaseline) {
            Text(BotEngine.percent(risk.flipProbability))
                .heroNumber()
            Spacer()
            // Status color always ships with an icon and a label.
            Label(risk.level.title, systemImage: symbol(for: risk.level))
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Chance \(leader) loses: \(BotEngine.percent(risk.flipProbability)), \(risk.level.title)")
        .help("The chance that the side ahead now (\(leader)) loses at settlement. Low under 15%, Moderate under 35%, High from 35%.")
        Text("Chance \(leader), ahead now, loses by the close")
            .font(.caption)
            .foregroundStyle(.secondary)

        // 50% is the most a reversal can be: the price sitting on the target.
        Gauge(value: min(risk.flipProbability / 0.5, 1)) { EmptyView() }
            .gaugeStyle(.linearCapacity)
            .tint(color)
            .accessibilityHidden(true)

        HStack {
            Text("0% · locked in")
            Spacer()
            Text("Coin flip · 50%")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)

        Divider().opacity(0.5)

        if let kalshi = risk.kalshiFlipProbability {
            LabeledContent("Kalshi's price says") {
                Text(BotEngine.percent(kalshi)).monospacedDigit()
            }
            .help("The same outcome priced by Kalshi: 1 − the price of \(leader). \(risk.blendsKalshi ? "Blended into the figure above, as the history showed improves it." : "Shown for comparison; blending it in didn't improve on held-out windows.")")
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

        if !bands.isEmpty {
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 3) {
                Text("Live check: said → happened").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(bands) { band in
                    LabeledContent(band.label) {
                        Text("\(BotEngine.percent(band.said)) → \(BotEngine.percent(band.happened)) (\(band.count))")
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            }
            .help("Every minute the card's figure is logged and, once the window settles, scored. Close agreement between said and happened means the card is well calibrated; small counts are noisy.")
        }

        Spacer(minLength: 0)
        Text(footnote(calibration))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func footnote(_ calibration: RiskCalibration?) -> String {
        guard let calibration else {
            return "From the current price, time left, volatility and the price's tracking error, with corrections fitted on 30 days of windows. Refits from the saved history once it's downloaded."
        }
        let weighting = calibration.volatilityHalfLife.map { "volatility weighted toward recent minutes (\(Int($0))-min half-life)" } ?? "volatility over the last hour"
        let blend = calibration.blend != nil ? ", blended with Kalshi's price" : ""
        return "From the current price, time left, \(weighting) and the price's tracking error\(blend). Refitted on \(calibration.windows) windows \(calibration.fittedAt.formatted(.relative(presentation: .named))) and kept only where it beat the fixed corrections on the newest windows."
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
