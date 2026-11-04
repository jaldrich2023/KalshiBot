//
//  CrashReporter.swift
//  KalshiBot
//
//  Automatic crash reports. A crashing process can't be trusted, so at crash time the
//  handlers only write a small JSON file to Application Support/crashes — using buffers
//  prepared at launch and async-signal-safe calls — and then re-raise, so macOS still
//  records the crash as usual. On the next launch the file is symbolicated, scrubbed of
//  anything personal, and sent to I'm The Team's backend, then deleted.
//

import Foundation
import CryptoKit
import MachO
import os

// MARK: - Capture (crash time)

/// The crash-time half. Everything a handler needs is prepared by `install`.
nonisolated enum CrashCapture {
    static let fatalSignals: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP]
    static let maxFrames: Int32 = 128

    static var defaultDirectory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appending(path: "crashes", directoryHint: .isDirectory)
    }

    /// Prepares the buffers and (unless `installHandlers` is false, as in tests) hooks the
    /// uncaught-exception handler and the fatal signals.
    static func install(directory: URL = defaultDirectory, version: AppVersion = .current,
                        logFile: URL? = AppLog.shared.fileURL, installHandlers: Bool = true) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CrashState.prepare(directory: directory, staticFields: staticFields(version: version, logFile: logFile))
        guard installHandlers else { return }

        NSSetUncaughtExceptionHandler { exception in
            CrashCapture.recordException(name: exception.name.rawValue, reason: exception.reason,
                                         addresses: exception.callStackReturnAddresses.map(\.uintValue),
                                         symbols: exception.callStackSymbols)
        }

        // A separate stack, so a stack overflow can still be recorded.
        let altSize = 64 * 1024
        var alt = stack_t(ss_sp: UnsafeMutableRawPointer.allocate(byteCount: altSize, alignment: 16), ss_size: altSize, ss_flags: 0)
        sigaltstack(&alt, nil)

        for signal in fatalSignals {
            var action = sigaction()
            action.__sigaction_u = __sigaction_u(__sa_sigaction: crashSignalHandler)
            action.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
        }
    }

    /// Writes the crash file for a fatal signal. Async-signal-safe: no allocation, no
    /// locks, no Objective-C or Swift runtime calls beyond plain memory access.
    static func recordSignal(_ signal: Int32, faultAddress: UInt) {
        guard CrashState.isPrepared, CrashState.exceptionRecorded == 0 else { return }
        let count = backtrace(CrashState.frames, maxFrames)
        CrashState.writeSignalFile(signal: signal, faultAddress: faultAddress, frameCount: Int(count))
    }

    /// Writes the crash file for an uncaught Objective-C exception. This runs before the
    /// process aborts, outside a signal handler, so Foundation is still usable.
    static func recordException(name: String, reason: String?, addresses: [UInt], symbols: [String]) {
        guard CrashState.isPrepared else { return }
        CrashState.exceptionRecorded = 1   // the abort() that follows shouldn't write a second file
        var record = CrashState.staticDictionary
        record["format"] = 1
        record["source"] = "exception"
        record["exception_type"] = name
        record["message"] = reason ?? ""
        record["timestamp"] = Int(time(nil))
        record["uptime_seconds"] = Int(time(nil) - CrashState.startTime)
        record["thread"] = currentThreadName()
        record["frames"] = addresses.map { "0x" + String($0, radix: 16) }
        record["symbols"] = symbols
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        let url = CrashState.directory.appending(path: "\(Int(time(nil)))-exception.json")
        try? data.write(to: url, options: .atomic)
    }

    static func currentThreadName() -> String {
        if pthread_main_np() != 0 { return "main" }
        var buffer = [CChar](repeating: 0, count: 64)
        pthread_getname_np(pthread_self(), &buffer, buffer.count)
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.isEmpty ? "thread \(pthread_mach_thread_np(pthread_self()))" : name
    }

    /// The fields known at launch: versions, where the app's code was loaded (so the next
    /// launch can name its frames), the boot (system frames are only nameable in the same
    /// boot), and the log file. Paths under the home folder are written with `~`.
    private static func staticFields(version: AppVersion, logFile: URL?) -> [String: Any] {
        let image = MainImage.current
        var fields: [String: Any] = [
            "app_version": version.marketing, "app_build": version.build,
            "image_base": "0x" + String(image.base, radix: 16), "image_size": image.size,
            "image_uuid": image.uuid, "boot_time": MainImage.bootTime,
        ]
        if let logFile { fields["log_file"] = logFile.path }
        return fields
    }
}

/// The signal handler. Marked nonisolated and capture-free, so it's a plain C function.
nonisolated private func crashSignalHandler(_ signal: Int32, _ info: UnsafeMutablePointer<__siginfo>?, _ context: UnsafeMutableRawPointer?) {
    let address = info.map { UInt(bitPattern: $0.pointee.si_addr) } ?? 0
    CrashCapture.recordSignal(signal, faultAddress: address)
    // SA_RESETHAND restored the default action; raising again lets macOS record the crash.
    raise(signal)
}

/// Pre-allocated crash-time state.
nonisolated private enum CrashState {
    nonisolated(unsafe) static var isPrepared = false
    nonisolated(unsafe) static var exceptionRecorded: sig_atomic_t = 0
    nonisolated(unsafe) static var startTime: time_t = time(nil)
    nonisolated(unsafe) static var directory = URL(filePath: "/tmp")
    nonisolated(unsafe) static var staticDictionary: [String: Any] = [:]

    nonisolated(unsafe) static var frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(CrashCapture.maxFrames))
    /// "<directory>/" as a C string.
    nonisolated(unsafe) static var directoryPath = UnsafeMutablePointer<CChar>.allocate(capacity: 1)
    nonisolated(unsafe) static var directoryLength = 0
    /// `,"app_version":…}` — the static fields as the tail of a JSON object.
    nonisolated(unsafe) static var staticTail = UnsafeMutablePointer<CChar>.allocate(capacity: 1)
    nonisolated(unsafe) static var staticTailLength = 0
    nonisolated(unsafe) static var path = UnsafeMutablePointer<CChar>.allocate(capacity: 2048)
    nonisolated(unsafe) static var finalPath = UnsafeMutablePointer<CChar>.allocate(capacity: 2048)
    nonisolated(unsafe) static var number = UnsafeMutablePointer<UInt8>.allocate(capacity: 32)
    nonisolated(unsafe) static var threadName = UnsafeMutablePointer<CChar>.allocate(capacity: 64)

    static func prepare(directory: URL, staticFields: [String: Any]) {
        self.directory = directory
        staticDictionary = staticFields
        startTime = time(nil)
        exceptionRecorded = 0

        let dir = Array((directory.path + "/").utf8CString)
        directoryPath = UnsafeMutablePointer<CChar>.allocate(capacity: dir.count)
        directoryPath.initialize(from: dir, count: dir.count)
        directoryLength = dir.count - 1

        var json = (try? JSONSerialization.data(withJSONObject: staticFields, options: [.sortedKeys])) ?? Data("{}".utf8)
        json.removeFirst()   // drop "{", keeping the closing "}"
        let tail = Array(("," + String(decoding: json, as: UTF8.self)).utf8CString)
        staticTail = UnsafeMutablePointer<CChar>.allocate(capacity: tail.count)
        staticTail.initialize(from: tail, count: tail.count)
        staticTailLength = tail.count - 1

        // backtrace() can allocate the first time it runs; get that out of the way now.
        _ = backtrace(frames, 1)
        isPrepared = true
    }

    static func writeSignalFile(signal: Int32, faultAddress: UInt, frameCount: Int) {
        let now = time(nil)
        // <dir>/<timestamp>-<signal>.json, written to .tmp then renamed so a half-written
        // file is never read.
        var length = 0
        append(directoryPath, directoryLength, to: path, at: &length)
        appendNumber(UInt(now), to: path, at: &length)
        appendLiteral("-", to: path, at: &length)
        appendNumber(UInt(signal), to: path, at: &length)
        appendLiteral(".json", to: path, at: &length)
        memcpy(finalPath, path, length)
        finalPath[length] = 0
        appendLiteral(".tmp", to: path, at: &length)
        path[length] = 0

        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return }
        put(fd, "{\"format\":1,\"source\":\"signal\",\"exception_type\":\"")
        put(fd, exceptionType(signal))
        put(fd, "\",\"signal_name\":\"")
        put(fd, signalName(signal))
        put(fd, "\",\"signal\":")
        putNumber(fd, UInt(signal))
        put(fd, ",\"message\":\"")
        put(fd, message(signal))
        if signal == SIGSEGV || signal == SIGBUS {
            put(fd, " at 0x")
            putHex(fd, faultAddress)
        }
        put(fd, "\",\"timestamp\":")
        putNumber(fd, UInt(now))
        put(fd, ",\"uptime_seconds\":")
        putNumber(fd, UInt(max(now - startTime, 0)))
        put(fd, ",\"thread\":\"")
        putThreadName(fd)
        put(fd, "\",\"frames\":[")
        for i in 0..<frameCount {
            if i > 0 { put(fd, ",") }
            put(fd, "\"0x")
            putHex(fd, UInt(bitPattern: frames[i]))
            put(fd, "\"")
        }
        put(fd, "]")
        _ = write(fd, staticTail, staticTailLength)
        close(fd)
        rename(path, finalPath)
    }

    private static func put(_ fd: Int32, _ text: StaticString) {
        _ = write(fd, text.utf8Start, text.utf8CodeUnitCount)
    }

    private static func putNumber(_ fd: Int32, _ value: UInt) {
        var length = 0
        var v = value
        repeat { number[length] = UInt8(48 + v % 10); v /= 10; length += 1 } while v > 0
        for i in 0..<(length / 2) { let t = number[i]; number[i] = number[length - 1 - i]; number[length - 1 - i] = t }
        _ = write(fd, number, length)
    }

    private static func putHex(_ fd: Int32, _ value: UInt) {
        var length = 0
        var v = value
        repeat {
            let digit = UInt8(v & 0xF)
            number[length] = digit < 10 ? 48 + digit : 87 + digit
            v >>= 4
            length += 1
        } while v > 0
        for i in 0..<(length / 2) { let t = number[i]; number[i] = number[length - 1 - i]; number[length - 1 - i] = t }
        _ = write(fd, number, length)
    }

    /// The thread's name, keeping only characters that are safe inside a JSON string.
    private static func putThreadName(_ fd: Int32) {
        if pthread_main_np() != 0 { put(fd, "main"); return }
        threadName[0] = 0
        pthread_getname_np(pthread_self(), threadName, 64)
        var length = 0
        while length < 63, threadName[length] != 0 {
            let c = UInt8(bitPattern: threadName[length])
            let safe = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 32 || c == 46 || c == 45 || c == 95
            if !safe { threadName[length] = 95 }   // "_"
            length += 1
        }
        if length == 0 { put(fd, "thread"); return }
        _ = write(fd, threadName, length)
    }

    private static func append(_ source: UnsafePointer<CChar>, _ count: Int, to buffer: UnsafeMutablePointer<CChar>, at length: inout Int) {
        guard length + count < 2000 else { return }
        memcpy(buffer + length, source, count)
        length += count
    }

    private static func appendLiteral(_ text: StaticString, to buffer: UnsafeMutablePointer<CChar>, at length: inout Int) {
        text.utf8Start.withMemoryRebound(to: CChar.self, capacity: text.utf8CodeUnitCount) {
            append($0, text.utf8CodeUnitCount, to: buffer, at: &length)
        }
    }

    private static func appendNumber(_ value: UInt, to buffer: UnsafeMutablePointer<CChar>, at length: inout Int) {
        var digits = 0
        var v = value
        repeat { number[digits] = UInt8(48 + v % 10); v /= 10; digits += 1 } while v > 0
        for i in stride(from: digits - 1, through: 0, by: -1) where length < 2000 {
            buffer[length] = CChar(bitPattern: number[i])
            length += 1
        }
    }

    private static func exceptionType(_ signal: Int32) -> StaticString {
        switch signal {
        case SIGSEGV, SIGBUS: "EXC_BAD_ACCESS"
        case SIGTRAP: "EXC_BREAKPOINT"
        case SIGILL: "EXC_BAD_INSTRUCTION"
        case SIGFPE: "EXC_ARITHMETIC"
        case SIGABRT: "EXC_CRASH"
        default: "EXC_CRASH"
        }
    }

    private static func signalName(_ signal: Int32) -> StaticString {
        switch signal {
        case SIGSEGV: "SIGSEGV"
        case SIGBUS: "SIGBUS"
        case SIGTRAP: "SIGTRAP"
        case SIGILL: "SIGILL"
        case SIGFPE: "SIGFPE"
        case SIGABRT: "SIGABRT"
        default: "SIGNAL"
        }
    }

    private static func message(_ signal: Int32) -> StaticString {
        switch signal {
        case SIGSEGV, SIGBUS: "Bad memory access"
        case SIGTRAP: "Swift runtime trap: a force-unwrapped nil, an out-of-range index, a failed precondition or fatalError"
        case SIGILL: "Illegal instruction"
        case SIGFPE: "Arithmetic exception"
        case SIGABRT: "The app called abort()"
        default: "Fatal signal"
        }
    }
}

/// Where the app's own code is loaded in this process.
nonisolated struct MainImage: Sendable {
    let base: UInt
    let size: Int
    let uuid: String

    static let current: MainImage = {
        guard let header = _dyld_get_image_header(0) else { return MainImage(base: 0, size: 0, uuid: "") }
        let base = UInt(bitPattern: header)
        var size = 0
        var uuid = ""
        header.withMemoryRebound(to: mach_header_64.self, capacity: 1) { h in
            var command = UnsafeRawPointer(h).advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<h.pointee.ncmds {
                let lc = command.load(as: load_command.self)
                if lc.cmd == UInt32(LC_SEGMENT_64) {
                    let segment = command.load(as: segment_command_64.self)
                    let name = withUnsafeBytes(of: segment.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                    if name == "__TEXT" { size = Int(segment.vmsize) }
                } else if lc.cmd == UInt32(LC_UUID) {
                    let bytes = command.load(as: uuid_command.self).uuid
                    uuid = UUID(uuid: bytes).uuidString
                }
                command = command.advanced(by: Int(lc.cmdsize))
            }
        }
        return MainImage(base: base, size: size, uuid: uuid)
    }()

    /// Seconds since 1970 at which the Mac last booted.
    static var bootTime: Int {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return 0 }
        return Int(boot.tv_sec)
    }

    func contains(_ address: UInt) -> Bool { address >= base && address < base + UInt(size) }
}

// MARK: - Crash file

/// A crash file, as written by `CrashCapture`.
nonisolated struct CrashRecord: Codable, Sendable, Equatable {
    var format: Int = 1
    var source: String
    var exceptionType: String
    var signalName: String?
    var message: String?
    var timestamp: Int
    var uptimeSeconds: Int
    var thread: String
    var frames: [String]
    var symbols: [String]?
    var appVersion: String
    var appBuild: String
    var imageBase: String
    var imageSize: Int
    var imageUUID: String
    var bootTime: Int
    var logFile: String?

    enum CodingKeys: String, CodingKey {
        case format, source, message, timestamp, thread, frames, symbols
        case exceptionType = "exception_type", signalName = "signal_name", uptimeSeconds = "uptime_seconds"
        case appVersion = "app_version", appBuild = "app_build", imageBase = "image_base", imageSize = "image_size"
        case imageUUID = "image_uuid", bootTime = "boot_time", logFile = "log_file"
    }
}

// MARK: - Building the report (next launch)

/// One stack frame, named where possible.
nonisolated struct CrashFrame: Sendable, Equatable {
    let image: String
    /// Demangled symbol, without its offset.
    let symbol: String?
    /// Offset from the start of the image, for app frames that couldn't be named.
    let imageOffset: UInt?
    let isApp: Bool

    /// The frame with addresses and offsets removed, for the fingerprint.
    var fingerprintKey: String { symbol ?? "\(image)+0x\(String(imageOffset ?? 0, radix: 16))" }
    var text: String { "\(image)  \(symbol ?? (imageOffset.map { "+0x" + String($0, radix: 16) } ?? "???"))" }
}

nonisolated enum CrashReportBuilder {
    static let appImageName = "KalshiBot"
    static let logLineLimit = 300
    static let logByteLimit = 100_000

    /// Names each frame: app frames through this build's symbols when the crashed build is
    /// this one, system frames only within the same boot (their addresses are stable then).
    static func frames(for record: CrashRecord, current: MainImage = .current, bootTime: Int = MainImage.bootTime) -> [CrashFrame] {
        if let symbols = record.symbols, !symbols.isEmpty {
            return symbols.map(parseSymbolLine)
        }
        let oldBase = UInt(record.imageBase.dropFirst(2), radix: 16) ?? 0
        let oldImage = MainImage(base: oldBase, size: record.imageSize, uuid: record.imageUUID)
        let sameBuild = !record.imageUUID.isEmpty && record.imageUUID == current.uuid
        var frames = record.frames.compactMap { UInt($0.dropFirst(2), radix: 16) }.map { address -> CrashFrame in
            if oldImage.contains(address) {
                let offset = address - oldBase
                let symbol = sameBuild ? symbolName(at: current.base + offset) : nil
                return CrashFrame(image: appImageName, symbol: symbol, imageOffset: offset, isApp: true)
            }
            if record.bootTime == bootTime, let (image, symbol) = systemSymbol(at: address) {
                return CrashFrame(image: image, symbol: symbol, imageOffset: nil, isApp: false)
            }
            return CrashFrame(image: "?", symbol: nil, imageOffset: nil, isApp: false)
        }
        // Drop the handler's own frames, up to and including the signal trampoline.
        if let tramp = frames.firstIndex(where: { $0.symbol == "_sigtramp" }) {
            frames.removeFirst(tramp + 1)
        } else {
            while let first = frames.first, first.symbol?.contains("crashSignalHandler") == true
                    || first.symbol?.contains("CrashCapture") == true || first.symbol?.contains("CrashState") == true {
                frames.removeFirst()
            }
        }
        return frames
    }

    /// SHA-256 of the exception type and the first five app frames (or any frames, if
    /// none are the app's), with addresses stripped — repeats of one crash share it.
    static func fingerprint(exceptionType: String, frames: [CrashFrame]) -> String {
        let app = frames.filter(\.isApp)
        let keys = (app.isEmpty ? frames : app).prefix(5).map(\.fingerprintKey)
        let text = ([exceptionType] + keys).joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The report for a crash file. The app and device context are the crashed build's
    /// and this Mac's; `ReportClient.prepared` fills in anything missing.
    static func build(record: CrashRecord, installID: String, device: DeviceInfo, settings: [String: String],
                      current: MainImage = .current, bootTime: Int = MainImage.bootTime) -> Report {
        let frames = frames(for: record, current: current, bootTime: bootTime)
        let innermost = frames.first(where: \.isApp).map { shortName($0.symbol ?? $0.text) }
        let title = innermost.map { "\(record.exceptionType) in \($0)" } ?? record.exceptionType
        let signal = record.signalName.map { " (\($0))" } ?? ""
        let stack = frames.prefix(20).enumerated().map { "\($0.offset)  \($0.element.text)" }.joined(separator: "\n")
        let description = Scrubber.scrub("""
            \(record.exceptionType)\(signal): \(record.message ?? "")
            Thread: \(record.thread) · up \(record.uptimeSeconds)s · Kalshi Bot \(record.appVersion) (\(record.appBuild))

            \(stack)
            """)
        let logs = record.logFile.map { path in
            Scrubber.scrub(AppLog.tail(of: URL(filePath: path), lines: logLineLimit, maxBytes: logByteLimit).joined(separator: "\n"))
        } ?? ""
        let critical = frames.contains { frame in
            let s = (frame.symbol ?? "").lowercased()
            return s.contains("save") || s.contains("migrat") || s.contains("persistentstore")
        }
        var metadata: [String: JSONValue] = [
            "uptime_seconds": .number(Double(record.uptimeSeconds)),
            "thread": .string(record.thread),
            "source": .string(record.source),
            "crashed_at": .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(record.timestamp)))),
            "settings": .object(settings.mapValues(JSONValue.string)),
        ]
        if let name = record.signalName { metadata["signal"] = .string(name) }
        return Report(kind: .crash, severity: critical ? .critical : .high, title: Scrubber.scrub(title),
                      description: description, appVersion: record.appVersion, appBuild: record.appBuild,
                      osVersion: device.osVersion, device: device.model, locale: device.locale, installID: installID,
                      contact: nil, logs: Report.suffix(logs, maxBytes: logByteLimit),
                      fingerprint: fingerprint(exceptionType: record.exceptionType, frames: frames), metadata: metadata)
    }

    /// "KalshiBot.LivePriceFeed.reconnect() async -> ()" → "LivePriceFeed.reconnect() async".
    static func shortName(_ symbol: String) -> String {
        var name = symbol
        if let range = name.range(of: " in ", options: .backwards) { name = String(name[range.upperBound...]) }
        if let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
        return name.replacingOccurrences(of: "\(appImageName).", with: "")
    }

    /// One line of `callStackSymbols`: "3   KalshiBot   0x0000000102f3c8a4 $s9KalshiBot…  + 132".
    private static func parseSymbolLine(_ line: String) -> CrashFrame {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 4 else { return CrashFrame(image: "?", symbol: line, imageOffset: nil, isApp: false) }
        var symbolParts = Array(parts[3...])
        if symbolParts.count >= 2, symbolParts[symbolParts.count - 2] == "+" { symbolParts.removeLast(2) }
        let image = parts[1]
        return CrashFrame(image: image, symbol: demangle(symbolParts.joined(separator: " ")), imageOffset: nil, isApp: image == appImageName)
    }

    private static func symbolName(at address: UInt) -> String? {
        var info = Dl_info()
        guard let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0, let name = info.dli_sname else { return nil }
        return demangle(String(cString: name))
    }

    private static func systemSymbol(at address: UInt) -> (String, String?)? {
        var info = Dl_info()
        guard let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0 else { return nil }
        let image = info.dli_fname.map { URL(filePath: String(cString: $0)).lastPathComponent } ?? "?"
        return (image, info.dli_sname.map { demangle(String(cString: $0)) })
    }

    static func demangle(_ symbol: String) -> String {
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") || symbol.hasPrefix("$S") else { return symbol }
        return symbol.withCString { cString in
            guard let result = _swiftDemangle(cString, strlen(cString), nil, nil, 0) else { return symbol }
            defer { free(result) }
            return String(cString: result)
        }
    }
}

@_silgen_name("swift_demangle")
nonisolated private func _swiftDemangle(_ mangledName: UnsafePointer<CChar>, _ length: Int,
                                         _ outputBuffer: UnsafeMutablePointer<CChar>?, _ outputBufferSize: UnsafeMutablePointer<Int>?,
                                         _ flags: UInt32) -> UnsafeMutablePointer<CChar>?

/// Masks secrets and personal details: API keys, bearer tokens, passwords, e-mail
/// addresses, the home folder and the user name.
nonisolated enum Scrubber {
    private static let rules: [(NSRegularExpression, String)] = ([
        (#"itt_[A-Za-z0-9_\-]{8,}"#, "itt_[REDACTED]"),
        (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=\-]+"#, "Bearer [REDACTED]"),
        (#"(?i)\b(x-api-key|api[_-]?key|apikey|token|access[_-]?token|secret|password|passwd|pwd)(\s*[:=]\s*)("[^"]*"|'[^']*'|\S+)"#, "$1$2[REDACTED]"),
        (#"(?i)\b(sk|pk|rk)_(live|test)_[A-Za-z0-9]{8,}"#, "[REDACTED_KEY]"),
        (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "[EMAIL]"),
    ] as [(String, String)]).compactMap { pattern, template in (try? NSRegularExpression(pattern: pattern)).map { ($0, template) } }

    static func scrub(_ text: String, home: String = realHomeDirectory, userName: String = NSUserName()) -> String {
        var result = text
        if !home.isEmpty { result = result.replacingOccurrences(of: home, with: "~") }
        for (regex, template) in rules {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        if userName.count >= 3 {
            result = result.replacingOccurrences(of: userName, with: "[USER]")
        }
        return result
    }

    /// The real home folder (in the sandbox, NSHomeDirectory() is the app's container).
    static var realHomeDirectory: String {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: dir)
    }
}

// MARK: - Collecting (next launch)

/// Turns crash files left by an earlier launch into reports in the outbox — when the
/// user has opted in, or chose to send them from the crash prompt.
final class CrashReports {
    static let maxFiles = 20

    private let directory: URL
    private let defaults: UserDefaults
    private let device: DeviceInfo
    private let current: MainImage
    private let settings: () -> [String: String]

    init(directory: URL = CrashCapture.defaultDirectory, defaults: UserDefaults = .standard, device: DeviceInfo = .current,
         current: MainImage = .current, settings: @escaping () -> [String: String] = { [:] }) {
        self.directory = directory
        self.defaults = defaults
        self.device = device
        self.current = current
        self.settings = settings
    }

    /// Crash files waiting, oldest first, after capping the folder at 20.
    func pendingFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        // Leftover half-written files are useless.
        for tmp in files where tmp.pathExtension == "tmp" { try? FileManager.default.removeItem(at: tmp) }
        let crashes = files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in crashes.dropLast(Self.maxFiles) { try? FileManager.default.removeItem(at: old) }
        return Array(crashes.suffix(Self.maxFiles))
    }

    var hasPending: Bool { !pendingFiles().isEmpty }

    /// Builds a report from each crash file, puts it in `client`'s outbox and deletes the
    /// file. Does nothing unless automatic reports are on or `force` is set (the user
    /// chose Send). Returns how many were queued.
    @discardableResult
    func collect(into client: ReportClient, force: Bool = false) -> Int {
        guard force || ReportClient.automaticReportsEnabled(defaults), client.isConfigured else { return 0 }
        var count = 0
        for file in pendingFiles() {
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(CrashRecord.self, from: data) else { continue }
            client.enqueue(CrashReportBuilder.build(record: record, installID: InstallIdentity.id(in: defaults),
                                                    device: device, settings: settings(), current: current))
            count += 1
        }
        return count
    }

    /// Don't send: deletes the waiting crash files.
    func discardPending() {
        for file in pendingFiles() { try? FileManager.default.removeItem(at: file) }
    }
}

nonisolated extension AppLog {
    /// The last lines of already-loaded log text.
    static func tailText(_ text: String, lines count: Int, maxBytes: Int) -> String {
        var lines = Array(text.split(separator: "\n").suffix(count).map(String.init))
        while !lines.isEmpty, lines.joined(separator: "\n").utf8.count > maxBytes { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }
}
