//
//  InfoTip.swift
//  KalshiBot
//
//  Popover tooltips: resting the pointer on a field for a moment opens a popover with
//  its name and a fuller explanation, on the side away from the nearer screen edge.
//  Only one is open at a time, and any click or key press closes it, so it never gets
//  in the way of the control underneath.
//

import SwiftUI
import AppKit

/// Which tip is open. Shared by every tip, so opening one closes the last.
@Observable
final class InfoTipCenter {
    static let shared = InfoTipCenter()

    private(set) var shownID: UUID?
    private(set) var edge: Edge = .trailing

    @ObservationIgnored private var hoveredID: UUID?
    @ObservationIgnored private var dwellTask: Task<Void, Never>?
    @ObservationIgnored private var monitor: Any?

    private init() {}

    /// The pointer is over tip `id`; it opens after a short rest.
    func enter(_ id: UUID) {
        guard hoveredID != id else { return }
        // Moving onto another tip (a neighbour, or one nested inside) closes the open one.
        if let shownID, shownID != id { self.shownID = nil }
        hoveredID = id
        dwellTask?.cancel()
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, self.hoveredID == id else { return }
            self.edge = PredictionLogView.openingEdge(forScreenPoint: NSEvent.mouseLocation)
            self.shownID = id
            self.installMonitor()
        }
    }

    /// The pointer left tip `id`.
    func leave(_ id: UUID) {
        // Close this tip's popover even if the pointer has since entered another tip
        // (nested tips leave in either order), so none is left stuck open.
        if shownID == id { shownID = nil }
        guard hoveredID == id else { return }
        hoveredID = nil
        dwellTask?.cancel()
    }

    func dismiss(_ id: UUID) {
        if shownID == id { shownID = nil }
    }

    /// Closes the open tip on any click or key press; the event still goes through.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            if let self {
                self.shownID = nil
                self.hoveredID = nil
                self.dwellTask?.cancel()
            }
            return event
        }
    }
}

private struct InfoTipModifier: ViewModifier {
    let title: String
    let detail: String
    @State private var id = UUID()
    private var center: InfoTipCenter { .shared }

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .onHover { hovering in
                if hovering { center.enter(id) } else { center.leave(id) }
            }
            .popover(isPresented: Binding(get: { center.shownID == id },
                                          set: { if !$0 { center.dismiss(id) } }),
                     arrowEdge: center.edge) {
                InfoTipView(title: title, detail: detail)
            }
            .accessibilityHint(detail)
    }
}

/// The popover's content: the field's name, then the explanation.
struct InfoTipView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .lineLimit(nil)
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// A popover tooltip: rest the pointer here to see `title` and `detail`.
    func infoTip(_ title: String, _ detail: String) -> some View {
        modifier(InfoTipModifier(title: title, detail: detail))
    }
}
