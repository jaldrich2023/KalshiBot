//
//  KalshiBotApp.swift
//  KalshiBot
//
//  Created by John Aldrich on 10/26/26.
//

import SwiftUI
import SwiftData
import AppKit

@main
struct KalshiBotApp: App {
    @State private var engine = BotEngine()
    /// Set by the dashboard once it has measured itself; until then, a sensible default.
    @AppStorage("dashboardRequiredHeight") private var dashboardHeight: Double = 0

    init() {
        Self.quitOtherInstances()
    }

    /// Two copies of the bot would both write the prediction log, settings and model.
    /// macOS normally prevents a second copy, but builds launched from Xcode don't, so
    /// any other running copy is asked to quit.
    private static func quitOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let current = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where app.processIdentifier != current {
            app.terminate()
        }
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            PredictionRecord.self,
            TrainingExample.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    /// The usable part of the main screen (below the menu bar, beside the Dock).
    private var screenFrame: CGRect {
        NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1819, height: 1536)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
                // As wide as the dashboard's five columns use well, and tall enough to show
                // all of it — but never larger than the screen, so nothing runs off it
                // (anything that still doesn't fit scrolls inside the window).
                .frame(width: min(2400, screenFrame.width - 40),
                       height: min(max(dashboardHeight, 900), screenFrame.height))
        }
        .windowResizability(.contentSize)
        // Always open the dashboard at launch (and from the Dock), never restore a
        // saved state of "no windows" — the bot keeps running, so it must be visible.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .modelContainer(sharedModelContainer)
        .commands {
            CommandGroup(replacing: .appInfo) { AboutCommand() }
        }

        Window("About Kalshi Bot", id: AboutView.windowID) {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .restorationBehavior(.disabled)
    }
}
