//
//  ReportProblemView.swift
//  KalshiBot
//
//  Help › Report a Problem…: a small form that sends a bug report or feedback to
//  I'm The Team. The user chooses to send it, so it's allowed even when automatic
//  reports are off. Preview shows exactly what will be sent.
//

import SwiftUI

struct ReportProblemView: View {
    static let windowID = "report-problem"

    @Environment(BotEngine.self) private var engine
    @Environment(ReportClient.self) private var reports
    @Environment(\.dismissWindow) private var dismissWindow

    enum Kind: String, CaseIterable, Identifiable {
        case bug = "Bug", feedback = "Feedback"
        var id: String { rawValue }
        var reportKind: Report.Kind { self == .bug ? .bug : .feedback }
    }

    enum Status: Equatable {
        case idle, sending
        case sent(id: String?)
        case queued(reason: String)
        case failed(String)
    }

    @State private var kind = Kind.bug
    @State private var title = ""
    @State private var details = ""
    @State private var contact = ""
    @State private var includeLogs = true
    @State private var isPreviewing = false
    @State private var status = Status.idle

    private var canSend: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && status != .sending && reports.isConfigured
    }

    var body: some View {
        Form {
            Picker("Kind", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField("Title", text: $title, prompt: Text("A short summary"))
            VStack(alignment: .leading, spacing: 4) {
                Text("Description")
                TextEditor(text: $details)
                    .font(.body)
                    .frame(height: 140)
                    .scrollContentBackground(.hidden)
                    .background(.background.secondary, in: .rect(cornerRadius: 6))
            }
            TextField("Contact e-mail (optional)", text: $contact, prompt: Text("Only if you'd like a reply"))
            HStack {
                Toggle("Include recent logs", isOn: $includeLogs)
                Spacer()
                Button("Preview…") { isPreviewing = true }
            }
            Text("Sent with the app and macOS versions, Mac model, locale, a random install id and the bot's settings (not your stake). Logs have keys, tokens, passwords and e-mail addresses masked.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            statusView
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismissWindow(id: Self.windowID) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") { Task { await submit() } }
                    .disabled(!canSend)
            }
        }
        .sheet(isPresented: $isPreviewing) {
            ReportPreview(text: previewText) { isPreviewing = false }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            if !reports.isConfigured {
                Label("Reporting isn't set up in this build (no ingest key), so reports can't be sent.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        case .sending:
            HStack { ProgressView().controlSize(.small); Text("Sending…") }
        case .sent(let id):
            Label(id.map { "Sent — thank you. Report \($0)." } ?? "Sent — thank you.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .textSelection(.enabled)
        case .queued(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Label("Couldn't send it now: \(reason). It's saved and will be sent automatically.", systemImage: "tray.and.arrow.up")
                    .foregroundStyle(.orange)
                Button("Retry Now") { Task { await retry() } }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Button("Try Again") { Task { await submit() } }
            }
        }
    }

    /// The report as the form stands.
    private var report: Report {
        let logs = includeLogs ? Scrubber.scrub(AppLog.shared.recentLines.suffix(300).joined(separator: "\n")) : nil
        let email = contact.trimmingCharacters(in: .whitespaces)
        return Report(kind: kind.reportKind, severity: .normal, title: title.trimmingCharacters(in: .whitespaces),
                      description: details.isEmpty ? nil : details, contact: email.isEmpty ? nil : email, logs: logs,
                      metadata: ["settings": .object(engine.crashReportSettings.mapValues(JSONValue.string)),
                                 "source": .string("report_form")])
    }

    /// Exactly what will be sent, as JSON.
    private var previewText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(reports.prepared(report))).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private func submit() async {
        status = .sending
        switch await reports.send(report) {
        case .sent(let id): status = .sent(id: id)
        case .queued(let reason): status = .queued(reason: reason)
        case .rejected(let code):
            status = .failed(code == 401 ? "The report server refused this build's key (HTTP 401)." : "The report was refused (HTTP \(code)).")
        case .disabled: status = .failed("Reporting isn't set up in this build.")
        }
    }

    private func retry() async {
        status = .sending
        let results = await reports.flush(respectingBackoff: false)
        if case .sent(let id)? = results.last { status = .sent(id: id) }
        else if case .queued(let reason)? = results.last { status = .queued(reason: reason) }
        else { status = .sent(id: nil) }
    }
}

/// The exact JSON a report will send.
private struct ReportPreview: View {
    let text: String
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This is exactly what will be sent").font(.headline)
            ScrollView {
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 360)
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
    }
}

/// Help › Report a Problem…
struct ReportProblemCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Report a Problem…") { openWindow(id: ReportProblemView.windowID) }
    }
}

/// Kalshi Bot › Check for Updates…
struct CheckForUpdatesCommand: View {
    let updates: UpdateChecker

    var body: some View {
        Button("Check for Updates…") { Task { await updates.checkNow() } }
    }
}
