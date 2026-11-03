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

    /// The window's fixed content size, in points: a 2,400 × 1,600 window once macOS adds
    /// the 52-point title bar.
    static let windowSize = CGSize(width: 2400, height: 1548)

    /// The usable part of the main screen (below the menu bar, beside the Dock).
    private var screenFrame: CGRect {
        NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1819, height: 1536)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
                // A fixed size the five-column dashboard is laid out for, shrunk only on a
                // screen too small for it, so nothing runs off the edge (anything that
                // then doesn't fit scrolls inside the window).
                .frame(width: min(Self.windowSize.width, screenFrame.width - 40),
                       height: min(Self.windowSize.height, screenFrame.height))
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
