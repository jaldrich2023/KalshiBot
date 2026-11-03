//
//  PerformanceView.swift
//  KalshiBot
//
//  Day-by-day and hour-by-hour performance against Kalshi's price, highlighting
//  where the bot did better, plus the trends emerging from the log.
//

import SwiftUI
import Charts

struct PerformanceView: View {
    let records: [PredictionRecord]

    // One hover group per chart (each chart has a single popover) and one shared by the
    // cards and tables.
    @State private var cumulativeHover = HoverDetailState()
    @State private var hourHover = HoverDetailState()
    @State private var heatHover = HoverDetailState()
    @State private var hover = HoverDetailState()

    var body: some View {
        let breakdown = PerformanceBreakdown(records: records)
        ScrollView {
            if breakdown.windows.isEmpty {
                ContentUnavailableView("No settled windows yet", systemImage: "chart.bar.xaxis",
                                       description: Text("Performance appears once windows with a Kalshi price have settled."))
                    .padding(.top, 120)
            } else {
                VStack(spacing: Theme.spacing) {
                    summary(breakdown.overall)
                    tradingTimes(breakdown.tradingTimes)
                    HStack(alignment: .top, spacing: Theme.spacing) {
                        trends(breakdown.trends)
                        cumulativeChart(breakdown.cumulative)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    // Two equal columns (each panel is flexible-width) at matching heights.
                    HStack(alignment: .top, spacing: Theme.spacing) {
                        hourChart(breakdown.hours)
                        heatmap(breakdown)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    periodTable("Day by day", systemImage: "calendar", column: "Day", periods: breakdown.days)
                    HStack(alignment: .top, spacing: Theme.spacing) {
                        periodTable("Week by week", systemImage: "calendar.day.timeline.left", column: "Week", periods: breakdown.weeks)
                        periodTable("Month by month", systemImage: "calendar.circle", column: "Month", periods: breakdown.months)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Summary

    private func summary(_ overall: PerformanceBreakdown.Period) -> some View {
        Panel(title: "Against Kalshi", systemImage: "scalemass") {
            HStack(spacing: 36) {
                metric("Windows", "\(overall.windows)")
                metric("Bot accuracy", BotEngine.percent(overall.botAccuracy))
                metric("Kalshi favorite", BotEngine.percent(overall.marketAccuracy))
                metric("Brier edge / window", PerformanceBreakdown.points(overall.edge), tint: tint(overall.verdict))
                    .help("Kalshi's squared error minus the bot's, in points per window. Positive means the bot's probability was closer to the outcome.")
                VStack(alignment: .leading, spacing: 4) {
                    VerdictPill(verdict: overall.verdict)
                    Text(overall.isSignificant ? "Larger than the noise" : "Within the noise (±\(PerformanceBreakdown.magnitude(overall.edgeMargin)) pts)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text("Green marks periods where the bot's probability was closer to the outcomes than Kalshi's price; red, where Kalshi's was closer. Times are Eastern, Kalshi's clock.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).heroNumber(size: 24).foregroundStyle(tint)
        }
    }

    // MARK: Best times to trade

    private func tradingTimes(_ days: [PerformanceBreakdown.DayRanking]) -> some View {
        Panel(title: "Best times to trade", systemImage: "calendar.badge.clock") {
            // Four equal-width cards per row, so a full week never runs off the edge; every
            // card in a row takes the height of the tallest.
            let ranked = Array(days.enumerated())
            let rows = stride(from: 0, to: ranked.count, by: 4).map { Array(ranked[$0..<min($0 + 4, ranked.count)]) }
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(rows, id: \.first?.element.id) { row in
                    GridRow {
                        ForEach(row, id: \.element.id) { rank, day in
                            dayColumn(day, rank: rank + 1)
                        }
                        ForEach(0..<(4 - row.count), id: \.self) { _ in
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("Days of the week ranked by how much closer the bot's probability was to the outcomes than Kalshi's price (Brier edge, points per window), then the 4-hour blocks (ET) within each day. ✓ is calls right / windows. Days or blocks with fewer than \(PerformanceBreakdown.reliableWindows) windows are marked “few windows”: their rank can change with a handful of results.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func dayColumn(_ day: PerformanceBreakdown.DayRanking, rank: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("#\(rank)").heroNumber(size: 20).foregroundStyle(tint(day.period.verdict))
                    Text(day.period.label).font(.headline)
                }
                HStack(spacing: 8) {
                    VerdictPill(verdict: day.period.verdict)
                    Text("\(PerformanceBreakdown.points(day.period.edge)) pts")
                        .font(.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(tint(day.period.verdict))
                }
                Text("✓ \(day.period.botCorrect)/\(day.period.windows) · Kalshi \(day.period.marketCorrect)\(day.period.windows < PerformanceBreakdown.reliableWindows ? " · few windows" : "")")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverDetail(hover, id: "weekday-\(day.id)", bleed: 0) {
                PeriodDetailView(title: "\(day.period.label)s — all hours", period: day.period)
            }
            Divider()
            ForEach(Array(day.blocks.enumerated()), id: \.element.id) { blockRank, block in
                HStack(spacing: 6) {
                    Text("\(blockRank + 1)")
                        .font(.caption.weight(.bold)).monospacedDigit()
                        .frame(width: 14, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Image(systemName: block.verdict == .ahead ? "arrow.up.right" : (block.verdict == .behind ? "arrow.down.right" : "equal"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(tint(block.verdict))
                    Text(block.label).font(.caption)
                    Spacer(minLength: 4)
                    Text(PerformanceBreakdown.points(block.edge))
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(tint(block.verdict))
                    Text("✓\(block.botCorrect)/\(block.windows)")
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(block.windows < PerformanceBreakdown.reliableWindows ? .tertiary : .secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(block.verdict == .ahead ? Color.green.opacity(0.12) : .clear, in: .rect(cornerRadius: 5))
                .hoverDetail(hover, id: "block-\(day.id)-\(block.id)", bleed: 0) {
                    PeriodDetailView(title: "\(day.period.label)s, \(block.label) ET", period: block)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rank \(blockRank + 1), \(block.label)")
                .accessibilityValue("\(block.verdict == .ahead ? "Beat Kalshi" : (block.verdict == .behind ? "Trailed Kalshi" : "Even")), \(PerformanceBreakdown.points(block.edge)) points, \(block.botCorrect) of \(block.windows) right")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(rank == 1 ? 0.08 : 0.04), in: .rect(cornerRadius: 12))
        .overlay {
            if rank == 1 && day.period.verdict == .ahead {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.green.opacity(0.5), lineWidth: 1)
            }
        }
    }

    // MARK: Trends

    private func trends(_ trends: [PerformanceBreakdown.Trend]) -> some View {
        Panel(title: "Emerging trends", systemImage: "chart.line.uptrend.xyaxis") {
            if trends.isEmpty {
                Text("Not enough windows yet to spot a trend.")
                    .foregroundStyle(.secondary)
            }
            ForEach(trends) { trend in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(trend.kind))
                        .foregroundStyle(color(trend.kind))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(trend.title).font(.callout.weight(.semibold))
                            Text(trend.isConfirmed ? "Confirmed" : "Early sign")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.white.opacity(trend.isConfirmed ? 0.2 : 0.08), in: .capsule)
                                .foregroundStyle(trend.isConfirmed ? .primary : .secondary)
                                .help(trend.isConfirmed ? "Larger than its margin of error" : "Within its margin of error — could still be luck")
                        }
                        Text(trend.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func icon(_ kind: PerformanceBreakdown.Trend.Kind) -> String {
        switch kind {
        case .favorable: "arrow.up.right.circle.fill"
        case .unfavorable: "arrow.down.right.circle.fill"
        case .neutral: "info.circle.fill"
        }
    }

    private func color(_ kind: PerformanceBreakdown.Trend.Kind) -> Color {
        switch kind {
        case .favorable: .green
        case .unfavorable: .red
        case .neutral: .secondary
        }
    }

    // MARK: Cumulative edge

    private func cumulativeChart(_ points: [PerformanceBreakdown.CumulativePoint]) -> some View {
        Panel(title: "Cumulative edge over Kalshi", systemImage: "chart.xyaxis.line") {
            Chart {
                RuleMark(y: .value("Even", 0))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ForEach(points) { point in
                    LineMark(x: .value("Window", point.time), y: .value("Edge", point.edgePoints))
                        .interpolationMethod(.linear)
                        .foregroundStyle(.tint)
                }
                if let hovered = cumulativeHover.hoveredID.flatMap({ id in points.first { cumulativeID($0) == id } }) {
                    RuleMark(x: .value("Window", hovered.time))
                        .foregroundStyle(.white.opacity(0.35))
                    PointMark(x: .value("Window", hovered.time), y: .value("Edge", hovered.edgePoints))
                        .foregroundStyle(.white)
                        .symbolSize(50)
                }
                if let last = points.last {
                    PointMark(x: .value("Window", last.time), y: .value("Edge", last.edgePoints))
                        .foregroundStyle(last.edgePoints >= 0 ? .green : .red)
                        .annotation(position: .top, alignment: .trailing) {
                            Text("\(last.edgePoints >= 0 ? "+" : "−")\(abs(last.edgePoints).formatted(.number.precision(.fractionLength(2)))) pts")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(last.edgePoints >= 0 ? .green : .red)
                        }
                }
            }
            .chartYAxisLabel("Brier points")
            .chartOverlay { proxy in
                ChartHoverDetail(proxy: proxy, state: cumulativeHover, resolve: { location in
                    // The window nearest the pointer along the time axis.
                    guard let time = proxy.value(atX: location.x, as: Date.self) else { return nil }
                    return points.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
                        .map(cumulativeID)
                }, popup: { id in
                    cumulativeDetail(id, points: points)
                })
            }
            // Stretches to fill the card when the trends list beside it is taller.
            .frame(minHeight: 220, idealHeight: 220, maxHeight: .infinity)
            Text("Running total of the per-window edge. Rising means the bot is pulling ahead of Kalshi's price; falling, falling behind; flat, matching it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Hour by hour

    private func hourChart(_ hours: [PerformanceBreakdown.Period]) -> some View {
        Panel(title: "Hour by hour (ET, all days)", systemImage: "clock") {
            Chart {
                RuleMark(y: .value("Even", 0)).foregroundStyle(.white.opacity(0.35))
                ForEach(Array(hours.enumerated()), id: \.offset) { hour, period in
                    if period.windows > 0 {
                        BarMark(x: .value("Hour", period.label), y: .value("Edge", period.edge * 100))
                            .foregroundStyle(tint(period.verdict).opacity(hourOpacity(period)))
                            .annotation(position: period.edge >= 0 ? .top : .bottom) {
                                Text("\(period.botCorrect)/\(period.windows)")
                                    .font(.system(size: 9).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityLabel("\(period.label)")
                            .accessibilityValue("\(period.windows) windows, bot right on \(period.botCorrect), Kalshi on \(period.marketCorrect), edge \(PerformanceBreakdown.points(period.edge)) points")
                    } else {
                        // Keep empty hours on the axis so the day reads left to right.
                        BarMark(x: .value("Hour", period.label), y: .value("Edge", 0))
                            .foregroundStyle(.clear)
                    }
                }
            }
            .chartXScale(domain: hours.map(\.label))
            .chartXAxis { hourAxis(hours.map(\.label)) }
            .chartYAxisLabel("Brier edge, points / window")
            .chartOverlay { proxy in
                ChartHoverDetail(proxy: proxy, state: hourHover, resolve: { location in
                    guard let label = proxy.value(atX: location.x, as: String.self),
                          hours.contains(where: { $0.label == label && $0.windows > 0 }) else { return nil }
                    return label
                }, popup: { label in
                    if let period = hours.first(where: { $0.label == label }) {
                        PeriodDetailView(title: "\(label) ET — all days", period: period)
                    }
                })
            }
            .frame(height: 220)
            Text("Bars above zero: the bot beat Kalshi's price in that hour. Labels show calls right / windows. Faded bars are within the noise.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Day × hour

    private func heatmap(_ breakdown: PerformanceBreakdown) -> some View {
        let days = breakdown.days.map(\.label)
        let hours = breakdown.hours.map(\.label)
        // Scale color to the largest gap seen, so small logs still show contrast.
        let scale = max(breakdown.cells.map { abs($0.period.edge) }.max() ?? 0, 0.001)
        return Panel(title: "Day × hour", systemImage: "square.grid.3x3.fill") {
            Chart(breakdown.cells) { cell in
                RectangleMark(x: .value("Hour", PerformanceBreakdown.hourLabel(cell.hour)), y: .value("Day", cell.day))
                    .foregroundStyle(heatHover.hoveredID == cell.id ? .white.opacity(0.55) : heatColor(cell.period, scale: scale))
                    .cornerRadius(3)
                    .annotation(position: .overlay) {
                        Text(cell.period.verdict == .ahead ? "▲" : (cell.period.verdict == .behind ? "▼" : "="))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .accessibilityLabel("\(cell.day), \(PerformanceBreakdown.hourLabel(cell.hour))")
                    .accessibilityValue("\(cell.period.windows) windows, edge \(PerformanceBreakdown.points(cell.period.edge)) points")
            }
            .chartXScale(domain: hours)
            .chartXAxis { hourAxis(hours) }
            .chartYScale(domain: days.reversed())
            .chartOverlay { proxy in
                ChartHoverDetail(proxy: proxy, state: heatHover, resolve: { location in
                    guard let hour = proxy.value(atX: location.x, as: String.self),
                          let day = proxy.value(atY: location.y, as: String.self) else { return nil }
                    return breakdown.cells.first { $0.day == day && PerformanceBreakdown.hourLabel($0.hour) == hour }?.id
                }, popup: { id in
                    if let cell = breakdown.cells.first(where: { $0.id == id }) {
                        PeriodDetailView(title: "\(cell.day), \(PerformanceBreakdown.hourLabel(cell.hour)) ET", period: cell.period)
                    }
                })
            }
            // Sized by its rows, then stretched to fill the card when the hour-by-hour
            // card beside it is taller.
            .frame(minHeight: max(CGFloat(days.count) * 30 + 30, 90),
                   idealHeight: max(CGFloat(days.count) * 30 + 30, 90),
                   maxHeight: .infinity)
            Text("Each cell is one hour on one day: ▲ green, the bot was closer than Kalshi; ▼ red, Kalshi was closer; = even. Deeper color, bigger gap.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Every third hour labelled, so 24 columns fit at half the window's width.
    private func hourAxis(_ labels: [String]) -> some AxisContent {
        AxisMarks(values: labels.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)) {
            AxisGridLine()
            AxisValueLabel()
        }
    }

    private func heatColor(_ period: PerformanceBreakdown.Period, scale: Double) -> Color {
        let strength = 0.3 + 0.7 * min(abs(period.edge) / scale, 1)
        switch period.verdict {
        case .ahead: return .green.opacity(strength)
        case .behind: return .red.opacity(strength)
        case .even: return .white.opacity(0.15)
        }
    }

    // MARK: Day by day

    /// One row per period, newest first; periods where the bot beat Kalshi are tinted green.
    private func periodTable(_ title: String, systemImage: String, column: String,
                             periods days: [PerformanceBreakdown.Period]) -> some View {
        Panel(title: title, systemImage: systemImage) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 0) {
                GridRow {
                    ForEach([column, "Windows", "Bot", "Kalshi", "Brier edge", "Result"], id: \.self) {
                        Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                ForEach(days.reversed()) { day in
                    let id = "\(column)-\(day.id)"
                    GridRow {
                        tableCell(id, column: 0, day) { Text(day.label) }
                        tableCell(id, column: 1, day) { Text("\(day.windows)").monospacedDigit() }
                        tableCell(id, column: 2, day) { Text("\(BotEngine.percent(day.botAccuracy)) (\(day.botCorrect))").monospacedDigit() }
                        tableCell(id, column: 3, day) { Text("\(BotEngine.percent(day.marketAccuracy)) (\(day.marketCorrect))").monospacedDigit() }
                        tableCell(id, column: 4, day) {
                            Text("\(PerformanceBreakdown.points(day.edge)) pts").monospacedDigit().foregroundStyle(tint(day.verdict))
                        }
                        tableCell(id, column: 5, day) {
                            HStack(spacing: 6) {
                                VerdictPill(verdict: day.verdict)
                                if day.isSignificant {
                                    Text("beyond noise").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .background {
                        if day.verdict == .ahead {
                            RoundedRectangle(cornerRadius: 6).fill(.green.opacity(0.12)).padding(.horizontal, -8)
                        }
                    }
                }
            }
        }
    }

    /// One cell of a period table; every cell in a row shares the row's popover.
    private func tableCell<Content: View>(_ id: String, column: Int, _ period: PerformanceBreakdown.Period,
                                          @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.vertical, 6)
            .hoverDetail(hover, id: id, column: column, bleed: 12) {
                PeriodDetailView(title: period.label, period: period)
            }
    }

    // MARK: Hover detail

    private func cumulativeID(_ point: PerformanceBreakdown.CumulativePoint) -> String {
        "\(point.time.timeIntervalSince1970)"
    }

    /// Hovered bars stand out; the rest fade a little while one is hovered.
    private func hourOpacity(_ period: PerformanceBreakdown.Period) -> Double {
        let base = period.isSignificant ? 1 : 0.7
        guard let hovered = hourHover.hoveredID else { return base }
        return hovered == period.label ? 1 : base * 0.45
    }

    /// The hovered window's call breakdown, plus what it did to the running edge.
    @ViewBuilder
    private func cumulativeDetail(_ id: String, points: [PerformanceBreakdown.CumulativePoint]) -> some View {
        if let index = points.firstIndex(where: { cumulativeID($0) == id }) {
            let point = points[index]
            let change = point.edgePoints - (index > 0 ? points[index - 1].edgePoints : 0)
            VStack(alignment: .leading, spacing: 0) {
                if let record = records.first(where: { $0.openTime == point.time }) {
                    CallBreakdownView(explanation: CallExplanation(record: record))
                } else {
                    Text(point.time.formatted(date: .abbreviated, time: .shortened)).font(.headline).padding(16)
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                    GridRow {
                        Text("This window's edge").foregroundStyle(.secondary)
                        Text("\(signed(change)) pts").foregroundStyle(change >= 0 ? .green : .red)
                    }
                    GridRow {
                        Text("Running total").foregroundStyle(.secondary)
                        Text("\(signed(point.edgePoints)) pts after window \(index + 1) of \(points.count)")
                    }
                }
                .monospacedDigit()
                .padding(16)
            }
            .frame(width: 460, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func signed(_ points: Double) -> String {
        "\(points >= 0 ? "+" : "−")\(abs(points).formatted(.number.precision(.fractionLength(2))))"
    }

    private func tint(_ verdict: PerformanceBreakdown.Verdict) -> Color {
        switch verdict {
        case .ahead: .green
        case .behind: .red
        case .even: .secondary
        }
    }
}

/// "Beat Kalshi" / "Trailed Kalshi" / "Even", with an arrow so it never relies on color alone.
private struct VerdictPill: View {
    let verdict: PerformanceBreakdown.Verdict

    var body: some View {
        let (text, symbol, color): (String, String, Color) = switch verdict {
        case .ahead: ("Beat Kalshi", "arrow.up.right", .green)
        case .behind: ("Trailed Kalshi", "arrow.down.right", .red)
        case .even: ("Even", "equal", .secondary)
        }
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((verdict == .even ? Color.white : color).opacity(0.14), in: .capsule)
    }
}
