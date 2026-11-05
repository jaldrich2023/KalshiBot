//
//  PerformanceBreakdown.swift
//  KalshiBot
//
//  The live log broken down day by day and hour by hour (Eastern time, Kalshi's
//  clock), compared with Kalshi's own price on the same windows, plus the trends
//  emerging from it.
//
//  The bot's probability is usually within a point of Kalshi's, so both pick the
//  same side almost every window and accuracy rarely separates them. The comparison
//  is therefore on Brier score — how close each probability was to the outcome —
//  which still differs when the sides agree.
//

import Foundation

nonisolated struct PerformanceBreakdown: Sendable {

    /// One settled window that has both the bot's call and Kalshi's price.
    struct Window: Sendable {
        let openTime: Date
        let probabilityUp: Double
        let marketYesMid: Double
        let actualUp: Bool

        var botCorrect: Bool { (probabilityUp >= 0.5) == actualUp }
        var marketCorrect: Bool { (marketYesMid >= 0.5) == actualUp }
        private var y: Double { actualUp ? 1 : 0 }
        var botBrier: Double { (probabilityUp - y) * (probabilityUp - y) }
        var marketBrier: Double { (marketYesMid - y) * (marketYesMid - y) }
        /// Kalshi's squared error minus the bot's: positive = the bot was closer. Floating-point
        /// leftovers (the bot quoting Kalshi's own price) count as exactly even, so charts
        /// don't scale to 1e-15.
        var edge: Double {
            let difference = marketBrier - botBrier
            return abs(difference) < 1e-9 ? 0 : difference
        }
    }

    enum Verdict: Sendable { case ahead, behind, even }

    /// A group of windows (a day, an hour of day, or one hour on one day).
    struct Period: Sendable, Identifiable {
        let id: String
        let label: String
        let windows: Int
        let botCorrect: Int
        let marketCorrect: Int
        /// Mean Brier edge (fraction; ×100 for points). Positive = bot better.
        let edge: Double
        /// 95% margin of error on `edge` (t-based for small samples; infinite with one window).
        let edgeMargin: Double
        /// Windows that settled Up.
        var settledUp = 0
        /// Average confidence of the bot's calls (0.5–1).
        var meanConfidence = 0.5
        /// Windows where the bot and Kalshi's favorite picked different sides.
        var disagreements = 0
        /// Windows whose edge wasn't exactly even (the bot didn't just quote Kalshi's price).
        var unevenWindows = 0

        var botAccuracy: Double { windows > 0 ? Double(botCorrect) / Double(windows) : 0 }
        var marketAccuracy: Double { windows > 0 ? Double(marketCorrect) / Double(windows) : 0 }

        /// Gaps under this (0.05 Brier points) are treated as a tie in the trends.
        static let evenBelow = 0.0005

        /// Follows the Brier edge shown beside it — the same measure the tint, ranking and
        /// significance use. An edge that rounds to 0.00 points is even.
        var verdict: Verdict {
            let shown = PerformanceBreakdown.hundredthsOfPoints(edge)
            return shown > 0 ? .ahead : (shown < 0 ? .behind : .even)
        }
        /// The difference is larger than its margin of error, on enough windows that differed
        /// to judge.
        var isSignificant: Bool {
            unevenWindows >= AccuracyStats.minimumPairedDifferences && abs(edge) > edgeMargin
        }
    }

    /// One day of the week with its time blocks, for ranking when to trade.
    struct DayRanking: Sendable, Identifiable {
        /// Calendar weekday, 1 = Sunday.
        let weekday: Int
        let period: Period
        /// Four-hour blocks on this weekday, best first.
        let blocks: [Period]
        var id: Int { weekday }
    }

    struct Cell: Sendable, Identifiable {
        let day: String
        let hour: Int
        let period: Period
        var id: String { "\(day)-\(hour)" }
    }

    struct CumulativePoint: Sendable, Identifiable {
        let time: Date
        /// Running total of the Brier edge, in points (×100).
        let edgePoints: Double
        var id: Date { time }
    }

    struct Trend: Sendable, Identifiable {
        enum Kind: Sendable { case favorable, unfavorable, neutral }
        let kind: Kind
        let title: String
        let detail: String
        /// Larger than its margin of error; otherwise it's an early sign only.
        let isConfirmed: Bool
        var id: String { title }
    }

    let windows: [Window]
    let overall: Period
    /// Eastern calendar days, oldest → newest.
    let days: [Period]
    /// Weeks starting Monday (Eastern), oldest → newest.
    let weeks: [Period]
    /// Calendar months (Eastern), oldest → newest.
    let months: [Period]
    /// Hours of the day 0–23 (Eastern), across all days; empty hours have 0 windows.
    let hours: [Period]
    let cells: [Cell]
    let cumulative: [CumulativePoint]
    let trends: [Trend]
    /// Days of the week, best first, each with its time blocks ranked.
    let tradingTimes: [DayRanking]

    /// Hours per time block in `tradingTimes`.
    static let blockHours = 4
    /// Fewer windows than this in a day or block is flagged as too few to rely on.
    static let reliableWindows = 30

    /// Windows compared in the "recent form" trend (6 hours).
    static let recentCount = 24

    static var eastern: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        calendar.firstWeekday = 2  // Monday
        return calendar
    }

    /// - Parameter windows: settled windows in any order.
    init(_ windows: [Window]) {
        let sorted = windows.sorted { $0.openTime < $1.openTime }
        let calendar = Self.eastern
        self.windows = sorted
        overall = Self.period(sorted, id: "all", label: "All windows")

        var dayStyle = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        dayStyle.timeZone = calendar.timeZone
        let byDay = Dictionary(grouping: sorted) { calendar.startOfDay(for: $0.openTime) }
        days = byDay.keys.sorted().map { start in
            Self.period(byDay[start] ?? [], id: start.ISO8601Format(), label: start.formatted(dayStyle))
        }
        weeks = Self.periods(sorted, by: .weekOfYear, calendar: calendar) { start in
            var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
            style.timeZone = calendar.timeZone
            return "Week of \(start.formatted(style))"
        }
        months = Self.periods(sorted, by: .month, calendar: calendar) { start in
            var style = Date.FormatStyle.dateTime.month(.wide).year()
            style.timeZone = calendar.timeZone
            return start.formatted(style)
        }

        let byHour = Dictionary(grouping: sorted) { calendar.component(.hour, from: $0.openTime) }
        hours = (0..<24).map { hour in
            Self.period(byHour[hour] ?? [], id: "h\(hour)", label: Self.hourLabel(hour))
        }

        cells = byDay.keys.sorted().flatMap { start -> [Cell] in
            let dayLabel = start.formatted(dayStyle)
            let dayHours = Dictionary(grouping: byDay[start] ?? []) { calendar.component(.hour, from: $0.openTime) }
            return dayHours.keys.sorted().map { hour in
                Cell(day: dayLabel, hour: hour,
                     period: Self.period(dayHours[hour] ?? [], id: "\(start.ISO8601Format())-\(hour)", label: Self.hourLabel(hour)))
            }
        }

        var running = 0.0
        cumulative = sorted.map { window in
            running += window.edge * 100
            return CumulativePoint(time: window.openTime, edgePoints: running)
        }

        trends = Self.trends(sorted, days: days, byHour: byHour, calendar: calendar)
        tradingTimes = Self.tradingTimes(sorted, calendar: calendar)
    }

    /// Groups windows by the calendar `unit` (week, month…) they open in, oldest first.
    static func periods(_ windows: [Window], by unit: Calendar.Component, calendar: Calendar,
                        label: (Date) -> String) -> [Period] {
        let grouped = Dictionary(grouping: windows) { calendar.dateInterval(of: unit, for: $0.openTime)?.start ?? $0.openTime }
        return grouped.keys.sorted().map { start in
            period(grouped[start] ?? [], id: start.ISO8601Format(), label: label(start))
        }
    }

    static func period(_ windows: [Window], id: String, label: String) -> Period {
        let edges = windows.map(\.edge)
        let n = Double(edges.count)
        let (mean, margin) = n > 0 ? AccuracyStats.meanAndMargin(edges) : (0, .infinity)
        return Period(id: id, label: label, windows: windows.count,
                      botCorrect: windows.filter(\.botCorrect).count,
                      marketCorrect: windows.filter(\.marketCorrect).count,
                      edge: mean, edgeMargin: margin,
                      settledUp: windows.filter(\.actualUp).count,
                      meanConfidence: n > 0 ? windows.map { max($0.probabilityUp, 1 - $0.probabilityUp) }.reduce(0, +) / n : 0.5,
                      disagreements: windows.filter { ($0.probabilityUp >= 0.5) != ($0.marketYesMid >= 0.5) }.count,
                      unevenWindows: edges.count { $0 != 0 })
    }

    /// Ranks weekdays by the bot's edge over Kalshi, then the four-hour blocks within each.
    /// Ties fall back to accuracy, then to more windows.
    static func tradingTimes(_ windows: [Window], calendar: Calendar) -> [DayRanking] {
        func better(_ a: Period, _ b: Period) -> Bool {
            if a.edge != b.edge { return a.edge > b.edge }
            if a.botAccuracy != b.botAccuracy { return a.botAccuracy > b.botAccuracy }
            return a.windows > b.windows
        }
        let byWeekday = Dictionary(grouping: windows) { calendar.component(.weekday, from: $0.openTime) }
        var dayName = Date.FormatStyle().weekday(.wide)
        dayName.timeZone = calendar.timeZone
        return byWeekday.map { weekday, list in
            let byBlock = Dictionary(grouping: list) { calendar.component(.hour, from: $0.openTime) / blockHours }
            let blocks = byBlock.map { block, blockWindows in
                period(blockWindows, id: "\(weekday)-\(block)", label: blockLabel(block))
            }
            return DayRanking(weekday: weekday,
                              period: period(list, id: "w\(weekday)", label: list[0].openTime.formatted(dayName)),
                              blocks: blocks.sorted(by: better))
        }
        .sorted { better($0.period, $1.period) }
    }

    /// e.g. "8 AM–12 PM"; "12–4 AM" when both ends share AM/PM.
    static func blockLabel(_ block: Int) -> String {
        let start = block * blockHours, end = (start + blockHours) % 24
        let startLabel = hourLabel(start), endLabel = hourLabel(end)
        if startLabel.suffix(2) == endLabel.suffix(2), end != 0 {
            return "\(startLabel.dropLast(3))–\(endLabel)"
        }
        return "\(startLabel)–\(endLabel)"
    }

    static func hourLabel(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h) \(hour < 12 ? "AM" : "PM")"
    }

    /// An edge in points, signed, e.g. "+0.12"; one that rounds to 0.00 shows unsigned.
    static func points(_ edge: Double) -> String {
        let shown = hundredthsOfPoints(edge)
        return shown == 0 ? magnitude(edge) : "\(shown > 0 ? "+" : "−")\(magnitude(edge))"
    }

    /// Size of an edge in points, without a sign.
    static func magnitude(_ edge: Double) -> String {
        (abs(hundredthsOfPoints(edge)) / 100).formatted(.number.precision(.fractionLength(2)))
    }

    /// An edge as displayed: rounded to hundredths of a point (e.g. 0.0012 → 12), so the
    /// sign and verdict are taken from the figure shown, never from what rounds away.
    static func hundredthsOfPoints(_ edge: Double) -> Double {
        let rounded = (edge * 10_000).rounded()
        return rounded == 0 ? 0 : rounded  // no −0
    }

    // MARK: Trends

    private static func trends(_ windows: [Window], days: [Period], byHour: [Int: [Window]],
                               calendar: Calendar) -> [Trend] {
        var trends: [Trend] = []
        let percent = FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0))

        // Recent form: the last six hours against everything before.
        if windows.count >= recentCount * 3 / 2 {
            let recent = period(Array(windows.suffix(recentCount)), id: "recent", label: "")
            let earlier = period(Array(windows.dropLast(recentCount)), id: "earlier", label: "")
            let change = recent.edge - earlier.edge
            let margin = (recent.edgeMargin * recent.edgeMargin + earlier.edgeMargin * earlier.edgeMargin).squareRoot()
            trends.append(Trend(
                kind: abs(change) < Period.evenBelow ? .neutral : (change > 0 ? .favorable : .unfavorable),
                title: "Last \(recentCount) windows: \(points(recent.edge)) vs. \(points(earlier.edge)) before",
                detail: "Brier edge over Kalshi per window, in points (positive = the bot was closer). The bot was right on \(recent.botCorrect) of \(recent.windows) recent calls; Kalshi's favorite on \(recent.marketCorrect). \(hundredthsOfPoints(change) == 0 ? "Unchanged" : "\(change > 0 ? "Improving" : "Slipping") by \(magnitude(change))") — \(abs(change) > margin ? "larger than" : "within") the ±\(magnitude(margin)) noise.",
                isConfirmed: abs(change) > margin))
        }

        // Hours of the day where the bot was ahead, and how consistently across days.
        let hourStats = byHour.compactMap { hour, list -> (hour: Int, period: Period, daysAhead: Int, days: Int)? in
            guard list.count >= 4 else { return nil }
            let perDay = Dictionary(grouping: list) { calendar.startOfDay(for: $0.openTime) }
                .values.map { period($0, id: "", label: "") }
            return (hour, period(list, id: "", label: ""), perDay.filter { $0.verdict == .ahead }.count, perDay.count)
        }
        let bestHours = hourStats.filter { $0.period.edge > Period.evenBelow }.sorted { $0.period.edge > $1.period.edge }.prefix(3)
        if !bestHours.isEmpty {
            let names = bestHours.map { "\(hourLabel($0.hour)) (\(points($0.period.edge)), ahead \($0.daysAhead) of \($0.days) days)" }
            trends.append(Trend(kind: .favorable,
                                title: "Strongest hours: \(bestHours.map { hourLabel($0.hour) }.joined(separator: ", ")) ET",
                                detail: "Where the bot beat Kalshi's price by the most: \(names.formatted(.list(type: .and))). An hour that's ahead on most days is a better sign than one big window.",
                                isConfirmed: bestHours.contains { $0.period.isSignificant }))
        }
        let worstHours = hourStats.filter { $0.period.edge < -Period.evenBelow }.sorted { $0.period.edge < $1.period.edge }.prefix(3)
        if !worstHours.isEmpty {
            trends.append(Trend(kind: .unfavorable,
                                title: "Weakest hours: \(worstHours.map { hourLabel($0.hour) }.joined(separator: ", ")) ET",
                                detail: "Where Kalshi's price was closer than the bot: \(worstHours.map { "\(hourLabel($0.hour)) (\(points($0.period.edge)))" }.formatted(.list(type: .and))).",
                                isConfirmed: worstHours.contains { $0.period.isSignificant }))
        }

        // Consecutive days ahead or behind.
        if let last = days.last, days.count >= 2, last.verdict != .even {
            let run = days.reversed().prefix { $0.verdict == last.verdict }.count
            if run >= 2 {
                trends.append(Trend(kind: last.verdict == .ahead ? .favorable : .unfavorable,
                                    title: "\(run) days in a row \(last.verdict == .ahead ? "ahead of" : "behind") Kalshi",
                                    detail: "Each of the last \(run) days ended with the bot \(last.verdict == .ahead ? "closer to the outcomes" : "further from the outcomes") than Kalshi's price.",
                                    isConfirmed: false))
            }
        }

        // Windows where the bot and Kalshi picked different sides.
        let disagreements = windows.filter { ($0.probabilityUp >= 0.5) != ($0.marketYesMid >= 0.5) }
        if !disagreements.isEmpty {
            let won = disagreements.filter(\.botCorrect).count
            trends.append(Trend(kind: won * 2 == disagreements.count ? .neutral : (won * 2 > disagreements.count ? .favorable : .unfavorable),
                                title: "Disagreed with Kalshi \(disagreements.count) time\(disagreements.count == 1 ? "" : "s"); right on \(won)",
                                detail: "The only windows where accuracy can differ. \(disagreements.count < 20 ? "Too few to judge yet — about 20 are needed before this means much." : "")",
                                isConfirmed: false))
        }

        // Calibration of the recent calls: confidence against hit rate.
        let recent = windows.suffix(recentCount)
        if recent.count >= 12 {
            let expected = recent.map { max($0.probabilityUp, 1 - $0.probabilityUp) }.reduce(0, +) / Double(recent.count)
            let actual = Double(recent.filter(\.botCorrect).count) / Double(recent.count)
            let margin = 1.96 * (expected * (1 - expected) / Double(recent.count)).squareRoot()
            let gap = actual - expected
            trends.append(Trend(kind: abs(gap) < 0.03 ? .neutral : (gap > 0 ? .favorable : .unfavorable),
                                title: "Recent calls \(abs(gap) < 0.03 ? "well calibrated" : (gap > 0 ? "beat their confidence" : "fell short of their confidence"))",
                                detail: "Over the last \(recent.count) windows the calls averaged \(expected.formatted(percent)) confidence and were right \(actual.formatted(percent)) of the time (±\(margin.formatted(percent)) is normal luck).",
                                isConfirmed: abs(gap) > margin))
        }

        // Kalshi's strong favorites: the 60-day history found them slightly underpriced.
        let favorites = windows.filter { max($0.marketYesMid, 1 - $0.marketYesMid) >= 0.7 }
        if favorites.count >= 8 {
            let priced = favorites.map { max($0.marketYesMid, 1 - $0.marketYesMid) }.reduce(0, +) / Double(favorites.count)
            let won = Double(favorites.filter(\.marketCorrect).count) / Double(favorites.count)
            let margin = 1.96 * (priced * (1 - priced) / Double(favorites.count)).squareRoot()
            trends.append(Trend(kind: .neutral,
                                title: "Kalshi's strong favorites won \(won.formatted(percent)), priced at \(priced.formatted(percent))",
                                detail: "\(favorites.count) windows where Kalshi priced a side at 70% or more. \(won > priced ? "Favorites were underpriced" : "Favorites were overpriced") by \(Int((abs(won - priced) * 100).rounded())) points — \(abs(won - priced) > margin ? "more than" : "within") the ±\(Int((margin * 100).rounded())) noise. The 60-day history showed favorites underpriced by 3–4 points, mostly eaten by fees and the spread.",
                                isConfirmed: abs(won - priced) > margin))
        }
        return trends
    }
}

extension PerformanceBreakdown {
    init(records: [PredictionRecord]) {
        self.init(records.compactMap { r in
            guard let actualUp = r.actualUp, let mid = r.marketYesMid else { return nil }
            return Window(openTime: r.openTime, probabilityUp: r.probabilityUp, marketYesMid: mid, actualUp: actualUp)
        })
    }
}
