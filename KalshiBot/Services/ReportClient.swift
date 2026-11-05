//
//  ReportClient.swift
//  KalshiBot
//
//  Sends crash, bug, feedback and telemetry reports to I'm The Team's backend. Each
//  report gets the app's non-personal context, is cut to the backend's limits, and is
//  posted with a 15-second timeout. One that can't be sent now (offline, 429, 5xx) waits
//  in an outbox on disk and is retried at the next launch and every 10 minutes while the
//  app runs, backing off exponentially. A 401 or 413 drops it: retrying can't help.
//

import Foundation
import Observation
import os

// MARK: - Report

/// Any JSON value, for a report's free-form metadata.
nonisolated enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

nonisolated struct Report: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable, CaseIterable { case bug, crash, feedback, telemetry }
    enum Severity: String, Codable, Sendable { case low, normal, high, critical }

    var kind: Kind
    var severity: Severity = .normal
    var title: String
    var description: String?
    var appVersion: String?
    var appBuild: String?
    var osVersion: String?
    var device: String?
    var locale: String?
    var installID: String?
    /// Only ever what the user typed into the report form.
    var contact: String?
    var logs: String?
    var fingerprint: String?
    var metadata: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case kind, severity, title, description, device, locale, contact, logs, fingerprint, metadata
        case appVersion = "app_version", appBuild = "app_build", osVersion = "os_version", installID = "install_id"
    }

    /// The backend's limits.
    enum Limit {
        static let title = 200
        static let description = 20_000
        static let contact = 320
        static let logBytes = 100_000
        static let metadataBytes = 32_000
    }

    /// Cut to the backend's limits, so it's never rejected for size. Logs keep their end
    /// (the most recent lines); metadata that's too big is replaced by a note saying so.
    func truncated() -> Report {
        var r = self
        r.title = String(title.prefix(Limit.title))
        r.description = description.map { String($0.prefix(Limit.description)) }
        r.contact = contact.map { String($0.prefix(Limit.contact)) }
        r.logs = logs.map { Self.suffix($0, maxBytes: Limit.logBytes) }
        if let metadata, let data = try? JSONEncoder().encode(metadata), data.count > Limit.metadataBytes {
            r.metadata = ["truncated": .bool(true), "original_bytes": .number(Double(data.count))]
        }
        return r
    }

    /// The last whole lines of `text` that fit in `maxBytes` of UTF-8.
    static func suffix(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var bytes = Array(text.utf8.suffix(maxBytes))
        // Don't start mid-character or mid-line.
        while let first = bytes.first, first & 0xC0 == 0x80 { bytes.removeFirst() }
        let tail = String(decoding: bytes, as: UTF8.self)
        if let newline = tail.firstIndex(of: "\n") { return String(tail[tail.index(after: newline)...]) }
        return tail
    }
}

// MARK: - Client

@Observable
final class ReportClient {
    /// The opt-in for automatic (crash and telemetry) reports. Off by default; reports the
    /// user sends from the form are always allowed.
    static let automaticReportsKey = "itt.crash_reports_enabled"
    static let timeout: TimeInterval = 15
    static let outboxLimit = 50
    static let retryInterval: TimeInterval = 10 * 60
    /// The longest a queued report waits between attempts.
    static let maxBackoff: TimeInterval = 12 * 3600

    enum SendResult: Equatable {
        case sent(id: String?)
        /// Couldn't be sent now; it's in the outbox and will be retried.
        case queued(reason: String)
        /// Refused for good (401 bad key, 413 too large).
        case rejected(status: Int)
        /// No ingest key in this build, so reporting is off.
        case disabled
    }

    /// A report waiting in the outbox.
    nonisolated struct OutboxItem: Codable, Sendable {
        var report: Report
        var created: Date
        var attempts: Int
        var nextAttempt: Date
        /// The user chose to send this one (the crash prompt's Send), so it goes even with
        /// automatic reports off. Optional so older outbox files still decode.
        var userApproved: Bool?
    }

    /// A queued report older than this is dropped rather than retried.
    static let maxAge: TimeInterval = 30 * 24 * 3600

    static var defaultOutbox: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appending(path: "outbox", directoryHint: .isDirectory)
    }

    @ObservationIgnored let outbox: URL
    @ObservationIgnored private let config: BackendConfig
    @ObservationIgnored private let transport: BackendTransport
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let version: AppVersion
    @ObservationIgnored private let device: DeviceInfo
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var isFlushing = false
    @ObservationIgnored private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "KalshiBot", category: "Reports")

    init(config: BackendConfig = .bundled(), transport: BackendTransport = URLSessionBackendTransport(),
         defaults: UserDefaults = .standard, version: AppVersion = .current, device: DeviceInfo = .current,
         outbox: URL = ReportClient.defaultOutbox, now: @escaping () -> Date = Date.init) {
        self.config = config
        self.transport = transport
        self.defaults = defaults
        self.version = version
        self.device = device
        self.outbox = outbox
        self.now = now
    }

    var isConfigured: Bool { config.hasKey }

    static func automaticReportsEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: automaticReportsKey) as? Bool ?? false
    }

    /// The report exactly as it would be sent: the app's context filled in, then cut to
    /// the limits.
    func prepared(_ report: Report) -> Report {
        var r = report
        r.appVersion = r.appVersion ?? version.marketing
        r.appBuild = r.appBuild ?? version.build
        r.osVersion = r.osVersion ?? device.osVersion
        r.device = r.device ?? device.model
        r.locale = r.locale ?? device.locale
        r.installID = r.installID ?? InstallIdentity.id(in: defaults)
        return r.truncated()
    }

    /// Sends now; if that fails for a reason that may pass, keeps it in the outbox.
    @discardableResult
    func send(_ report: Report) async -> SendResult {
        guard config.hasKey else { return .disabled }
        let ready = prepared(report)
        switch await post(ready) {
        case .success(let id): return .sent(id: id)
        case .permanent(let status): return .rejected(status: status)
        case .retry(let reason):
            enqueue(ready, attempts: 1)
            return .queued(reason: reason)
        }
    }

    /// Puts a report in the outbox without trying it first (for example, a crash
    /// collected at launch, sent by the next flush).
    func enqueue(_ report: Report, attempts: Int = 0, userApproved: Bool = false) {
        try? FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        let date = now()
        let item = OutboxItem(report: prepared(report), created: date, attempts: attempts,
                              nextAttempt: date.addingTimeInterval(Self.backoff(afterAttempts: attempts)),
                              userApproved: userApproved ? true : nil)
        let name = "\(Int(date.timeIntervalSince1970 * 1000))-\(UUID().uuidString).json"
        try? JSONEncoder().encode(item).write(to: outbox.appending(path: name), options: .atomic)
        trimOutbox()
    }

    /// Queued reports, oldest first.
    func queued() -> [(url: URL, item: OutboxItem)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url), let item = try? JSONDecoder().decode(OutboxItem.self, from: data) else {
                    try? FileManager.default.removeItem(at: url)
                    return nil
                }
                return (url, item)
            }
            .sorted { $0.item.created < $1.item.created }
    }

    /// Sends what's waiting. At launch every queued report is tried; the periodic retry
    /// only tries those whose back-off has passed. Stops at the first that has to wait.
    @discardableResult
    func flush(respectingBackoff: Bool = true) async -> [SendResult] {
        guard config.hasKey, !isFlushing else { return [] }
        isFlushing = true
        defer { isFlushing = false }
        var results: [SendResult] = []
        for (url, item) in queued() where !respectingBackoff || item.nextAttempt <= now() {
            guard let result = await attempt(item, at: url) else { continue }
            results.append(result)
            if case .queued = result { return results }
        }
        return results
    }

    /// Retries one queued report now — the form's Retry Now. Nil if it's no longer in the
    /// outbox (a flush already sent or dropped it).
    func resend(_ report: Report) async -> SendResult? {
        guard config.hasKey else { return .disabled }
        guard !isFlushing else { return .queued(reason: "It's being retried right now") }
        let ready = prepared(report)
        guard let (url, item) = queued().first(where: { $0.item.report == ready }) else { return nil }
        isFlushing = true
        defer { isFlushing = false }
        return await attempt(item, at: url)
    }

    /// Posts one queued report and updates the outbox: deleted when sent or refused,
    /// rescheduled when it has to wait. Nil when it was dropped without sending — too old,
    /// or an automatic report after the user turned automatic reports off.
    private func attempt(_ queuedItem: OutboxItem, at url: URL) async -> SendResult? {
        var item = queuedItem
        let automatic = item.report.kind == .crash || item.report.kind == .telemetry
        if now().timeIntervalSince(item.created) > Self.maxAge
            || (automatic && item.userApproved != true && !Self.automaticReportsEnabled(defaults)) {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        switch await post(item.report) {
        case .success(let id):
            try? FileManager.default.removeItem(at: url)
            return .sent(id: id)
        case .permanent(let status):
            logger.warning("Report \(item.report.title, privacy: .public) refused (HTTP \(status)); dropping it")
            try? FileManager.default.removeItem(at: url)
            return .rejected(status: status)
        case .retry(let reason):
            item.attempts += 1
            item.nextAttempt = now().addingTimeInterval(Self.backoff(afterAttempts: item.attempts))
            try? JSONEncoder().encode(item).write(to: url, options: .atomic)
            return .queued(reason: reason)
        }
    }

    /// Retries the outbox every 10 minutes while the app runs.
    func startPeriodicRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.retryInterval))
                await self?.flush(respectingBackoff: true)
            }
        }
    }

    /// 10 min, 20 min, 40 min, … up to 12 hours.
    static func backoff(afterAttempts attempts: Int) -> TimeInterval {
        guard attempts > 0 else { return 0 }
        return min(retryInterval * pow(2, Double(attempts - 1)), maxBackoff)
    }

    private func trimOutbox() {
        let items = queued()
        for old in items.dropLast(Self.outboxLimit) { try? FileManager.default.removeItem(at: old.url) }
    }

    private enum PostResult { case success(String?), permanent(Int), retry(String) }

    private func post(_ report: Report) async -> PostResult {
        var request = URLRequest(url: config.reportsURL, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = try? JSONEncoder().encode(report)
        do {
            let (data, response) = try await transport.send(request)
            switch response.statusCode {
            case 200..<300:
                let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"].map { "\($0)" }
                return .success(id)
            case 408:
                return .retry("The server timed out")
            case 429:
                return .retry("The server is busy (rate limited)")
            case 400..<500:
                // 401 bad key, 413 too large, 400/403/404/422 invalid: retrying won't help.
                return .permanent(response.statusCode)
            default:
                return .retry("The server returned HTTP \(response.statusCode)")
            }
        } catch {
            return .retry(error.localizedDescription)
        }
    }
}
