//
//  UpdateChecker.swift
//  KalshiBot
//
//  Asks the backend for the newest published release — at launch at most every 6 hours,
//  or on demand from Check for Updates… — and offers it with a quiet notice if it's newer
//  than this build. It never downloads or installs anything; the notice opens the
//  download page. The install notice's reply feeds in here too.
//

import Foundation
import Observation

@Observable
final class UpdateChecker {
    enum Keys {
        static let lastCheck = "itt.last_update_check"
        static let dismissed = "itt.dismissed_update_version"
    }

    static let interval: TimeInterval = 6 * 3600
    static let channel = "stable"

    enum CheckResult: Equatable {
        case updateAvailable(LatestRelease)
        case upToDate
        case failed(String)
    }

    /// A newer release than this one, unless the user dismissed it.
    private(set) var availableUpdate: LatestRelease?
    /// The outcome of the last Check for Updates…, for its alert.
    var manualResult: CheckResult?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let config: BackendConfig
    @ObservationIgnored private let transport: BackendTransport
    @ObservationIgnored private let version: AppVersion
    @ObservationIgnored private let now: () -> Date

    init(defaults: UserDefaults = .standard, config: BackendConfig = .bundled(),
         transport: BackendTransport = URLSessionBackendTransport(), version: AppVersion = .current,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.config = config
        self.transport = transport
        self.version = version
        self.now = now
    }

    var isDue: Bool {
        guard let last = defaults.object(forKey: Keys.lastCheck) as? Date else { return true }
        return now().timeIntervalSince(last) >= Self.interval
    }

    /// The launch check: skipped if one ran in the last 6 hours.
    @discardableResult
    func checkIfDue() async -> CheckResult? {
        guard isDue else { return nil }
        return await check()
    }

    /// Check for Updates…: always checks, and shows a release even if its notice was
    /// dismissed. A newer release shows as the notice; "up to date" and failures are
    /// reported for the alert.
    func checkNow() async {
        let result = await check(ignoringDismissal: true)
        if case .updateAvailable = result { manualResult = nil } else { manualResult = result }
    }

    @discardableResult
    func check(ignoringDismissal: Bool = false) async -> CheckResult {
        var request = URLRequest(url: config.latestReleaseURL(channel: Self.channel), timeoutInterval: 15)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await transport.send(request)
            switch response.statusCode {
            case 200..<300:
                defaults.set(now(), forKey: Keys.lastCheck)
                let release = (try? JSONDecoder().decode(LatestReleaseResponse.self, from: data))?.release
                consider(release, ignoringDismissal: ignoringDismissal)
                return newer(release).map(CheckResult.updateAvailable) ?? .upToDate
            case 404:
                defaults.set(now(), forKey: Keys.lastCheck)
                return .upToDate   // nothing published yet
            default:
                return .failed("The update server returned HTTP \(response.statusCode).")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Offers `latest` if it's newer than this build and not dismissed.
    func consider(_ latest: LatestRelease?, ignoringDismissal: Bool = false) {
        guard let release = newer(latest),
              ignoringDismissal || release.version != defaults.string(forKey: Keys.dismissed) else { return }
        availableUpdate = release
    }

    /// Hides the notice for this release; a later release shows it again.
    func dismiss() {
        guard let availableUpdate else { return }
        defaults.set(availableUpdate.version, forKey: Keys.dismissed)
        self.availableUpdate = nil
    }

    /// `latest` if it's a newer semantic version with a web download link.
    func newer(_ latest: LatestRelease?) -> LatestRelease? {
        guard let latest, let newest = SemanticVersion(latest.version), let running = version.semantic, newest > running,
              let scheme = latest.downloadURL?.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return latest
    }
}

nonisolated struct LatestReleaseResponse: Decodable, Sendable {
    let release: LatestRelease?
}
