//
//  WindowPriceChart.swift
//  KalshiBot
//

import SwiftUI
import Charts

/// Trailing 60-second average of the composite BTC price across the current window,
/// against the window's target. Each point is what the settlement value would be if
/// the window closed at that moment, so it compares like-for-like with the target.
struct WindowPriceChart: View {
    @Environment(BotEngine.self) private var engine
    let market: KalshiMarket
    /// This window's locked call, for the stop-loss and take-profit lines.
    var record: PredictionRecord?
    /// Where past calls at a similar confidence were made (from the prediction log).
    var similar: PredictionRecord.SimilarCallZone?
    /// Layers switched off on this chart (comma-separated `ChartLayer` raw values).
    @AppStorage("priceChartHiddenLayers") private var hiddenLayers = ""

    private func shows(_ layer: ChartLayer) -> Bool { ChartLayer.isShown(layer, hidden: hiddenLayers) }

    @State private var hoveredDate: Date?

    private struct PricePoint: Identifiable {
        let time: Date
        let price: Double
        var id: Date { time }
    }

    /// Built from 1-second composite ticks only. Ticks from the minute before the open
    /// are included so the average is valid from the first second of the window; if the
    /// app launched mid-window, the line starts once a full 60s of ticks exists.
    private var points: [PricePoint] {
        averages(from: market.openTime, to: market.closeTime)
    }

    private func averages(from open: Date, to close: Date) -> [PricePoint] {
        let samples = engine.ticks
            .filter { $0.time > open.addingTimeInterval(-60) && $0.time <= close }
            .map { (time: $0.time, price: $0.price) }
        return Indicators.trailingAverage(samples)
            .filter { $0.time >= open }
            .map { PricePoint(time: $0.time, price: $0.average) }
    }

    private var projection: WindowProjection? {
        WindowProjection.fit(engine.ticks.map { (time: $0.time, price: $0.price) },
                             open: market.openTime, close: market.closeTime, volatility: engine.volatilityPerRootSecond)
    }

    /// Expected 60s-average path from now to the close if the price holds: the average
    /// catches up with the current price over the next minute, then stays level.
    private func projectionPath(from last: PricePoint, _ projection: WindowProjection) -> [(time: Date, center: Double)] {
        let total = market.closeTime.timeIntervalSince(last.time)
        guard total > 0 else { return [] }
        let steps = max(Int(total / 30), 1)
        return (0...steps).map { step in
            let elapsed = total * Double(step) / Double(steps)
            let catchUp = min(elapsed / 60, 1)
            return (last.time.addingTimeInterval(elapsed), last.price + (projection.forecastSettlement - last.price) * catchUp)
        }
    }

    /// The ±1σ range for the closing value, as it stood at each moment of the window: the
    /// price then, ± the settlement uncertainty for the time left then. It narrows toward
    /// the close as time runs out. From now to the close it holds at today's range.
    private func closeRange(_ projection: WindowProjection, now: Date) -> [(time: Date, low: Double, high: Double)] {
        let window = engine.ticks.filter { $0.time >= market.openTime && $0.time <= now }
        guard let first = window.first else { return [] }
        var range: [(time: Date, low: Double, high: Double)] = []
        var next = first.time
        for tick in window where tick.time >= next {
            let sigma = projection.settlementSigma(secondsRemaining: market.closeTime.timeIntervalSince(tick.time))
            range.append((tick.time, tick.price - sigma, tick.price + sigma))
            next = tick.time.addingTimeInterval(20)
        }
        let sigmaNow = projection.settlementSigma(secondsRemaining: market.closeTime.timeIntervalSince(now))
        let forecast = projection.forecastSettlement
        // Each time appears once: the chart identifies these points by time. A tick taken
        // right now gives way to the forecast, and at the close "now" is the close.
        if range.last?.time == now { range.removeLast() }
        range.append((now, forecast - sigmaNow, forecast + sigmaNow))
        if market.closeTime > now {
            range.append((market.closeTime, forecast - sigmaNow, forecast + sigmaNow))
        }
        return range
    }

    /// The fitted trend over the stretch it describes (not extended — see `WindowProjection`).
    private func trendSegment(_ projection: WindowProjection) -> [(time: Date, price: Double)] {
        [projection.fitStart, projection.fitEnd].map {
            (market.openTime.addingTimeInterval($0), projection.trendValue(at: $0))
        }
    }

    /// This window's call, once locked: when, and where on the 60s line (the plotted
    /// average at that second; the index estimate if the line hadn't started).
    private func callPoint(in points: [PricePoint]) -> (time: Date, price: Double, record: PredictionRecord)? {
        guard let record, record.ticker == market.ticker, !record.isAwaitingCall else { return nil }
        let onLine = nearest(to: record.predictedAt, in: points).flatMap { abs($0.time.timeIntervalSince(record.predictedAt)) <= 2 ? $0.price : nil }
        return (record.predictedAt, onLine ?? record.spotAtPrediction, record)
    }

    /// The similar-calls box in chart coordinates, on the called side of the target.
    private func similarBox() -> (start: Date, end: Date, low: Double, high: Double)? {
        guard let similar, let record, record.ticker == market.ticker, !record.isAwaitingCall else { return nil }
        let direction: Double = record.predictedUp ? 1 : -1
        let a = record.strike + direction * similar.distanceLow, b = record.strike + direction * similar.distanceHigh
        // At least 20 seconds wide and $2 tall, so a tight cluster is still visible.
        let start = market.openTime.addingTimeInterval(similar.lockStart)
        let end = market.openTime.addingTimeInterval(max(similar.lockEnd, similar.lockStart + 20))
        let low = min(a, b), high = max(max(a, b), min(a, b) + 2)
        return (start, end, low, high)
    }

    private func nearest(to date: Date, in points: [PricePoint]) -> PricePoint? {
        points.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
    }

    /// Stop-loss and take-profit for the called position, as lines and tags.
    private func exitLines(_ plan: ExitPlan) -> [(id: String, price: Double, color: Color, tag: ChartTag)] {
        let side = plan.calledUp ? "Yes" : "No"
        let position = engine.position(for: market, record: record)
        func dollars(_ amount: Double?) -> String {
            amount.map { " · \($0 >= 0 ? "+" : "−")\(BotEngine.usd(abs($0)))" } ?? ""
        }
        let entry = StrategyAdvisor.cents(plan.entry)
        var lines: [(id: String, price: Double, color: Color, tag: ChartTag)] = []
        if let profit = plan.takeProfit {
            lines.append(("Take profit", profit, .mint,
                          ChartTag(id: "takeProfit",
                                   text: "◎ Take profit \(BotEngine.usd(profit)) · \(side) in at \(entry) sells ~\(StrategyAdvisor.cents(plan.takeProfitSale))\(dollars(position?.profitAtTakeProfit))",
                                   color: .mint, value: profit, side: .leading,
                                   // Labels sit on the far side of their line from the price.
                                   placement: plan.calledUp ? .above : .below)))
        }
        if let stop = plan.stop {
            let name = plan.exitNow ? "⨯ Exit now" : (plan.stopIsTrailing ? "⨯ Trailing stop" : "⨯ Stop-loss")
            lines.append(("Stop", stop, .orange,
                          ChartTag(id: "stop",
                                   text: "\(name) \(BotEngine.usd(stop)) · \(side) in at \(entry) sells ~\(StrategyAdvisor.cents(plan.stopSale))\(dollars(position?.profitAtStop))",
                                   color: .orange, value: stop, side: .leading,
                                   placement: plan.calledUp ? .below : .above)))
        }
        return lines
    }

    /// Every label on this chart as an edge tag, so none can overlap.
    private func tags(points: [PricePoint], trend: [(time: Date, price: Double)], path: [(time: Date, center: Double)],
                      projection: WindowProjection?, extremes: WindowChart.Extremes?) -> [ChartTag] {
        // Breakout odds from the same "Now" price the high and low are measured on.
        let breakouts = WindowChart.breakouts(extremes, price: points.last?.price, volatility: engine.volatilityPerRootSecond, market: market,
                                              calibration: engine.riskCalibration)
        var tags = WindowChart.referenceTags(market: market, extremes: extremes, breakouts: breakouts, price: points.last?.price)
        if let last = points.last {
            tags.append(ChartTag(id: "price", text: "Now \(BotEngine.usd(last.price))", color: .primary, value: nil, side: .trailing, rank: 1))
        }
        if let end = path.last {
            tags.append(ChartTag(id: "projected", text: "◆ Projected \(BotEngine.usd(end.center))", color: .accentColor, value: nil, side: .trailing, rank: 3))
        }
        if let call = callPoint(in: points) {
            let r = call.record
            tags.append(ChartTag(id: "call",
                                 text: "\(r.predictedUp ? "▲ Called Up" : "▼ Called Down") \(BotEngine.percent(r.confidence)) · \(r.predictedAt.formatted(date: .omitted, time: .standard)) (\(PredictionRecord.offsetText(r.lockOffset)))",
                                 color: r.predictedUp ? .green : .red, value: call.price, side: .center,
                                 placement: r.predictedUp ? .above : .below))
        }
        if let similar, similarBox() != nil {
            tags.append(ChartTag(id: "similar",
                                 text: "▭ Similar calls: \(similar.count) at \(similar.bandLow)–\(similar.bandHigh)%, locked \(PredictionRecord.offsetText(similar.lockStart))–\(PredictionRecord.offsetText(similar.lockEnd))",
                                 color: .secondary, value: nil, side: .leading, rank: 4))
        }
        if !trend.isEmpty, let projection {
            tags.append(ChartTag(id: "trend", text: "Trend \(Self.perMinute(projection.slopePerSecond))", color: .white.opacity(0.8), value: nil, side: .trailing, rank: 2))
        }
        return tags
    }

    var body: some View {
        let points = points
        let projection = projection
        let path = points.last.flatMap { last in projection.map { projectionPath(from: last, $0) } } ?? []
        let trend = projection.map(trendSegment) ?? []
        let range = projection.map { closeRange($0, now: points.last?.time ?? .now) } ?? []
        // High and low of the plotted series — the 60s average that the "Now" tag shows.
        let extremes = WindowChart.extremes(points.map { (time: $0.time, price: $0.price) },
                                            from: market.openTime, to: market.closeTime)
        let exits = engine.exitPlan(for: market, record: record)

        Panel(title: "BTC 60s Average — Current Window", systemImage: "chart.xyaxis.line") {
            // Always laid out (dashes until there's a trend) so the chart never shifts.
            projectionSummary(projection)
            if points.isEmpty {
                Text("Collecting 60s of prices…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
            } else {
                Chart {
                    WindowReferenceMarks(market: market, showSettlement: shows(.settlement), showTarget: shows(.target))
                    // Highest and lowest "Now" price (60s average) this window.
                    if shows(.highLow), let extremes {
                        WindowExtremeMarks(extremes: extremes, market: market, until: points.last?.time ?? .now)
                    }

                    // Where to exit the called position: stop-loss (or trailing stop) and take-profit,
                    // from now to the close.
                    if shows(.exits), let exits, let now = points.last?.time {
                        ForEach(exitLines(exits), id: \.id) { line in
                            RuleMark(xStart: .value("From", now), xEnd: .value("To", market.closeTime),
                                     y: .value(line.id, line.price))
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                                .foregroundStyle(line.color.opacity(0.85))
                        }
                    }

                    // ±1σ range for the closing value — tightens as the window runs down.
                    ForEach(shows(.closeRange) ? range : [], id: \.time) { step in
                        AreaMark(x: .value("Time", step.time),
                                 yStart: .value("Low", step.low),
                                 yEnd: .value("High", step.high),
                                 series: .value("Series", "Close range"))
                            .foregroundStyle(Color.accentColor.opacity(0.12))
                            .interpolationMethod(.linear)
                    }

                    // Where past calls at a similar confidence were made (middle half of each).
                    if shows(.similar), let box = similarBox() {
                        RectangleMark(xStart: .value("From", box.start), xEnd: .value("To", box.end),
                                      yStart: .value("Low", box.low), yEnd: .value("High", box.high))
                            .foregroundStyle((record?.predictedUp == true ? Color.green : Color.red).opacity(0.14))
                    }

                    ForEach(shows(.line) ? points : []) { point in
                        LineMark(x: .value("Time", point.time), y: .value("60s average", point.price),
                                 series: .value("Series", "60s average"))
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.linear)
                    }

                    // Trend line: the straight-line fit through the window's prices so far.
                    ForEach(shows(.trend) ? trend : [], id: \.time) { point in
                        LineMark(x: .value("Time", point.time), y: .value("Trend", point.price),
                                 series: .value("Series", "Trend"))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }

                    // Projected close: the expected path if the price holds.
                    ForEach(shows(.projection) ? path : [], id: \.time) { step in
                        LineMark(x: .value("Time", step.time), y: .value("Projected", step.center),
                                 series: .value("Series", "Projection"))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .foregroundStyle(Color.accentColor.opacity(0.9))
                            .interpolationMethod(.linear)
                    }
                    if shows(.projection), let end = path.last {
                        PointMark(x: .value("Time", end.time), y: .value("Projected", end.center))
                            .symbol(.diamond)
                            .symbolSize(60)
                            .foregroundStyle(Color.accentColor)
                    }

                    if shows(.now), let last = points.last {
                        PointMark(x: .value("Time", last.time), y: .value("Price", last.price))
                            .symbolSize(64)
                    }

                    // The exact moment and price the call locked.
                    if shows(.call), let call = callPoint(in: points) {
                        let color: Color = call.record.predictedUp ? .green : .red
                        RuleMark(x: .value("Called", call.time))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .foregroundStyle(color.opacity(0.6))
                        PointMark(x: .value("Called", call.time), y: .value("Price", call.price))
                            .symbol(.triangle)
                            .symbolSize(140)
                            .foregroundStyle(color)
                    }

                    if let hoveredDate, let hovered = nearest(to: hoveredDate, in: points) {
                        RuleMark(x: .value("Time", hovered.time))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                tooltip(for: hovered)
                            }
                        PointMark(x: .value("Time", hovered.time), y: .value("Price", hovered.price))
                            .symbolSize(80)
                    }
                }
                .windowChartAxes(market: market,
                                 yDomain: WindowChart.yDomain(points.map(\.price) + trend.map(\.price) + path.map(\.center)
                                                              + range.flatMap { [$0.low, $0.high] }
                                                              + [extremes?.high.price, extremes?.low.price].compactMap { $0 }
                                                              + (exits.map { exitLines($0).map(\.price) } ?? [])
                                                              + (shows(.call) ? [callPoint(in: points)?.price].compactMap { $0 } : [])
                                                              + (shows(.similar) ? similarBox().map { [$0.low, $0.high] } ?? [] : []),
                                                              market: market),
                                 hoveredDate: $hoveredDate,
                                 tags: (tags(points: points, trend: trend, path: path, projection: projection, extremes: extremes)
                                    + (exits.map { exitLines($0).map(\.tag) } ?? []))
                                    .filter { tag in ChartLayer.forTag(tag.id).map(shows) ?? true },
                                 focus: points.last.map { (time: $0.time, price: $0.price) })
                .accessibilityLabel("BTC 60-second average price over the current 15-minute window")
                .accessibilityValue(accessibilitySummary(points))
            }
        }
        .overlay(alignment: .topTrailing) {
            ChartLayerToggles(layers: ChartLayer.priceChart, hidden: $hiddenLayers)
                .padding(.top, 14)
                .padding(.trailing, 16)
        }
    }

    static func perMinute(_ slopePerSecond: Double) -> String {
        "\(slopePerSecond >= 0 ? "+" : "−")\(BotEngine.usd(abs(slopePerSecond * 60)))/min"
    }

    /// Trend rate, projected settlement, and the chance of Up from the current price.
    @ViewBuilder
    private func projectionSummary(_ projection: WindowProjection?) -> some View {
        let secondsLeft = market.closeTime.timeIntervalSinceNow
        HStack(spacing: 24) {
            summaryMetric("Trend so far", projection.map { Self.perMinute($0.slopePerSecond) } ?? "—")
                .infoTip("Trend so far", "Slope of the straight-line fit through this window's prices, in dollars per minute. Descriptive only: extending it to the close was a poor forecast in backtests.")
            summaryMetric("Projected close", projection.map { BotEngine.usd($0.forecastSettlement) } ?? "—")
                .infoTip("Projected close", "The forecast for the settlement value: the current price. In a 30-day backtest it beat the extended trend at every minute, because short-term moves don't carry on predictably.")
            summaryMetric("vs. target", projection.flatMap {
                WindowChart.differenceFromTarget($0.forecastSettlement, market: market)?.replacingOccurrences(of: " vs. target", with: "")
            } ?? "—")
            .infoTip("vs. target", "How far the projected close is above or below the target. Above means the window would settle Up if the price held.")
            summaryMetric("P(up) from price now", projection.flatMap { projection in
                market.floorStrike.map {
                    // Same calibrated odds as the Reversal Risk card.
                    BotEngine.percent(SettlementOdds.estimate(price: projection.forecastSettlement, strike: $0,
                                                              secondsRemaining: secondsLeft,
                                                              volatility: projection.volatilityPerRootSecond).probabilityUp)
                }
            } ?? "—")
            .infoTip("P(up) from price now", "Probability of settling at or above the target from the current price, time left and volatility — calibrated on 30 days of windows. It's the same calculation as the Reversal Risk card, from the Up side.")
            summaryMetric("Close range", projection.map {
                "±\(BotEngine.usd($0.settlementSigma(secondsRemaining: secondsLeft)))"
            } ?? "—")
            .infoTip("Close range", "±1σ for the settlement from the current price (shaded on the chart): about two windows in three settle inside it. It narrows as the window runs down; the funnel shows how it has tightened.")
        }
        .accessibilityElement(children: .combine)
    }

    private func summaryMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
    }

    private func tooltip(for point: PricePoint) -> some View {
        WindowChart.tooltip {
            Text(point.time.formatted(date: .omitted, time: .standard))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("60s avg \(BotEngine.usd(point.price))")
                .font(.caption.bold())
            if let difference = WindowChart.differenceFromTarget(point.price, market: market) {
                Text(difference)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func accessibilitySummary(_ points: [PricePoint]) -> String {
        guard let last = points.last else { return "" }
        var summary = "Latest 60s average \(BotEngine.usd(last.price))"
        if let strike = market.floorStrike {
            summary += ", \(last.price >= strike ? "above" : "below") target \(BotEngine.usd(strike))"
        }
        return summary
    }
}
