//
//  ContentView.swift
//  KalshiBot
//
//  Created by John Aldrich on 10/26/26.
//

import SwiftUI
import SwiftData
import AppKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(BotEngine.self) private var engine
    @Query(sort: \PredictionRecord.openTime, order: .reverse) private var records: [PredictionRecord]
    @State private var tab = ContentView.initialTab

    /// Debug builds can open on a given tab (`-screenshotTab 2`), for documentation screenshots.
    private static var initialTab: Int {
        #if DEBUG
        UserDefaults.standard.integer(forKey: "screenshotTab")
        #else
        0
        #endif
    }

    var body: some View {
        @Bindable var engine = engine
        // Redraw every tab as soon as a window settles (the query alone can lag until
        // the next prediction is inserted).
        let _ = engine.settledCount

        TabView(selection: $tab) {
            Tab("Dashboard", systemImage: "gauge.with.dots.needle.50percent", value: 0) {
                DashboardView(records: records)
            }
            Tab("Indicators", systemImage: "waveform.path.ecg", value: 1) {
                IndicatorsView(records: records)
            }
            Tab("Performance", systemImage: "chart.bar.xaxis", value: 2) {
                PerformanceView(records: engine.calls(records))
            }
            Tab("Prediction Log", systemImage: "list.bullet.rectangle", value: 3) {
                PredictionLogView(records: records)
            }
            Tab("Activity", systemImage: "text.alignleft", value: 4) {
                ActivityView()
            }
        }
        .containerBackground(for: .window) { AppBackground() }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                StatusPill(isRunning: engine.isRunning)
            }
            ToolbarItemGroup {
                Button("Copy CSV", systemImage: "doc.on.clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(PredictionLogView.csv(for: records), forType: .string)
                }
                .help("Copy the full prediction log as CSV")
            }
            // The primary action gets its own prominent glass group.
            ToolbarItem {
                Button(engine.isRunning ? "Stop" : "Start",
                       systemImage: engine.isRunning ? "stop.fill" : "play.fill") {
                    engine.isRunning ? engine.stop() : engine.start(context: modelContext)
                }
                .buttonStyle(.glassProminent)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            engine.start(context: modelContext)
        }
    }
}

#Preview {
    ContentView()
        .environment(BotEngine())
        .modelContainer(for: PredictionRecord.self, inMemory: true)
}
