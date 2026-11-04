//
//  BackendClient.swift
//  KalshiBot
//
//  What the install notice and crash reports share: the backend's address and key, the
//  Mac's non-personal details, the random install id, and the HTTP layer (swappable in
//  tests).
//

import Foundation

// MARK: - Configuration

/// I'm The Team's product backend and the ingest-only API key. The key is read from the
/// gitignored `ITTConfig.plist` bundled at build time; with no key nothing is sent.
nonisolated struct BackendConfig: Sendable {
    static let defaultBaseURL = URL(string: "https://www.imtheteam.com")!
    /// The product's slug in the backend, for the latest-release endpoint.
    static let productSlug = "kalshibot"
    /// The bundled resource holding the key, as `ITTAPIKey` (optionally `ITTBaseURL`).
    static let resourceName = "ITTConfig"

    let baseURL: URL
    let apiKey: String

    var installsURL: URL { baseURL.appending(path: "api/v1/installs") }
    var reportsURL: URL { baseURL.appending(path: "api/v1/reports") }
    /// The newest published release; needs no key.
    func latestReleaseURL(channel: String) -> URL {
        baseURL.appending(path: "api/v1/products/\(Self.productSlug)/latest")
            .appending(queryItems: [URLQueryItem(name: "channel", value: channel)])
    }
    /// False for a missing, empty or unfilled placeholder key.
    var hasKey: Bool { !apiKey.isEmpty && !apiKey.contains("<") }

    /// The configuration bundled with the app.
    static func bundled(_ bundle: Bundle = .main) -> BackendConfig {
        let values = bundle.url(forResource: resourceName, withExtension: "plist")
            .flatMap { NSDictionary(contentsOf: $0) as? [String: Any] } ?? [:]
        let key = (values["ITTAPIKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let url = (values["ITTBaseURL"] as? String).flatMap(URL.init(string:)) ?? defaultBaseURL
        return BackendConfig(baseURL: url, apiKey: key)
    }
}

/// The Mac's details sent with the install notice and crash reports. Never a serial number, MAC address,
/// user name or account.
nonisolated struct DeviceInfo: Sendable, Equatable {
    let osVersion: String
    let model: String
    let locale: String
    /// IANA identifier, e.g. "America/Chicago". The backend derives the approximate
    /// location from the connection's IP address; this is a hint (and covers VPNs).
    let timeZone: String

    static var current: DeviceInfo {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = v.patchVersion == 0 ? "macOS \(v.majorVersion).\(v.minorVersion)"
                                     : "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        return DeviceInfo(osVersion: os, model: hardwareModel, locale: Locale.current.identifier,
                          timeZone: TimeZone.current.identifier)
    }

    /// e.g. "Mac16,10".
    private static var hardwareModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "Mac" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

// MARK: - Transport

/// The HTTP layer, so tests can stand in for the network.
nonisolated protocol BackendTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

nonisolated struct URLSessionBackendTransport: BackendTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

// MARK: - Install id

/// This installation's random id (UUID v4), created on first use and kept from then on.
/// Never derived from hardware, network addresses, user names or accounts.
nonisolated enum InstallIdentity {
    static let key = "itt.install_id"

    static func id(in defaults: UserDefaults) -> String {
        if let id = defaults.string(forKey: key), UUID(uuidString: id) != nil { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: key)
        return id
    }
}
