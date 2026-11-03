//
//  CandlePatternCard.swift
//  KalshiBot
//

import SwiftUI
import Charts

/// Names the candlestick pattern formed by the latest completed 1-minute candles,
/// explains it, and relates it to the current window's target.
struct CandlePatternCard: View {
    @Environment(BotEngine.self) private var engine
    let market: KalshiMarket

    var body: some View {
        Panel(title: "Candle Pattern", systemImage: "sparkle.magnifyingglass") {
            VStack(alignment: .leading, spacing: 10) {
                if let analysis = CandlePatterns.analyze(engine.completedMinuteCandles) {
                    content(analysis, implication: windowImplication(bias: analysis.primary?.bias ?? .neutral))
                } else {
                    Text("Waiting for the first full minute of prices…")
                        .foregroundStyle(.secondary)
                }
            }
            .reservingSpace {
                VStack(alignment: .leading, spacing: 10) {
                    content(Self.layoutTemplate, implication: "Supports a recovery toward the target — price needs +$88,888.88 in 88 min to settle Up.")
                }
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func content(_ analysis: PatternAnalysis, implication: String?) -> some View {
        let primary = analysis.primary
        let highlighted = primary?.candleCount ?? 1

        HStack(alignment: .center, spacing: 10) {
            BiasBadge(name: primary?.name ?? "No clear pattern", bias: primary?.bias ?? .neutral)
            Spacer(minLength: 0)
            if let primary {
                Text(primary.strengthTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .infoTip("Pattern strength", "How reliable this pattern is traditionally considered, from weak to strong. It's chart-reading convention: on these 15-minute windows no candle pattern predicted the result in testing.")
            }
        }
        .infoTip(primary?.name ?? "No clear pattern", primary.map { "\($0.meaning) It's formed by the last \($0.candleCount) one-minute candle\($0.candleCount == 1 ? "" : "s"), and reads \($0.bias.title.lowercased())." }
                 ?? "The latest one-minute candles don't match any of the patterns the bot recognizes.")

        MiniCandles(candles: Array(analysis.candles.suffix(8)), highlightedCount: highlighted)
            .frame(height: 70)
            .infoTip("Latest candles", "The last eight completed one-minute candles of the index estimate. The candles that form the pattern are bright; the rest are dimmed. Green closed higher than it opened, red lower; the thin lines are each minute's high and low.")

        if let primary {
            Text(primary.meaning)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("The latest candles don't form a recognized pattern. Read price action from the chart and indicators instead.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let implication {
            VStack(alignment: .leading, spacing: 2) {
                Text("For this window").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(implication)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .infoTip("For this window", "What the pattern's usual reading would mean for this window, given where the price is against the target and the time left. Informational only — the pattern isn't a model input.")
        }

        if analysis.patterns.count > 1 {
            VStack(alignment: .leading, spacing: 2) {
                Text("Also detected").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(analysis.patterns.dropFirst()) { pattern in
                    Text("\(pattern.name) · \(pattern.bias.title.lowercased())")
                        .infoTip(pattern.name, pattern.meaning.isEmpty ? "Also matched by the latest candles; it reads \(pattern.bias.title.lowercased())." : pattern.meaning)
                }
            }
        }

        Spacer(minLength: 0)
        if let last = analysis.candles.last {
            Text("Candle closed \(last.time.addingTimeInterval(60).formatted(date: .omitted, time: .shortened)) · prior \(analysis.trend.title) · informational, not a model input")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .infoTip("Candle details", "When the latest one-minute candle closed, and the trend in the candles before the pattern, which decides whether a reversal pattern applies. Candle patterns are shown for context only; they aren't used by the model.")
        }
    }

    /// The most patterns that can match at once (one 3-candle, two 2-candle, one
    /// single), with the longest wording — the card's largest possible layout.
    private static let layoutTemplate: PatternAnalysis = {
        let candles = (0..<8).map { i in
            Candle(time: Date(timeIntervalSince1970: Double(i) * 60), open: 100, high: 102, low: 98, close: 101, volume: 0)
        }
        return PatternAnalysis(patterns: [
            CandlePattern(name: "Three White Soldiers", bias: .bullish, strength: 3, candleCount: 3,
                          meaning: "An up candle whose body completely swallows the prior down candle. Buyers overpowered sellers decisively — one of the more reliable reversal signals, strongest after a decline."),
            CandlePattern(name: "Bullish Engulfing", bias: .bullish, strength: 3, candleCount: 2, meaning: ""),
            CandlePattern(name: "Tweezer Bottom", bias: .bullish, strength: 1, candleCount: 2, meaning: ""),
            CandlePattern(name: "Bullish Marubozu", bias: .bullish, strength: 2, candleCount: 1, meaning: ""),
        ], trend: .sideways, candles: candles)
    }()

    /// Translates the pattern's bias into what it implies relative to the target.
    private func windowImplication(bias: PatternBias) -> String? {
        guard let spot = engine.spot, let strike = market.floorStrike else { return nil }
        let minutes = max(Int(market.closeTime.timeIntervalSinceNow / 60), 0)
        let gap = BotEngine.usd(abs(spot - strike))
        let above = spot >= strike
        let timeLeft = minutes == 1 ? "1 min" : "\(minutes) min"

        switch (bias, above) {
        case (.bullish, false):
            return "Supports a recovery toward the target — price needs +\(gap) in \(timeLeft) to settle Up."
        case (.bullish, true):
            return "Supports holding the \(gap) cushion above the target with \(timeLeft) left."
        case (.bearish, true):
            return "Warns the \(gap) cushion above the target could erode in the \(timeLeft) left."
        case (.bearish, false):
            return "Points to continued weakness — price is \(gap) below the target with \(timeLeft) left."
        case (.neutral, _):
            return "No directional edge. Price is \(gap) \(above ? "above" : "below") the target with \(timeLeft) left."
        }
    }
}

/// Pattern name on tinted glass: green bullish, red bearish, untinted neutral.
private struct BiasBadge: View {
    let name: String
    let bias: PatternBias

    var body: some View {
        let tint: Color? = switch bias {
        case .bullish: .green.opacity(0.5)
        case .bearish: .red.opacity(0.5)
        case .neutral: nil
        }
        Label(name, systemImage: symbol)
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(tint), in: .capsule)
            .accessibilityLabel("\(name), \(bias.title)")
    }

    private var symbol: String {
        switch bias {
        case .bullish: "arrow.up.right"
        case .bearish: "arrow.down.right"
        case .neutral: "arrow.left.and.right"
        }
    }
}

/// The latest candles, with the ones forming the pattern at full strength and the rest dimmed.
private struct MiniCandles: View {
    let candles: [Candle]
    let highlightedCount: Int

    var body: some View {
        let lows = candles.map(\.low), highs = candles.map(\.high)
        let low = lows.min() ?? 0, high = highs.max() ?? 1
        Chart {
            ForEach(Array(candles.enumerated()), id: \.offset) { index, candle in
                let isPattern = index >= candles.count - highlightedCount
                let color: Color = candle.close >= candle.open ? .green : .red
                // String x values make the axis categorical, so each candle gets its own slot.
                RuleMark(x: .value("Index", String(index)), yStart: .value("Low", candle.low), yEnd: .value("High", candle.high))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(color.opacity(isPattern ? 1 : 0.3))
                BarMark(x: .value("Index", String(index)),
                        yStart: .value("Open", candle.open),
                        yEnd: .value("Close", abs(candle.close - candle.open) < 0.5 ? candle.open + 0.5 : candle.close),
                        width: .ratio(0.6))
                    .foregroundStyle(color.opacity(isPattern ? 1 : 0.3))
                    .clipShape(.rect(cornerRadius: 2))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: low...max(high, low + 1))
        .accessibilityHidden(true)
    }
}
