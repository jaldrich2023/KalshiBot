//
//  AppVersion.swift
//  KalshiBot
//
//  Semantic versioning (https://semver.org): MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD].
//  The marketing version (MARKETING_VERSION build setting) must follow it:
//  bump MAJOR for incompatible changes, MINOR for new features, PATCH for fixes.
//

import Foundation

nonisolated struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    /// Dot-separated pre-release identifiers, e.g. ["beta", "2"] for "-beta.2".
    let preRelease: [String]
    /// Build metadata after "+". Ignored for precedence, per the spec.
    let buildMetadata: [String]

    init(major: Int, minor: Int, patch: Int, preRelease: [String] = [], buildMetadata: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.preRelease = preRelease
        self.buildMetadata = buildMetadata
    }

    /// Parses a strict SemVer 2.0.0 string; returns nil if it isn't one.
    init?(_ string: String) {
        var rest = Substring(string)
        var metadata: [String] = []
        if let plus = rest.firstIndex(of: "+") {
            metadata = rest[rest.index(after: plus)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            rest = rest[..<plus]
            guard metadata.allSatisfy(Self.isValidIdentifier) else { return nil }
        }
        var pre: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            pre = rest[rest.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            rest = rest[..<dash]
            guard pre.allSatisfy({ Self.isValidIdentifier($0) && !Self.hasLeadingZero($0) }) else { return nil }
        }
        let core = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              core.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) && !Self.hasLeadingZero(String($0)) }),
              let major = Int(core[0]), let minor = Int(core[1]), let patch = Int(core[2]) else { return nil }
        self.init(major: major, minor: minor, patch: patch, preRelease: pre, buildMetadata: metadata)
    }

    var isPreRelease: Bool { !preRelease.isEmpty }

    var description: String {
        var text = "\(major).\(minor).\(patch)"
        if !preRelease.isEmpty { text += "-" + preRelease.joined(separator: ".") }
        if !buildMetadata.isEmpty { text += "+" + buildMetadata.joined(separator: ".") }
        return text
    }

    /// Precedence per SemVer §11; build metadata doesn't count.
    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        // A pre-release sorts before the release it precedes.
        switch (lhs.preRelease.isEmpty, rhs.preRelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (a, b) in zip(lhs.preRelease, rhs.preRelease) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y          // both numeric: numerically
            case (_?, nil): return true              // numeric < alphanumeric
            case (nil, _?): return false
            case (nil, nil): return a < b            // both alphanumeric: ASCII order
            }
        }
        return lhs.preRelease.count < rhs.preRelease.count
    }

    /// Equality follows precedence, so build metadata is ignored.
    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    private static func isValidIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Numeric identifiers must not have leading zeros ("0" itself is fine).
    private static func hasLeadingZero(_ id: String) -> Bool {
        id.count > 1 && id.first == "0" && id.allSatisfy(\.isASCIIDigit)
    }
}

nonisolated private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// This build's version details, read from the bundle's Info.plist.
nonisolated struct AppVersion: Sendable {
    /// MARKETING_VERSION, e.g. "1.0.0".
    let marketing: String
    /// CURRENT_PROJECT_VERSION, the build number.
    let build: String
    let copyright: String

    var semantic: SemanticVersion? { SemanticVersion(marketing) }

    static var current: AppVersion {
        let info = Bundle.main.infoDictionary ?? [:]
        return AppVersion(
            marketing: info["CFBundleShortVersionString"] as? String ?? "0.0.0",
            build: info["CFBundleVersion"] as? String ?? "0",
            copyright: info["NSHumanReadableCopyright"] as? String ?? "© 2026 I'm The Team, LLC. All rights reserved."
        )
    }
}
