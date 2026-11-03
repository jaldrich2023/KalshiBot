//
//  WindowChartSupport.swift
//  KalshiBot
//
//  Pieces shared by every chart of the current 15-minute window, so they all
//  have the same axes, reference lines, and hover behavior.
//

import SwiftUI
import Charts

/// Settlement-minute shading and the target line.
struct WindowReferenceMarks: ChartContent {
    let market: KalshiMarket
    var showSettlement = true
    var showTarget = true

    var body: some ChartContent {
        // The final 60s whose BRTI average settles the market.
        // Labelled by `ChartTag`s along the chart edges, which never overlap.
        if showSettlement {
            RectangleMark(xStart: .value("Start", market.closeTime.addingTimeInterval(-60)), xEnd: .value("End", market.closeTime))
                .foregroundStyle(Color.white.opacity(0.05))
        }

        if showTarget, let strike = market.floorStrike {
            RuleMark(y: .value("Target", strike))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Color.white.opacity(0.45))
        }
    }
}

/// Everything that can be drawn on a window chart, each switchable on or off.
enum ChartLayer: String, CaseIterable, Identifiable {
    case line, now, candles, movement, close, target, settlement, highLow, closeRange, trend, projection, exits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .line: "60s average"
        case .now: "Now"
        case .candles: "Candles"
        case .movement: "Movement"
        case .close: "Close"
        case .target: "Target"
        case .settlement: "Settlement minute"
        case .highLow: "High/Low"
        case .closeRange: "Close range"
        case .trend: "Trend"
        case .projection: "Projection"
        case .exits: "Stop & take profit"
        }
    }

    /// What the layer draws, for the Layers menu's tip.
    var detail: String {
        switch self {
        case .line: "the trailing 60-second average of the index estimate — what the settlement value would be if the window closed then"
        case .now: "the latest price, with its label on the right edge"
        case .candles: "one candle per minute: green closed higher than it opened, red lower, with the wick from low to high"
        case .movement: "a line joining each minute's close"
        case .close: "the latest minute's close, labelled on the right edge"
        case .target: "Kalshi's target; at or above it at the close settles Up"
        case .settlement: "the shaded final minute, whose 60-second average decides the result"
        case .highLow: "the window's highest and lowest price so far, with the chance of breaking each"
        case .closeRange: "the ±1σ range for the closing value, narrowing as time runs out"
        case .trend: "a straight-line fit through the window's prices — descriptive, not a forecast"
        case .projection: "the expected path of the 60-second average to the close if the price holds"
        case .exits: "the stop-loss and take-profit prices for the called side, from the Strategy card"
        }
    }

    static let priceChart: [ChartLayer] = [.line, .now, .target, .settlement, .highLow, .closeRange, .trend, .projection, .exits]
    static let candleChart: [ChartLayer] = [.candles, .movement, .close, .target, .settlement, .highLow, .trend]

    /// The layer an edge tag belongs to, so hiding a layer hides its label too.
    static func forTag(_ id: String) -> ChartLayer? {
        switch id {
        case "target": .target
        case "settlement": .settlement
        case "high", "low": .highLow
        case "price": .now
        case "projected": .projection
        case "trend": .trend
        case "takeProfit", "stop": .exits
        case "close": .close
        default: nil
        }
    }

    /// Hidden layers are stored as a comma-separated list of raw values.
    static func isShown(_ layer: ChartLayer, hidden: String) -> Bool {
        !hidden.split(separator: ",").contains(Substring(layer.rawValue))
    }
}

/// A "Layers" menu of on/off switches, one per chart layer. It floats in the card's
/// header corner, so it takes no space from the chart.
struct ChartLayerToggles: View {
    let layers: [ChartLayer]
    @Binding var hidden: String

    var body: some View {
        Menu {
            ForEach(layers) { layer in
                Toggle(layer.title, isOn: binding(for: layer))
            }
            Divider()
            Button("Show all") { hidden = "" }
        } label: {
            Label(hiddenCount == 0 ? "Layers" : "Layers (\(hiddenCount) hidden)", systemImage: "square.3.layers.3d")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .infoTip("Layers", "Show or hide each line and marker on this chart; your choice is remembered. " + layers.map { "\($0.title): \($0.detail)." }.joined(separator: " ") + " Rest the pointer on the chart to read the price at any moment.")
    }

    private var hiddenCount: Int { layers.count { !ChartLayer.isShown($0, hidden: hidden) } }

    private func binding(for layer: ChartLayer) -> Binding<Bool> {
        Binding(get: { ChartLayer.isShown(layer, hidden: hidden) },
                set: { show in
                    var set = Set(hidden.split(separator: ",").map(String.init))
                    if show { set.remove(layer.rawValue) } else { set.insert(layer.rawValue) }
                    hidden = set.sorted().joined(separator: ",")
                })
    }
}

/// The window's high and low so far: a dotted line across the window at each and a
/// marker where it was set. Their labels are `ChartTag`s on the left edge.
struct WindowExtremeMarks: ChartContent {
    let extremes: WindowChart.Extremes
    let market: KalshiMarket
    /// The lines run from the open to here (now): these are prices already reached, not forecasts.
    var until: Date = .now

    var body: some ChartContent {
        mark(extremes.high, title: "High", color: .green)
        mark(extremes.low, title: "Low", color: .red)
    }

    @ChartContentBuilder
    private func mark(_ point: (time: Date, price: Double), title: String, color: Color) -> some ChartContent {
        RuleMark(xStart: .value("Start", market.openTime), xEnd: .value("End", min(max(until, point.time), market.closeTime)),
                 y: .value("Window \(title.lowercased())", point.price))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 3]))
            .foregroundStyle(color.opacity(0.6))
            .accessibilityLabel("Window \(title.lowercased())")
            .accessibilityValue(BotEngine.usd(point.price))
        PointMark(x: .value("Time", point.time), y: .value("Window \(title.lowercased())", point.price))
            .symbol(.circle)
            .symbolSize(28)
            .foregroundStyle(color)
    }
}

/// A value tag on a window chart at a price level: against the left or right edge, or
/// centered across the chart just above or below its line. Tags in the same column are
/// spaced so they never overlap (see `ChartTag.layout`).
nonisolated struct ChartTag: Identifiable {
    enum Side { case leading, center, trailing }

    let id: String
    let text: String
    let color: Color
    /// The price the tag points at; nil pins it into a stack at the top of its column.
    let value: Double?
    let side: Side
    /// Where the tag sits relative to its price: centered on it, or just above/below its line.
    enum Placement { case on, above, below }
    var placement: Placement = .on
    /// Order within the pinned stack at the top (0 = topmost); used when `value` is nil.
    var rank = 0

    /// Pixel heights reserved per tag.
    static let height: CGFloat = 18

    /// Spreads desired y positions (pixels, top = 0) so neighbors are at least `gap`
    /// apart and all stay within 0…`height`, moving each as little as possible.
    static func layout(_ desired: [CGFloat], gap: CGFloat, height: CGFloat) -> [CGFloat] {
        let order = desired.indices.sorted { desired[$0] < desired[$1] }
        var ys = order.map { min(max(desired[$0], gap / 2), height - gap / 2) }
        for i in ys.indices.dropFirst() where ys[i] - ys[i - 1] < gap { ys[i] = ys[i - 1] + gap }
        // Overflowed the bottom: push the stack back up from the bottom edge.
        if let last = ys.last, last > height - gap / 2 {
            ys[ys.count - 1] = height - gap / 2
            for i in ys.indices.dropLast().reversed() where ys[i + 1] - ys[i] < gap { ys[i] = ys[i + 1] - gap }
        }
        var result = desired
        for (k, index) in order.enumerated() { result[index] = ys[k] }
        return result
    }
}

/// Draws `ChartTag`s in their columns, spaced so none overlap and clear of the "Now" dot.
struct ChartTagLayer: View {
    let tags: [ChartTag]
    let proxy: ChartProxy
    let plot: CGRect
    /// The point labels must keep clear of (the latest price), in data coordinates.
    var focus: (time: Date, price: Double)?

    var body: some View {
        let anchors = Dictionary(uniqueKeysWithValues: tags.compactMap { tag in
            tag.value.flatMap { proxy.position(forY: $0) }.map { (tag.id, $0) }
        })
        let dot = focus.flatMap { f in
            proxy.position(forX: f.time).flatMap { x in proxy.position(forY: f.price).map { CGPoint(x: x, y: $0) } }
        }
        let placed = ChartTagPlacement.place(tags, anchors: anchors, focus: dot, size: plot.size)
        ForEach(tags) { tag in
            if let center = placed[tag.id] {
                ReferenceTagView(text: tag.text, color: tag.color)
                    .fixedSize()
                    .position(x: plot.minX + center.x, y: plot.minY + center.y)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Where each tag goes, in plot coordinates (origin top-left): off its line by a few
/// points so the line stays visible, out of the way of the "Now" dot, and never
/// overlapping another tag in its column.
nonisolated enum ChartTagPlacement {
    /// Space between a tag and the line it labels.
    static let lineClearance: CGFloat = 3
    /// Space kept around the "Now" dot.
    static let focusClearance: CGFloat = 10

    /// Approximate rendered width of a tag (caption2, semibold, padded capsule).
    static func width(of text: String) -> CGFloat { CGFloat(text.count) * 6.5 + 14 }

    static func place(_ tags: [ChartTag], anchors: [String: CGFloat], focus: CGPoint?, size: CGSize) -> [String: CGPoint] {
        let h = ChartTag.height
        let offset = h / 2 + lineClearance
        // When the price sits in the top-right, the pinned stack moves to the bottom-right.
        let pinBottom = focus.map { $0.y < size.height * 0.4 && $0.x > size.width * 0.5 } ?? false
        let maxRank = tags.filter { $0.value == nil }.map(\.rank).max() ?? 0

        func overlapsFocus(x: CGFloat, y: CGFloat, w: CGFloat) -> Bool {
            guard let f = focus else { return false }
            return abs(f.x - x) < w / 2 + focusClearance && abs(f.y - y) < h / 2 + focusClearance
        }

        var xs: [String: CGFloat] = [:]
        var desired: [String: CGFloat] = [:]
        for tag in tags {
            let w = width(of: tag.text)
            var x: CGFloat
            switch tag.side {
            case .leading: x = 4 + w / 2
            case .center: x = size.width / 2
            case .trailing: x = size.width - 4 - w / 2
            }
            var y: CGFloat
            if let anchor = anchors[tag.id] {
                func at(_ placement: ChartTag.Placement) -> CGFloat {
                    switch placement {
                    case .on: anchor
                    case .above: anchor - offset
                    case .below: anchor + offset
                    }
                }
                y = at(tag.placement)
                if overlapsFocus(x: x, y: y, w: w) {
                    if tag.side == .center, let f = focus {
                        // Slide sideways, away from the dot.
                        x = f.x >= size.width / 2 ? f.x - w / 2 - focusClearance - 6 : f.x + w / 2 + focusClearance + 6
                        x = min(max(x, w / 2 + 4), size.width - w / 2 - 4)
                    }
                    if overlapsFocus(x: x, y: y, w: w) {
                        // Still in the way: put it on the other side of its line.
                        y = at(tag.placement == .below ? .above : .below)
                    }
                }
            } else {
                y = pinBottom
                    ? size.height - CGFloat(maxRank - tag.rank) * (h + 2) - h / 2
                    : CGFloat(tag.rank) * (h + 2) + h / 2
            }
            xs[tag.id] = x
            desired[tag.id] = y
        }

        var result: [String: CGPoint] = [:]
        for side in [ChartTag.Side.leading, .center, .trailing] {
            let column = tags.filter { $0.side == side }
            let ys = ChartTag.layout(column.map { desired[$0.id] ?? 0 }, gap: h + 2, height: size.height)
            for (tag, y) in zip(column, ys) { result[tag.id] = CGPoint(x: xs[tag.id] ?? 0, y: y) }
        }
        return result
    }
}

/// A tag: tinted text on a dark capsule so it reads over lines and glass.
struct ReferenceTagView: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.6), in: .capsule)
            .overlay { Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.5) }
    }
}

enum WindowChart {
    /// Highest and lowest price since the window opened, and when each was set.
    struct Extremes {
        let high: (time: Date, price: Double)
        let low: (time: Date, price: Double)
    }

    /// Target on the left edge, window high centered above its line and low centered
    /// below its line, and the settlement minute on the right.
    static func referenceTags(market: KalshiMarket, extremes: Extremes?,
                              breakouts: (up: Double?, down: Double?), price: Double? = nil) -> [ChartTag] {
        var tags: [ChartTag] = [ChartTag(id: "settlement", text: "Settlement avg", color: .secondary, value: nil, side: .trailing)]
        if let strike = market.floorStrike {
            tags.append(ChartTag(id: "target", text: "Target \(BotEngine.usd(strike))\(market.strikeIsEstimate ? " (est.)" : "")",
                                 color: .white, value: strike, side: .leading,
                                 // Off the line, on the side away from the price.
                                 placement: (price ?? strike) >= strike ? .below : .above))
        }
        if let extremes {
            let time = Date.FormatStyle(date: .omitted, time: .standard)
            tags.append(ChartTag(id: "high", text: "▲ High \(BotEngine.usd(extremes.high.price)) hit \(extremes.high.time.formatted(time))\(breakouts.up.map { " · \(BotEngine.percent($0)) chance of a new high" } ?? "")",
                                 color: .green, value: extremes.high.price, side: .center, placement: .above))
            tags.append(ChartTag(id: "low", text: "▼ Low \(BotEngine.usd(extremes.low.price)) hit \(extremes.low.time.formatted(time))\(breakouts.down.map { " · \(BotEngine.percent($0)) chance of a new low" } ?? "")",
                                 color: .red, value: extremes.low.price, side: .center, placement: .below))
        }
        return tags
    }

    /// Breakout chances for the window's high and low from the current price.
    static func breakouts(_ extremes: Extremes?, price: Double?, volatility: Double?, market: KalshiMarket,
                          calibration: RiskCalibration? = nil) -> (up: Double?, down: Double?) {
        guard let extremes, let price, let volatility else { return (nil, nil) }
        let remaining = market.closeTime.timeIntervalSinceNow
        return (ReversalRisk.breakoutProbability(distance: extremes.high.price - price, volatility: volatility,
                                                 secondsRemaining: remaining, calibration: calibration),
                ReversalRisk.breakoutProbability(distance: price - extremes.low.price, volatility: volatility,
                                                 secondsRemaining: remaining, calibration: calibration))
    }

    /// The highest and lowest prices actually reached inside the window (from
    /// `BotEngine.windowPrices`); nil until there's one.
    static func extremes(_ samples: [(time: Date, price: Double)], from open: Date, to close: Date) -> Extremes? {
        let inWindow = samples.filter { $0.time >= open && $0.time < close && $0.price.isFinite }
        guard let high = inWindow.max(by: { $0.price < $1.price }),
              let low = inWindow.min(by: { $0.price < $1.price }) else { return nil }
        return Extremes(high: high, low: low)
    }

    /// Y range covering the data and the target, with breathing room.
    static func yDomain(_ values: [Double], market: KalshiMarket) -> ClosedRange<Double> {
        // Non-finite values would make an invalid range (and crash Swift Charts).
        var values = values.filter(\.isFinite)
        if let strike = market.floorStrike, strike.isFinite { values.append(strike) }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let padding = max((high - low) * 0.15, 5)
        return (low - padding)...(high + padding)
    }

    static func tooltip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2, content: content)
            .monospacedDigit()
            .padding(6)
            .background(.regularMaterial, in: .rect(cornerRadius: 6))
    }

    static func differenceFromTarget(_ price: Double, market: KalshiMarket) -> String? {
        guard let strike = market.floorStrike else { return nil }
        let diff = price - strike
        return "\(diff >= 0 ? "+" : "")\(BotEngine.usd(diff)) vs. target"
    }
}

extension View {
    /// Fixed open→close time axis labelled every minute, dollar y-axis, and hover tracking.
    func windowChartAxes(market: KalshiMarket, yDomain: ClosedRange<Double>, hoveredDate: Binding<Date?>,
                         tags: [ChartTag] = [], focus: (time: Date, price: Double)? = nil) -> some View {
        self
            // End padding keeps the final (close) minute label from being clipped.
            .chartXScale(domain: market.openTime...market.closeTime, range: .plotDimension(endPadding: 28))
            .chartYScale(domain: yDomain)
            .chartXAxis {
                // One mark per minute, anchored to the window open.
                AxisMarks(values: (0...15).map { market.openTime.addingTimeInterval(Double($0) * 60) }) {
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisTick()
                    AxisValueLabel(format: .dateTime.hour().minute(), collisionResolution: .disabled)
                        .font(.caption2)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) {
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel(format: .currency(code: "USD").precision(.fractionLength(0)))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(.clear)
                            .contentShape(.rect)
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    let plotX = location.x - (proxy.plotFrame.map { geometry[$0].minX } ?? 0)
                                    hoveredDate.wrappedValue = proxy.value(atX: plotX, as: Date.self)
                                case .ended:
                                    hoveredDate.wrappedValue = nil
                                }
                            }
                        if let frame = proxy.plotFrame {
                            ChartTagLayer(tags: tags, proxy: proxy, plot: geometry[frame], focus: focus)
                        }
                    }
                }
            }
            // Grows to the row's height (set by the card beside it), never below 240.
            .frame(minHeight: 240, maxHeight: .infinity)
    }
}
