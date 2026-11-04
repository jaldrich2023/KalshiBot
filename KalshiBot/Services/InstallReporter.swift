//
//  InstallReporter.swift
//  KalshiBot
//
//  A one-time, anonymous install notice to I'm The Team's product backend: a random
//  install id, the app version and build, the macOS version, the Mac model, the locale
//  and the time zone — no personal data. The app never looks up its own location; the
//  server derives an approximate one from the connection's IP address. It's sent once
//  per installation, then again after each update and at most every 30 days, so the
//  backend's version and location views stay current. The response may name a newer
//  release, which the app offers as a quiet, dismissible notice.
//

import Foundation
import Observation
import os

// MARK: - Wire format

nonisolated struct InstallPingPayload: Codable, Sendable, Equatable {
    let installID: String
    let appVersion: String
    let appBuild: String
    let osVersion: String
    let device: String
    let locale: String
    let timezone: String
    let channel: String

    enum CodingKeys: String, CodingKey {
        case installID = "install_id", appVersion = "app_version", appBuild = "app_build"
        case osVersion = "os_version", device, locale, timezone, channel
    }
}

/// The newest published release, as the backend reports it.
nonisolated struct LatestRelease: Decodable, Sendable, Equatable {
    let version: String
    let build: String?
    let title: String?
    let notes: String?
    let downloadURL: URL?
    let checksum: String?
    let minOS: String?
    let releasedAt: String?

    enum CodingKeys: String, CodingKey {
        case version, build, title, notes, checksum
        case downloadURL = "download_url", minOS = "min_os", releasedAt = "released_at"
    }

    init(version: String, build: String? = nil, title: String? = nil, notes: String? = nil, downloadURL: URL? = nil,
         checksum: String? = nil, minOS: String? = nil, releasedAt: String? = nil) {
        self.version = version
        self.build = build
        self.title = title
        self.notes = notes
        self.downloadURL = downloadURL
        self.checksum = checksum
        self.minOS = minOS
        self.releasedAt = releasedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        // The build may arrive as a string or a number.
        build = (try? c.decodeIfPresent(String.self, forKey: .build)) ?? (try? c.decodeIfPresent(Int.self, forKey: .build)).map(String.init)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        downloadURL = (try? c.decodeIfPresent(String.self, forKey: .downloadURL)).flatMap(URL.init(string:))
        checksum = try? c.decodeIfPresent(String.self, forKey: .checksum)
        minOS = try? c.decodeIfPresent(String.self, forKey: .minOS)
        releasedAt = try? c.decodeIfPresent(String.self, forKey: .releasedAt)
    }
}

nonisolated struct InstallPingResponse: Decodable, Sendable {
    let ok: Bool?
    let firstRun: Bool?
    let latest: LatestRelease?

    enum CodingKeys: String, CodingKey { case ok, firstRun = "first_run", latest }
}

// MARK: - Reporter

@Observable
final class InstallReporter {
    enum Keys {
        static let installID = InstallIdentity.key
        static let reported = "itt.install_reported"
        static let reportedVersion = "itt.install_reported_version"
        /// When the backend last accepted (or refused) a ping, for the 30-day interval.
        static let lastPing = "itt.install_last_ping"
        /// Off (false) skips the notice entirely. Set in Settings › Privacy.
        static let telemetryEnabled = "itt.telemetry_enabled"
    }

    enum Outcome: Equatable {
        /// Nothing sent: no key, telemetry off, already reported for this version, or
        /// already tried this launch.
        case skipped
        /// The backend accepted it (201 on the first ping for this install, 200 after).
        case reported(firstRun: Bool)
        /// The key or request was refused (401 or another 4xx). Marked as reported so a
        /// bad key doesn't retry forever.
        case rejected(status: Int)
        /// Network failure, timeout, 429 or 5xx: tried again on the next launch.
        case retryLater
    }

    static let timeout: TimeInterval = 10
    /// The longest between pings, so the backend's location and version views stay current.
    static let refreshInterval: TimeInterval = 30 * 24 * 3600
    static let channel = "stable"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let config: BackendConfig
    @ObservationIgnored private let transport: BackendTransport
    @ObservationIgnored private let version: AppVersion
    @ObservationIgnored private let device: DeviceInfo
    @ObservationIgnored private let now: () -> Date
    /// Told about the newest release the reply names.
    @ObservationIgnored private let updates: UpdateChecker?
    @ObservationIgnored private var attemptedThisLaunch = false
    @ObservationIgnored private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "KalshiBot", category: "InstallPing")

    init(defaults: UserDefaults = .standard, config: BackendConfig = .bundled(),
         transport: BackendTransport = URLSessionBackendTransport(),
         version: AppVersion = .current, device: DeviceInfo = .current, now: @escaping () -> Date = Date.init,
         updates: UpdateChecker? = nil) {
        self.defaults = defaults
        self.config = config
        self.transport = transport
        self.version = version
        self.device = device
        self.now = now
        self.updates = updates
    }

    /// This installation's random id (UUID v4), created on first use and kept from then on.
    var installID: String {
        InstallIdentity.id(in: defaults)
    }

    var isTelemetryEnabled: Bool { defaults.object(forKey: Keys.telemetryEnabled) as? Bool ?? true }

    /// Not yet reported, last reported from a different version, or not for 30 days.
    var isDue: Bool {
        guard defaults.bool(forKey: Keys.reported), defaults.string(forKey: Keys.reportedVersion) == version.marketing,
              let last = defaults.object(forKey: Keys.lastPing) as? Date else { return true }
        return now().timeIntervalSince(last) >= Self.refreshInterval
    }

    /// Sends the notice if it's due — at most once per launch, never in a loop.
    @discardableResult
    func reportIfNeeded() async -> Outcome {
        guard config.hasKey, isTelemetryEnabled, isDue, !attemptedThisLaunch else { return .skipped }
        attemptedThisLaunch = true

        let payload = InstallPingPayload(installID: installID, appVersion: version.marketing, appBuild: version.build,
                                         osVersion: device.osVersion, device: device.model, locale: device.locale,
                                         timezone: device.timeZone, channel: Self.channel)
        var request = URLRequest(url: config.installsURL, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = try? JSONEncoder().encode(payload)

        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            logger.info("Install notice not sent (\(error.localizedDescription, privacy: .public)); will retry next launch")
            return .retryLater
        }

        switch response.statusCode {
        case 200..<300:
            logger.notice("Install notice sent (HTTP \(response.statusCode))")
            markReported()
            let body = try? JSONDecoder().decode(InstallPingResponse.self, from: data)
            updates?.consider(body?.latest)
            return .reported(firstRun: body?.firstRun ?? (response.statusCode == 201))
        case 408, 429, 500...:
            logger.info("Install notice deferred (HTTP \(response.statusCode)); will retry next launch")
            return .retryLater
        default:
            // 401 (wrong key) or another client error: retrying won't help.
            logger.warning("Install notice refused (HTTP \(response.statusCode)); check the ITTAPIKey in ITTConfig.plist. Not retrying.")
            markReported()
            return .rejected(status: response.statusCode)
        }
    }

    private func markReported() {
        defaults.set(true, forKey: Keys.reported)
        defaults.set(version.marketing, forKey: Keys.reportedVersion)
        defaults.set(now(), forKey: Keys.lastPing)
    }
}
