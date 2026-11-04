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
    @Environment(InstallReporter.self) private var installReporter
    @Environment(UpdateChecker.self) private var updates
    @Environment(ReportClient.self) private var reports
    /// Crash files from an earlier launch while automatic reports are off: ask once.
    @State private var showsCrashPrompt = false
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
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if showsCrashPrompt {
                    CrashPrompt { choice in answerCrashPrompt(choice) }
                }
                if let release = updates.availableUpdate {
                    UpdateNotice(release: release) { updates.dismiss() }
                }
            }
            .padding(.bottom, 24)
        }
        .containerBackground(for: .window) { AppBackground() }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                StatusPill(isRunning: engine.isRunning)
                    .infoTip(engine.isRunning ? "Live" : "Paused", engine.isRunning
                             ? "The bot is collecting prices, calling each window \(engine.callDelayMinutes) min after it opens, and scoring and retraining after each settles. Leave it running to build up live windows."
                             : "The bot is stopped: no prices are collected and no windows are called. Press Start to resume; windows missed while paused aren't called.")
            }
            ToolbarItemGroup {
                Button("Copy CSV", systemImage: "doc.on.clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(PredictionLogView.csv(for: records), forType: .string)
                }
                .infoTip("Copy CSV", "Copies the full prediction log to the clipboard as CSV — every window with its call, confidence, Kalshi's price, the settlement and the result — ready to paste into a spreadsheet.")
            }
            // The primary action gets its own prominent glass group.
            ToolbarItem {
                Button(engine.isRunning ? "Stop" : "Start",
                       systemImage: engine.isRunning ? "stop.fill" : "play.fill") {
                    engine.isRunning ? engine.stop() : engine.start(context: modelContext)
                }
                .buttonStyle(.glassProminent)
                .infoTip(engine.isRunning ? "Stop" : "Start", engine.isRunning
                         ? "Stops collecting prices and calling windows. The log, model and settings are kept."
                         : "Starts collecting prices and calling windows. The first call locks \(engine.callDelayMinutes) min into the next window.")
            }
        }
        .preferredColorScheme(.dark)
        .alert(manualCheckTitle, isPresented: Binding(get: { updates.manualResult != nil && updates.availableUpdate == nil },
                                                      set: { if !$0 { updates.manualResult = nil } })) {
            Button("OK") { updates.manualResult = nil }
        } message: {
            Text(manualCheckMessage)
        }
        .task {
            // Unit tests run inside this app; starting the bot there would trade places with
            // the live app on the same data, and miss or double-log windows.
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            engine.start(context: modelContext)
            // Once the window is up: the anonymous install notice (if it's due), the update
            // check (at most every 6 hours), crash reports left by an earlier launch, then
            // anything waiting in the outbox — and a retry every 10 minutes from then on.
            await installReporter.reportIfNeeded()
            await updates.checkIfDue()
            let crashes = crashReports
            if crashes.collect(into: reports) == 0, crashes.hasPending, reports.isConfigured {
                showsCrashPrompt = true
            }
            await reports.flush(respectingBackoff: false)
            reports.startPeriodicRetry()
            #if DEBUG
            CrashTest.runIfRequested()
            #endif
        }
    }
}

extension ContentView {
    private var crashReports: CrashReports {
        let settings = engine.crashReportSettings
        return CrashReports(settings: { settings })
    }

    private func answerCrashPrompt(_ choice: CrashPrompt.Choice) {
        showsCrashPrompt = false
        switch choice {
        case .dontSend:
            crashReports.discardPending()
        case .always:
            UserDefaults.standard.set(true, forKey: ReportClient.automaticReportsKey)
            fallthrough
        case .send:
            crashReports.collect(into: reports, force: true)
            Task { await reports.flush(respectingBackoff: false) }
        }
    }

    private var manualCheckTitle: String {
        switch updates.manualResult {
        case .failed: "Couldn't check for updates"
        default: "Kalshi Bot is up to date"
        }
    }

    private var manualCheckMessage: String {
        switch updates.manualResult {
        case .failed(let reason): reason
        default: "Version \(AppVersion.current.marketing) is the newest release."
        }
    }
}

/// After a crash, while automatic reports are off: a one-time, non-blocking question.
private struct CrashPrompt: View {
    enum Choice { case send, dontSend, always }
    let answer: (Choice) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.bubble")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("The app crashed last time. Send an anonymous crash report?")
                .fontWeight(.medium)
            Button("Send") { answer(.send) }
                .buttonStyle(.glassProminent)
            Button("Don't Send") { answer(.dontSend) }
                .buttonStyle(.glass)
            Button("Always Send") { answer(.always) }
                .buttonStyle(.glass)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
    }
}

/// A quiet, dismissible note that a newer release is out. It only opens the download
/// page; nothing is downloaded or installed automatically.
private struct UpdateNotice: View {
    let release: LatestRelease
    let onDismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(release.title ?? "Kalshi Bot \(release.version) is available")
                .fontWeight(.medium)
            if let url = release.downloadURL {
                Button("Download") { openURL(url) }
                    .buttonStyle(.glassProminent)
            }
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Hide this notice until the next release")
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    ContentView()
        .environment(BotEngine())
        .environment(InstallReporter(config: BackendConfig(baseURL: BackendConfig.defaultBaseURL, apiKey: "")))
        .environment(UpdateChecker(config: BackendConfig(baseURL: BackendConfig.defaultBaseURL, apiKey: "")))
        .environment(ReportClient(config: BackendConfig(baseURL: BackendConfig.defaultBaseURL, apiKey: "")))
        .modelContainer(for: PredictionRecord.self, inMemory: true)
}
