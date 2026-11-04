//
//  SettingsView.swift
//  KalshiBot
//
//  Kalshi Bot › Settings… (⌘,): what the app may send to I'm The Team.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage(ReportClient.automaticReportsKey) private var crashReports = false
    @AppStorage(InstallReporter.Keys.telemetryEnabled) private var installNotice = true

    static let privacyURL = URL(string: "https://github.com/jaldrich2023/KalshiBot#privacy")!

    var body: some View {
        Form {
            Section {
                Toggle("Send crash and bug reports", isOn: $crashReports)
                Text("Off by default. When on, a crash is reported at the next launch: the crash type, the stack trace and the app's last 300 log lines (secrets masked), with the app and macOS versions, Mac model, locale, a random install id and the bot's settings — nothing personal. Reports you send from Help › Report a Problem… are always allowed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Send anonymous install notice", isOn: $installNotice)
                Text("Once per installation, after each update and about once a month: a random install id, the app version, macOS version, Mac model, locale and time zone. The server derives an approximate location from the connection's IP address.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Privacy")
            } footer: {
                Link("Privacy and disclaimer", destination: Self.privacyURL)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
/// Debug builds only: launch with `--crash-test` (a Swift trap), `--crash-test=segv`
/// (bad memory access) or `--crash-test=exception` (an uncaught Objective-C exception)
/// to crash 3 seconds after launch, so the next launch's crash report can be checked.
enum CrashTest {
    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard let flag = arguments.first(where: { $0.hasPrefix("--crash-test") }) else { return }
        let kind = flag.split(separator: "=").dropFirst().first.map(String.init) ?? "trap"
        AppLog.shared.append("Crash test requested: \(kind)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            switch kind {
            case "segv":
                UnsafeMutablePointer<Int>(bitPattern: 0x8)!.pointee = 1
            case "exception":
                Thread.detachNewThread {
                    NSException(name: .genericException, reason: "Crash test", userInfo: nil).raise()
                }
            default:
                fatalError("Crash test")
            }
        }
    }
}
#endif
