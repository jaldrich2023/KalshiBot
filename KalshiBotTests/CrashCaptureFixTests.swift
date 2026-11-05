//
//  CrashCaptureFixTests.swift
//  KalshiBotTests
//
//  Crash capture and report building: prepared buffers, the faulting PC, stripped
//  builds, the scrubber's edge cases and lenient log decoding.
//

import Foundation
import Testing
@testable import KalshiBot

/// Serialized: crash capture keeps process-wide state.
@MainActor @Suite(.serialized)
struct CrashCaptureFixTests {
    private let version = AppVersion(marketing: "2.27.0", build: "48", copyright: "")

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "CrashCaptureFixTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func crashFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    // MARK: Capture

    @Test func preparedBuffersWriteThePCFirstAndOnlyOnce() throws {
        let directory = tempDirectory()
        CrashCapture.install(directory: directory, version: version, logFile: nil, installHandlers: false)
        #expect(CrashCapture.recordSignal(SIGBUS, faultAddress: 0x20, pc: 0xabc123))

        let file = try #require(crashFiles(in: directory).first)
        let record = try JSONDecoder().decode(CrashRecord.self, from: Data(contentsOf: file))
        #expect(record.signalName == "SIGBUS")
        #expect(record.message == "Bad memory access at 0x20")
        #expect(record.firstFrameIsPC == true)
        #expect(record.frames.first == "0xabc123")
        #expect(record.frames.count > 1)

        // The buffers are claimed: a second crash (another thread) doesn't write over them.
        #expect(!CrashCapture.recordSignal(SIGSEGV, faultAddress: 0, pc: 0))
        #expect(crashFiles(in: directory).count == 1)
    }

    @Test func oldCrashFilesStillDecode() throws {
        let json = #"""
            {"format":1,"source":"signal","exception_type":"EXC_CRASH","signal_name":"SIGABRT","message":"x",
             "timestamp":1,"uptime_seconds":2,"thread":"main","frames":["0x1"],"app_version":"2.26.0",
             "app_build":"47","image_base":"0x0","image_size":0,"image_uuid":"","boot_time":0}
            """#
        let record = try JSONDecoder().decode(CrashRecord.self, from: Data(json.utf8))
        #expect(record.firstFrameIsPC == nil && record.handlerFramesRemoved == nil)
    }

    @Test func theAppImageIsTheOneHoldingTheAppsCode() {
        #expect(MainImage.current.size > 0 && !MainImage.current.uuid.isEmpty)
        #expect(CrashReportBuilder.isAppImage("KalshiBot"))
        #expect(CrashReportBuilder.isAppImage("KalshiBot.debug.dylib"))
        #expect(!CrashReportBuilder.isAppImage("CoreFoundation"))
    }

    // MARK: Stripped builds

    /// An exception crash from a stripped build, the app loaded at `base`.
    private func strippedRecord(base: UInt) -> CrashRecord {
        let offsets: [UInt] = [0xc8a4, 0x10]
        let addresses = offsets.map { base + $0 }
        func hex(_ value: UInt) -> String { "0x" + String(value, radix: 16) }
        return CrashRecord(source: "exception", exceptionType: "NSRangeException", signalName: nil, message: "out of range",
                           timestamp: 0, uptimeSeconds: 1, thread: "main", frames: addresses.map(hex),
                           symbols: [
                               "1   KalshiBot   \(hex(addresses[0])) KalshiBot + \(offsets[0])",
                               "2   KalshiBot   \(hex(addresses[1])) \(hex(base)) + \(offsets[1])",
                           ],
                           appVersion: "2.27.0", appBuild: "48", imageBase: hex(base), imageSize: 0x100000,
                           imageUUID: "STRIPPED-BUILD", bootTime: 1, logFile: nil)
    }

    @Test func strippedLinesAreNamedByImageOffset() {
        let frame = CrashReportBuilder.parseSymbolLine("1   KalshiBot   0x0000000102f3c8a4 KalshiBot + 51364",
                                                       image: MainImage(base: 0x1_02f3_0000, size: 0x100000, uuid: ""))
        #expect(frame.symbol == nil)
        #expect(frame.isApp)
        #expect(frame.imageOffset == 51364)
        #expect(frame.fingerprintKey == "KalshiBot+0xc8a4")

        // Without a recorded base, the line's own offset is used.
        #expect(CrashReportBuilder.parseSymbolLine("1   KalshiBot   0x0000000102f3c8a4 _mh_execute_header + 51364").imageOffset == 51364)

        let current = MainImage(base: 0x7000_0000_0000, size: 0x100000, uuid: "NEW-BUILD")
        let frames = CrashReportBuilder.frames(for: strippedRecord(base: 0x1_02f3_0000), current: current, bootTime: 2)
        #expect(frames.map(\.imageOffset) == [0xc8a4, 0x10])
        #expect(frames.allSatisfy { $0.symbol == nil && $0.isApp })
        // No absolute (load-address-dependent) value in any key: the image was loaded at
        // 0x102f30000, so its digits must not appear.
        #expect(frames.allSatisfy { !$0.fingerprintKey.contains("102f3") })
    }

    @Test func strippedCrashesShareAFingerprintAcrossLaunches() {
        let current = MainImage(base: 0x7000_0000_0000, size: 0x100000, uuid: "NEW-BUILD")
        func fingerprintOf(_ r: CrashRecord) -> String {
            CrashReportBuilder.fingerprint(exceptionType: r.exceptionType,
                                           frames: CrashReportBuilder.frames(for: r, current: current, bootTime: 2))
        }
        #expect(fingerprintOf(strippedRecord(base: 0x1_02f3_0000)) == fingerprintOf(strippedRecord(base: 0x1_0450_0000)))

        let device = DeviceInfo(osVersion: "macOS 27.2", model: "Mac16,10", locale: "en_US", timeZone: "America/Chicago")
        let report = CrashReportBuilder.build(record: strippedRecord(base: 0x1_02f3_0000), installID: "id", device: device,
                                              settings: [:], current: current, bootTime: 2)
        #expect(!report.title.contains("_mh_execute_header"))
        #expect(!report.title.contains("0x102f3"))
    }

    @Test func headerAndFarAwayMainAreNotSymbols() {
        let image = MainImage(base: 0x1_0000_0000, size: 0x100000, uuid: "")
        #expect(!CrashReportBuilder.isRealSymbol("_mh_execute_header", start: 0x1_0000_0000, address: 0x1_0000_5000, image: image))
        #expect(!CrashReportBuilder.isRealSymbol("KalshiBot", start: 0x1_0000_1000, address: 0x1_0000_5000, image: image))
        #expect(!CrashReportBuilder.isRealSymbol("main", start: 0x1_0000_1000, address: 0x1_0008_0000, image: image))
        #expect(CrashReportBuilder.isRealSymbol("main", start: 0x1_0000_1000, address: 0x1_0000_1010, image: image))
        #expect(CrashReportBuilder.isRealSymbol("$s9KalshiBot4mainyyF", start: 0x1_0000_1000, address: 0x1_0000_1010, image: image))
    }

    // MARK: Scrubbing and logs

    @Test func shortUserNamesDontMangleWordsButPathsAreStillMasked() {
        let clean = Scrubber.scrub("device error in /Users/dev/Library/x for dev", home: "", userName: "dev")
        #expect(clean.contains("device error"))
        #expect(clean.contains("/Users/[USER]/Library/x"))

        // Longer names: whole words only.
        let long = Scrubber.scrub("testers and tester", home: "", userName: "tester")
        #expect(long == "testers and [USER]")
    }

    @Test func swiftSignaturesAreNotTakenForSecrets() {
        let signatures = "KalshiBot.Client.fetch(token: Swift.String) and save(secret: Data, password: Foundation.Data?)"
        #expect(Scrubber.scrub(signatures, home: "", userName: "") == signatures)
        // Real values still are.
        let values = Scrubber.scrub("token=abc123, password: hunter2) secret = 'xyz'", home: "", userName: "")
        for secret in ["abc123", "hunter2", "xyz"] { #expect(!values.contains(secret), "still contains \(secret)") }
    }

    @Test func logTailSurvivesACutMultibyteCharacter() throws {
        let url = tempDirectory().appending(path: "launch.log")
        var data = Data("line 1\nline 2 caf".utf8)
        data.append(0xC3)   // the first half of "é", cut by a crash
        try data.write(to: url)
        let tail = AppLog.tail(of: url, lines: 10, maxBytes: 10_000)
        #expect(tail.count == 2)
        #expect(tail.first == "line 1")
    }
}
