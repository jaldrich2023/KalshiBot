//
//  AppLog.swift
//  KalshiBot
//
//  The app's recent log lines: the last 500 in memory, mirrored to one file per launch
//  in Application Support/Logs. A crash report attaches the tail of the crashed launch's
//  file; that file is never written again, so later launches can't mix into it.
//

import Foundation

nonisolated final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    static let capacity = 500
    /// Past this size the file is rewritten from the in-memory lines.
    static let maxFileBytes = 1_000_000
    /// Log files from earlier launches that are kept.
    static let keptFiles = 5

    static var defaultDirectory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appending(path: "Logs", directoryHint: .isDirectory)
    }

    let directory: URL
    /// This launch's log file, once `start()` has run.
    private(set) var fileURL: URL?

    private let lock = NSLock()
    private var lines: [String] = []
    private var handle: FileHandle?
    private var fileBytes = 0
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    init(directory: URL = AppLog.defaultDirectory) {
        self.directory = directory
    }

    /// Opens this launch's file and removes all but the newest earlier ones.
    func start(launchedAt date: Date = .now) {
        lock.withLock {
            guard handle == nil else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = DateFormatter.launchFileName.string(from: date)
            let url = directory.appending(path: "launch-\(name)-\(ProcessInfo.processInfo.processIdentifier).log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
            fileURL = url
            fileBytes = 0
            prune(keeping: url)
        }
    }

    /// Adds a timestamped line.
    func append(_ message: String) {
        let line = "\(stamp.string(from: .now)) \(message.replacingOccurrences(of: "\n", with: " "))"
        lock.withLock {
            lines.append(line)
            if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
            guard let handle else { return }
            let data = Data((line + "\n").utf8)
            if fileBytes + data.count > Self.maxFileBytes {
                // Rotate in place: keep the last `capacity` lines.
                let kept = Data((lines.joined(separator: "\n") + "\n").utf8)
                try? handle.truncate(atOffset: 0)
                try? handle.write(contentsOf: kept)
                fileBytes = kept.count
            } else {
                try? handle.write(contentsOf: data)
                fileBytes += data.count
            }
        }
    }

    var recentLines: [String] { lock.withLock { lines } }

    /// The last `count` lines of a log file, at most `maxBytes` long.
    static func tail(of url: URL, lines count: Int, maxBytes: Int) -> [String] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(count).map(String.init))
        while !lines.isEmpty, lines.joined(separator: "\n").utf8.count > maxBytes { lines.removeFirst() }
        return lines
    }

    private func prune(keeping current: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "log" && $0 != current } ?? []
        let newestFirst = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for url in newestFirst.dropFirst(Self.keptFiles) { try? FileManager.default.removeItem(at: url) }
    }
}

nonisolated private extension DateFormatter {
    static let launchFileName: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
