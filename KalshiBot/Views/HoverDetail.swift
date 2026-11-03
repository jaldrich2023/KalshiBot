//
//  HoverDetail.swift
//  KalshiBot
//
//  Hover-for-detail popovers, as in the prediction log: resting the pointer on an item
//  for a moment opens a popover at the pointer, on the side away from the nearer
//  screen edge. Works for table cells and for individual marks in a chart.
//

import SwiftUI
import AppKit
import Charts

/// Which item is hovered, which one's popover is open, and where. Shared by every cell
/// (or chart) in one group, so moving across a row's cells keeps one steady popover.
@Observable
final class HoverDetailState {
    private(set) var hoveredID: String?
    private(set) var shownID: String?
    private(set) var shownColumn = 0
    private(set) var point: CGPoint = .zero
    private(set) var edge: Edge = .trailing

    @ObservationIgnored private var lastColumn = 0
    @ObservationIgnored private var lastPoint: CGPoint = .zero
    @ObservationIgnored private var dwellTask: Task<Void, Never>?
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    /// The pointer is over `id` (in cell `column`, at `location` in that cell).
    func enter(_ id: String, column: Int = 0, at location: CGPoint) {
        lastColumn = column
        lastPoint = location
        clearTask?.cancel()
        guard hoveredID != id else { return }
        hoveredID = id
        shownID = nil
        dwellTask?.cancel()
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, self.hoveredID == id else { return }
            self.shownColumn = self.lastColumn
            self.point = self.lastPoint
            self.edge = PredictionLogView.openingEdge(forScreenPoint: NSEvent.mouseLocation)
            self.shownID = id
        }
    }

    /// The pointer left `id`; clears after a beat so crossing between cells doesn't flicker.
    func leave(_ id: String) {
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled, self.hoveredID == id else { return }
            self.dwellTask?.cancel()
            self.hoveredID = nil
            self.shownID = nil
        }
    }

    func dismiss() { shownID = nil }

    func isShown(_ id: String, column: Int = 0) -> Binding<Bool> {
        Binding(get: { self.shownID == id && self.shownColumn == column },
                set: { if !$0, self.shownID == id { self.shownID = nil } })
    }
}

extension View {
    /// Shows `popup` at the pointer after a short rest on this view; highlights while hovered.
    func hoverDetail<Popup: View>(_ state: HoverDetailState, id: String, column: Int = 0, highlight: Bool = true,
                                  bleed: CGFloat = 6, @ViewBuilder popup: @escaping () -> Popup) -> some View {
        self
            .contentShape(.rect)
            .background {
                if highlight && state.hoveredID == id {
                    Rectangle().fill(Color.accentColor.opacity(0.16)).padding(.horizontal, -bleed)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): state.enter(id, column: column, at: location)
                case .ended: state.leave(id)
                }
            }
            .popover(isPresented: state.isShown(id, column: column),
                     attachmentAnchor: .rect(.rect(CGRect(origin: state.point, size: .zero))),
                     arrowEdge: state.edge) {
                popup()
            }
    }
}

/// A transparent layer over a chart's plot that finds the mark under the pointer and
/// shows its detail popover. Place inside `.chartOverlay`.
struct ChartHoverDetail<Popup: View>: View {
    let proxy: ChartProxy
    let state: HoverDetailState
    /// The hovered item's id for a point in plot coordinates, or nil over empty space.
    let resolve: (CGPoint) -> String?
    @ViewBuilder let popup: (String) -> Popup

    var body: some View {
        GeometryReader { geometry in
            let origin = proxy.plotFrame.map { geometry[$0].origin } ?? .zero
            Rectangle()
                .fill(.clear)
                .contentShape(.rect)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let plotPoint = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
                        if let id = resolve(plotPoint) {
                            state.enter(id, at: location)
                        } else if let current = state.hoveredID {
                            state.leave(current)
                        }
                    case .ended:
                        if let current = state.hoveredID { state.leave(current) }
                    }
                }
                .popover(isPresented: Binding(get: { state.shownID != nil },
                                              set: { if !$0 { state.dismiss() } }),
                         attachmentAnchor: .rect(.rect(CGRect(origin: state.point, size: .zero))),
                         arrowEdge: state.edge) {
                    if let id = state.shownID { popup(id) }
                }
        }
    }
}

/// Detail for one period of the performance breakdown.
struct PeriodDetailView: View {
    let title: String
    let period: PerformanceBreakdown.Period

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                row("Windows", "\(period.windows)\(period.windows < PerformanceBreakdown.reliableWindows ? " (few — rank can change quickly)" : "")")
                row("Bot right", "\(period.botCorrect) of \(period.windows) · \(BotEngine.percent(period.botAccuracy))")
                row("Kalshi's favorite right", "\(period.marketCorrect) of \(period.windows) · \(BotEngine.percent(period.marketAccuracy))")
                row("Brier edge / window",
                    "\(PerformanceBreakdown.points(period.edge)) pts ± \(period.edgeMargin.isFinite ? PerformanceBreakdown.magnitude(period.edgeMargin) : "—")")
                row("Verdict", period.isSignificant ? "\(verdict) — beyond the noise" : "\(verdict) — within the noise")
                row("Settled Up", "\(period.settledUp) of \(period.windows) · \(BotEngine.percent(period.windows > 0 ? Double(period.settledUp) / Double(period.windows) : 0))")
                row("Average confidence", BotEngine.percent(period.meanConfidence))
                row("Bot and Kalshi disagreed", "\(period.disagreements) window\(period.disagreements == 1 ? "" : "s")")
            }
            .monospacedDigit()
            Text("Brier edge: Kalshi's squared error minus the bot's, per window — positive means the bot's probability was closer to the outcome.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .lineLimit(nil)
        .padding(16)
        .frame(width: 420, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var verdict: String {
        switch period.verdict {
        case .ahead: "Beat Kalshi"
        case .behind: "Trailed Kalshi"
        case .even: "Even with Kalshi"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }
}
