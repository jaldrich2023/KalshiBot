//
//  PredictionLogView.swift
//  KalshiBot
//

import SwiftUI
import SwiftData
import AppKit

struct PredictionLogView: View {
    @Environment(BotEngine.self) private var engine
    let records: [PredictionRecord]

    /// The row under the pointer, and the one whose breakdown is showing (after a short dwell).
    @State private var hoveredID: PersistentIdentifier?
    @State private var breakdownID: PersistentIdentifier?
    @State private var dwellTask: Task<Void, Never>?
    @State private var clearTask: Task<Void, Never>?
    /// Where the breakdown opens: the cell under the pointer, the pointer's spot in it,
    /// and which side to open on (away from the nearer screen edge).
    @State private var breakdownColumn: Int?
    @State private var breakdownPoint: CGPoint = .zero
    @State private var breakdownEdge: Edge = .trailing
    /// Latest pointer position, kept out of SwiftUI state so mouse moves don't redraw the table.
    @State private var pointer = PointerTracker()

    var body: some View {
        Table(records) {
            TableColumn("Window") { r in
                cell(r, column: 0) { Text(r.openTime.formatted(date: .abbreviated, time: .shortened)) }
            }
            .width(min: 150, ideal: 170)
            TableColumn("Target") { r in
                cell(r, column: 1) {
                    Text(BotEngine.usd(r.strike)).monospacedDigit()
                }
            }
            .width(min: 90, ideal: 100)
            TableColumn("Spot at call") { r in
                cell(r, column: 2) {
                    Text(BotEngine.usd(r.spotAtPrediction)).monospacedDigit()
                }
            }
            .width(min: 90, ideal: 100)
            TableColumn("P(up)") { r in
                cell(r, column: 3) {
                    Text(BotEngine.percent(r.probabilityUp)).monospacedDigit()
                }
            }
            .width(min: 50, ideal: 60)
            TableColumn("Call") { r in
                cell(r, column: 4) {
                    Label(r.predictedUp ? "Up" : "Down", systemImage: r.predictedUp ? "arrow.up" : "arrow.down")
                        .foregroundStyle(r.predictedUp ? .green : .red)
                }
            }
            .width(min: 60, ideal: 70)
            TableColumn("Confidence") { r in
                cell(r, column: 5) {
                    // Probability of the side called, 50–100%.
                    Text(BotEngine.percent(r.confidence)).monospacedDigit()
                        .foregroundStyle(r.confidence >= AccuracyStats.confidentThreshold ? .primary : .secondary)
                }
            }
            .width(min: 70, ideal: 80)
            TableColumn("Kalshi Yes") { r in
                cell(r, column: 6) {
                    // Mid, plus the bid/ask actually on offer when the call was made.
                    HStack(spacing: 4) {
                        Text(r.marketYesMid.map(BotEngine.percent) ?? "—")
                        if let bid = r.marketYesBid, let ask = r.marketYesAsk {
                            Text("\(StrategyAdvisor.cents(bid))/\(StrategyAdvisor.cents(ask))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .monospacedDigit()
                }
            }
            .width(min: 110, ideal: 130)
            TableColumn("Settled at") { r in
                cell(r, column: 7) {
                    Text(r.settlementValue.map(BotEngine.usd) ?? "—").monospacedDigit()
                }
            }
            .width(min: 90, ideal: 100)
            TableColumn("Outcome") { r in
                cell(r, column: 8) {
                    if let up = r.actualUp {
                        // Same style as the Call column: green up arrow, red down arrow.
                        Label(up ? "Up" : "Down", systemImage: up ? "arrow.up" : "arrow.down")
                            .foregroundStyle(up ? .green : .red)
                    } else {
                        Text(r.closeTime > .now ? "Live" : "Pending").foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 60, ideal: 70)
            TableColumn("Result") { r in
                cell(r, column: 9) {
                    switch r.isCorrect {
                    case _ where engine.isNoCall(r):
                        Label("No call", systemImage: "minus.circle").foregroundStyle(.secondary)
                            .help("Below the \(BotEngine.percent(engine.minimumCallConfidence)) confidence threshold, so not counted")
                    case true?: Label("Correct", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case false?: Label("Wrong", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    case nil: Text("—").foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 90, ideal: 100)
        }
        .scrollContentBackground(.hidden)
        .padding(6)
        .glassCard()
        .padding(20)
        .overlay {
            if records.isEmpty {
                ContentUnavailableView("No predictions yet", systemImage: "clock",
                                       description: Text("The bot makes its first call when the next 15-minute window opens."))
            }
        }
    }

    /// One cell: fills its column so the whole row highlights and responds to hover.
    private func cell<Content: View>(_ r: PredictionRecord, column: Int, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .contentShape(.rect)
            .background {
                if hoveredID == r.persistentModelID {
                    Rectangle().fill(Color.accentColor.opacity(0.18)).padding(.horizontal, -6)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    pointer.column = column
                    pointer.point = location
                    hover(r.persistentModelID, inside: true)
                case .ended:
                    hover(r.persistentModelID, inside: false)
                }
            }
            .popover(isPresented: breakdownBinding(for: r, column: column),
                     attachmentAnchor: .rect(.rect(CGRect(origin: breakdownPoint, size: .zero))),
                     arrowEdge: breakdownEdge) {
                CallBreakdownView(explanation: CallExplanation(record: r))
            }
    }

    /// Highlights at once; shows the breakdown after the pointer rests 0.4s on a row.
    /// Leaving a cell clears only after a beat, so moving across one row's cells
    /// keeps the highlight and the breakdown.
    private func hover(_ id: PersistentIdentifier, inside: Bool) {
        if inside {
            clearTask?.cancel()
            guard hoveredID != id else { return }
            hoveredID = id
            breakdownID = nil
            dwellTask?.cancel()
            dwellTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, hoveredID == id else { return }
                // Open at the pointer, on the side away from the nearer screen edge.
                breakdownColumn = pointer.column
                breakdownPoint = pointer.point
                breakdownEdge = Self.openingEdge(forScreenPoint: NSEvent.mouseLocation)
                breakdownID = id
            }
        } else {
            clearTask?.cancel()
            clearTask = Task {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, hoveredID == id else { return }
                dwellTask?.cancel()
                hoveredID = nil
                breakdownID = nil
            }
        }
    }

    private func breakdownBinding(for r: PredictionRecord, column: Int) -> Binding<Bool> {
        Binding(get: { breakdownID == r.persistentModelID && breakdownColumn == column },
                set: { if !$0, breakdownID == r.persistentModelID { breakdownID = nil } })
    }

    /// `arrowEdge` is the anchor edge the arrow sits on, so `.trailing` opens the
    /// popover to the right of the pointer. Left half of the screen → open right;
    /// right half → open left.
    static func openingEdge(forScreenPoint point: CGPoint) -> Edge {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let frame = screen?.frame else { return .trailing }
        return point.x < frame.midX ? .trailing : .leading
    }

    static func csv(for records: [PredictionRecord]) -> String {
        let iso = ISO8601DateFormatter()
        let featureKeys = FeatureKey.allCases
        var lines = [
            (["ticker", "open_time", "close_time", "predicted_at", "strike", "spot_at_prediction",
              "proxy_open_avg", "p_up", "predicted", "kalshi_yes_mid", "kalshi_yes_bid", "kalshi_yes_ask", "settlement_value", "actual", "correct"]
             + featureKeys.map { "f_\($0.rawValue)" }).joined(separator: ",")
        ]
        for r in records.sorted(by: { $0.openTime < $1.openTime }) {
            let features = r.features
            var fields = [
                r.ticker, iso.string(from: r.openTime), iso.string(from: r.closeTime), iso.string(from: r.predictedAt),
                String(r.strike), String(r.spotAtPrediction), r.proxyOpenAverage.map { String($0) } ?? "",
                String(format: "%.4f", r.probabilityUp), r.predictedUp ? "up" : "down",
                r.marketYesMid.map { String($0) } ?? "", r.marketYesBid.map { String($0) } ?? "",
                r.marketYesAsk.map { String($0) } ?? "", r.settlementValue.map { String($0) } ?? "",
                r.actualUp.map { $0 ? "up" : "down" } ?? "", r.isCorrect.map { $0 ? "1" : "0" } ?? "",
            ]
            fields += featureKeys.map { key in features[key].map { String(format: "%.4f", $0) } ?? "" }
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}

struct ActivityView: View {
    @Environment(BotEngine.self) private var engine

    var body: some View {
        List(engine.activity) { entry in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(entry.time.formatted(date: .omitted, time: .standard))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Text(entry.message)
                    .font(.callout)
            }
            .listRowBackground(Color.clear)
        }
        .scrollContentBackground(.hidden)
        .padding(6)
        .glassCard()
        .padding(20)
    }
}

/// Latest pointer position over the log, read when the breakdown opens.
private final class PointerTracker {
    var column = 0
    var point: CGPoint = .zero
}

/// Hover breakdown of one call: the verdict, then each reason with whether it helped.
struct CallBreakdownView: View {
    let explanation: CallExplanation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(explanation.headline, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ForEach(explanation.points) { point in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: point.helped == true ? "checkmark.circle.fill"
                          : point.helped == false ? "xmark.circle.fill" : "info.circle")
                        .foregroundStyle(point.helped == true ? .green : point.helped == false ? .red : .secondary)
                        .accessibilityLabel(point.helped == true ? "Helped the call" : point.helped == false ? "Worked against the call" : "Context")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(point.title).font(.callout.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(point.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        // Shown from inside a table cell, which limits text to one line: lift that, and
        // size the card to its full content height so nothing is clipped.
        .lineLimit(nil)
        .padding(16)
        .frame(width: 460, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var symbol: String {
        switch explanation.outcome {
        case .correct: "checkmark.seal.fill"
        case .wrong: "xmark.seal.fill"
        case .pending: "clock"
        }
    }

    private var color: Color {
        switch explanation.outcome {
        case .correct: .green
        case .wrong: .red
        case .pending: .secondary
        }
    }
}
