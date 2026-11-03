//
//  WindowCandleChart.swift
//  KalshiBot
//

import SwiftUI
import Charts

/// 1-minute candles of the composite BTC price across the current window, with the
/// same axes and reference lines as `WindowPriceChart`. Built from the bot's own
/// 1-second ticks, so the current minute updates live (exchange candle APIs lag minutes).
struct WindowCandleChart: View {
    @Environment(BotEngine.self) private var engine
    let market: KalshiMarket

    @State private var hoveredDate: Date?
    /// Layers switched off on this chart (comma-separated `ChartLayer` raw values).
    @AppStorage("candleChartHiddenLayers") private var hiddenLayers = ""

    private func shows(_ layer: ChartLayer) -> Bool { ChartLayer.isShown(layer, hidden: hiddenLayers) }

    private var samples: [(time: Date, price: Double)] {
        engine.ticks.map { (time: $0.time, price: $0.price) }
    }

    /// Every label on this chart as an edge tag, so none can overlap.
    private func tags(closes: [(time: Date, price: Double)],
                      trend: (start: (time: Date, price: Double), end: (time: Date, price: Double), slopePerSecond: Double)?,
                      extremes: WindowChart.Extremes?) -> [ChartTag] {
        let breakouts = WindowChart.breakouts(extremes, price: engine.spot, volatility: engine.volatilityPerRootSecond, market: market)
        var tags = WindowChart.referenceTags(market: market, extremes: extremes, breakouts: breakouts, price: closes.last?.price)
        if let last = closes.last {
            tags.append(ChartTag(id: "close", text: "Close \(BotEngine.usd(last.price))", color: .accentColor, value: nil, side: .trailing, rank: 1))
        }
        if let trend {
            tags.append(ChartTag(id: "trend", text: "Trend \(WindowPriceChart.perMinute(trend.slopePerSecond))",
                                 color: .white.opacity(0.8), value: nil, side: .trailing, rank: 2))
        }
        return tags
    }

    var body: some View {
        let candles = Indicators.minuteCandles(samples, from: market.openTime, to: market.closeTime)
        let values = candles.flatMap { [$0.high, $0.low] }
        // Each candle's close, plotted at the end of its minute.
        let closes = candles.map { (time: $0.time.addingTimeInterval(60), price: $0.close) }
        let trend = Self.trendLine(through: closes)
        let windowPrices = engine.windowPrices(for: market)
        let extremes = WindowChart.extremes(windowPrices, from: market.openTime, to: market.closeTime)

        Panel(title: "BTC 1-Minute Candles — Current Window", systemImage: "chart.bar.xaxis") {
            if candles.isEmpty {
                Text("Collecting prices…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
            } else {
                Chart {
                    WindowReferenceMarks(market: market, showSettlement: shows(.settlement), showTarget: shows(.target))
                    if shows(.highLow), let extremes {
                        WindowExtremeMarks(extremes: extremes, market: market, until: windowPrices.last?.time ?? .now)
                    }

                    ForEach(shows(.candles) ? candles : [], id: \.time) { candle in
                        let style: Color = candle.close >= candle.open ? .green : .red
                        // Wick: low → high.
                        RuleMark(x: .value("Minute", candle.time.addingTimeInterval(30)),
                                 yStart: .value("Low", candle.low), yEnd: .value("High", candle.high))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .foregroundStyle(style)
                        // Body: open → close, 2px gap either side via the 56s width.
                        RectangleMark(xStart: .value("Start", candle.time.addingTimeInterval(8)),
                                      xEnd: .value("End", candle.time.addingTimeInterval(52)),
                                      yStart: .value("Open", candle.open), yEnd: .value("Close", bodyEnd(candle)))
                            .foregroundStyle(style)
                            .clipShape(.rect(cornerRadius: 2))
                    }

                    // Movement line: close to close.
                    ForEach(shows(.movement) ? closes : [], id: \.time) { point in
                        LineMark(x: .value("Time", point.time), y: .value("Close", point.price),
                                 series: .value("Series", "Movement"))
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(Color.accentColor)
                            .interpolationMethod(.linear)
                        PointMark(x: .value("Time", point.time), y: .value("Close", point.price))
                            .symbolSize(18)
                            .foregroundStyle(Color.accentColor)
                    }

                    // Trend line: least-squares fit through the closes.
                    if shows(.trend), let trend {
                        ForEach([trend.start, trend.end], id: \.time) { point in
                            LineMark(x: .value("Time", point.time), y: .value("Trend", point.price),
                                     series: .value("Series", "Trend"))
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                                .foregroundStyle(Color.white.opacity(0.7))
                        }
                    }

                    if let hoveredDate, let candle = candles.last(where: { $0.time <= hoveredDate }) ?? candles.first {
                        RuleMark(x: .value("Minute", candle.time.addingTimeInterval(30)))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                tooltip(for: candle)
                            }
                    }
                }
                .windowChartAxes(market: market,
                                 // Everything drawn is inside the scale, so no line runs past the plot.
                                 yDomain: WindowChart.yDomain(values + closes.map(\.price)
                                                              + [extremes?.high.price, extremes?.low.price, trend?.start.price, trend?.end.price].compactMap { $0 },
                                                              market: market),
                                 hoveredDate: $hoveredDate,
                                 tags: tags(closes: closes, trend: trend, extremes: extremes)
                                    .filter { tag in ChartLayer.forTag(tag.id).map(shows) ?? true },
                                 focus: closes.last)
                .accessibilityLabel("BTC one-minute candles over the current 15-minute window")
                .accessibilityValue(candles.last.map { "Latest close \(BotEngine.usd($0.close))" } ?? "")
            }
        }
        .overlay(alignment: .topTrailing) {
            ChartLayerToggles(layers: ChartLayer.candleChart, hidden: $hiddenLayers)
                .padding(.top, 14)
                .padding(.trailing, 16)
        }
    }

    /// Least-squares line through the closes, spanning the first to the last.
    static func trendLine(through closes: [(time: Date, price: Double)])
        -> (start: (time: Date, price: Double), end: (time: Date, price: Double), slopePerSecond: Double)? {
        guard closes.count >= 2, let first = closes.first, let last = closes.last,
              let line = Indicators.linearFit(xs: closes.map { $0.time.timeIntervalSince(first.time) }, ys: closes.map(\.price))
        else { return nil }
        let span = last.time.timeIntervalSince(first.time)
        return ((first.time, line.intercept), (last.time, line.intercept + line.slope * span), line.slope)
    }

    /// Flat candles (open == close) still get a visible sliver of body.
    private func bodyEnd(_ candle: Candle) -> Double {
        abs(candle.close - candle.open) < 0.5 ? candle.open + (candle.close >= candle.open ? 0.5 : -0.5) : candle.close
    }

    private func tooltip(for candle: Candle) -> some View {
        WindowChart.tooltip {
            Text("\(candle.time.formatted(date: .omitted, time: .shortened)) · \(candle.close >= candle.open ? "Up" : "Down")")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 1) {
                GridRow { Text("O"); Text(BotEngine.usd(candle.open)) }
                GridRow { Text("H"); Text(BotEngine.usd(candle.high)) }
                GridRow { Text("L"); Text(BotEngine.usd(candle.low)) }
                GridRow { Text("C").bold(); Text(BotEngine.usd(candle.close)).bold() }
            }
            .font(.caption)
            if let difference = WindowChart.differenceFromTarget(candle.close, market: market) {
                Text(difference)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
