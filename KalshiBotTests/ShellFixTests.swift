//
//  ShellFixTests.swift
//  KalshiBotTests
//
//  The report outbox's refusals, age limit and opt-out, the form's resend, and Check
//  for Updates… after a dismissal.
//

import Foundation
import Testing
@testable import KalshiBot

@MainActor
struct OutboxFixTests {
    private let defaults = UserDefaults(suiteName: "OutboxFixTests.\(UUID().uuidString)")!
    private let device = DeviceInfo(osVersion: "macOS 27.2", model: "Mac16,10", locale: "en_US", timeZone: "America/Chicago")
    private let outbox = FileManager.default.temporaryDirectory.appending(path: "OutboxFixTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func client(_ transport: StubInstallTransport, now: Date = Date(timeIntervalSince1970: 1_762_200_000)) -> ReportClient {
        ReportClient(config: BackendConfig(baseURL: URL(string: "https://example.test")!, apiKey: "itt_test"), transport: transport,
                     defaults: defaults, version: AppVersion(marketing: "2.27.1", build: "49", copyright: ""),
                     device: device, outbox: outbox, now: { now })
    }

    private func crash() -> Report { Report(kind: .crash, severity: .high, title: "EXC_BAD_ACCESS in Foo.bar()") }

    @Test(arguments: [400, 403, 404, 422])
    func invalidReportsAreDroppedNotRetried(_ status: Int) async {
        let transport = StubInstallTransport([.status(status)])
        #expect(await client(transport).send(Report(kind: .bug, title: "Bad")) == .rejected(status: status))
        #expect(client(transport).queued().isEmpty)
    }

    @Test func aTimeoutIsRetried() async {
        let transport = StubInstallTransport([.status(408)])
        let result = await client(transport).send(Report(kind: .bug, title: "Slow"))
        guard case .queued = result else { Issue.record("expected queued, got \(result)"); return }
        #expect(client(transport).queued().count == 1)
    }

    @Test func automaticReportsQueuedBeforeAnOptOutAreNotSent() async {
        defaults.set(true, forKey: ReportClient.automaticReportsKey)
        client(StubInstallTransport([])).enqueue(crash())
        defaults.set(false, forKey: ReportClient.automaticReportsKey)
        let transport = StubInstallTransport([.status(201)])
        #expect(await client(transport).flush(respectingBackoff: false).isEmpty)
        #expect(transport.count == 0)
        #expect(client(transport).queued().isEmpty)
    }

    @Test func aCrashTheUserChoseToSendGoesEvenWithAutomaticReportsOff() async {
        client(StubInstallTransport([])).enqueue(crash(), userApproved: true)
        let transport = StubInstallTransport([.status(201)])
        #expect(await client(transport).flush(respectingBackoff: false) == [.sent(id: nil)])
        #expect(transport.count == 1)
    }

    @Test func userReportsGoWithAutomaticReportsOff() async {
        client(StubInstallTransport([])).enqueue(Report(kind: .feedback, title: "Nice"))
        let transport = StubInstallTransport([.status(201)])
        #expect(await client(transport).flush(respectingBackoff: false) == [.sent(id: nil)])
    }

    @Test func reportsOlderThanThirtyDaysAreDropped() async {
        let start = Date(timeIntervalSince1970: 1_762_200_000)
        client(StubInstallTransport([]), now: start).enqueue(Report(kind: .bug, title: "Old"))
        let transport = StubInstallTransport([.status(201)])
        #expect(await client(transport, now: start.addingTimeInterval(31 * 86_400)).flush(respectingBackoff: false).isEmpty)
        #expect(transport.count == 0)
        #expect(client(transport).queued().isEmpty)
    }

    @Test func resendRetriesExactlyThatReport() async {
        let mine = Report(kind: .bug, title: "Mine", logs: "line 1")
        let other = Report(kind: .bug, title: "Other")
        client(StubInstallTransport([])).enqueue(other)
        let failing = StubInstallTransport([.status(503)])
        guard case .queued = await client(failing).send(mine) else { Issue.record("expected queued"); return }

        let transport = StubInstallTransport([.status(201, #"{"ok":true,"id":"r_7"}"#)])
        #expect(await client(transport).resend(mine) == .sent(id: "r_7"))
        #expect(transport.count == 1)
        #expect(client(transport).queued().map(\.item.report.title) == ["Other"])
        // Already gone: nothing to resend.
        #expect(await client(transport).resend(mine) == nil)
    }
}

@MainActor
struct UpdateCheckFixTests {
    private let defaults = UserDefaults(suiteName: "UpdateCheckFixTests.\(UUID().uuidString)")!

    private func checker(_ transport: StubInstallTransport) -> UpdateChecker {
        UpdateChecker(defaults: defaults, config: BackendConfig(baseURL: URL(string: "https://example.test")!, apiKey: ""),
                      transport: transport, version: AppVersion(marketing: "2.9.0", build: "1", copyright: ""))
    }

    private func release(_ version: String) -> String {
        #"{"release":{"version":"\#(version)","title":"Kalshi Bot \#(version)","download_url":"https://example.test/dl"}}"#
    }

    @Test func checkForUpdatesShowsADismissedReleaseAgain() async {
        let updates = checker(StubInstallTransport([.status(200, release("2.10.0")), .status(200, release("2.10.0"))]))
        await updates.check()
        updates.dismiss()
        await updates.checkNow()
        #expect(updates.availableUpdate?.version == "2.10.0")
        // Shown as the notice, not as an "up to date" alert.
        #expect(updates.manualResult == nil)
    }

    @Test func upToDateIsReportedForTheAlert() async {
        let updates = checker(StubInstallTransport([.status(200, release("2.9.0"))]))
        await updates.checkNow()
        #expect(updates.manualResult == .upToDate)
        #expect(updates.availableUpdate == nil)
    }
}

struct ReversalWarningTests {
    // $2/√s for 720 s left: 1σ of the movement still to come is about $53.67.
    @Test func closeCallsAreWithinHalfASigmaOrOnTheWrongSide() throws {
        let sigma = 2 * 720.0.squareRoot()
        let close = try #require(ReversalRisk.closeCall(spot: 80_000 + 0.3 * sigma, strike: 80_000, calledUp: true,
                                                        volatility: 2, secondsRemaining: 720))
        #expect(abs(close.cushionSigma - 0.3) < 1e-9)
        #expect(close.pastLossRate == ReversalHistory.closeAtCallLost)
        #expect(!close.onWrongSide)

        let wrongSide = try #require(ReversalRisk.closeCall(spot: 80_010, strike: 80_000, calledUp: false,
                                                            volatility: 2, secondsRemaining: 720))
        #expect(wrongSide.onWrongSide)
        #expect(wrongSide.pastLossRate == ReversalHistory.wrongSideAtCallLost)

        // A comfortable cushion isn't flagged, and nothing is flagged without volatility.
        #expect(ReversalRisk.closeCall(spot: 80_000 + sigma, strike: 80_000, calledUp: true, volatility: 2, secondsRemaining: 720) == nil)
        #expect(ReversalRisk.closeCall(spot: 80_001, strike: 80_000, calledUp: true, volatility: 0, secondsRemaining: 720) == nil)
    }

    private func titles(secondsRemaining: TimeInterval, price: Double) -> [String] {
        ReversalRisk.assess(.init(price: price, strike: 80_000, secondsRemaining: secondsRemaining, volatility: 2)).factors.map(\.title)
    }

    @Test func closeLateInTheWindowWarnsAboutTheFinalMinutes() {
        // 150 s left, $5 above the target: well under 0.5σ.
        #expect(titles(secondsRemaining: 150, price: 80_005).contains("Final minutes, close to the target"))
        #expect(!titles(secondsRemaining: 150, price: 80_005).contains("Close to the target"))
        // Earlier in the window, the ordinary warning.
        #expect(titles(secondsRemaining: 600, price: 80_005).contains("Close to the target"))
        // A big cushion late on: no warning.
        #expect(!titles(secondsRemaining: 150, price: 80_200).contains("Final minutes, close to the target"))
    }
}

@MainActor
struct WaitUntilConfidentTests {
    @Test func aWaitingCallLocksOnceConfidentAndGivesUpAfterPlusTwelve() {
        #expect(BotEngine.waitDecision(probabilityUp: 0.72, level: 0.80, elapsed: 300) == .wait)
        #expect(BotEngine.waitDecision(probabilityUp: 0.81, level: 0.80, elapsed: 300) == .lock)
        // Either side counts: a 19% chance of Up is an 81% Down call.
        #expect(BotEngine.waitDecision(probabilityUp: 0.19, level: 0.80, elapsed: 300) == .lock)
        #expect(BotEngine.waitDecision(probabilityUp: 0.80, level: 0.80, elapsed: 720) == .lock)   // exactly at the level, at +12
        #expect(BotEngine.waitDecision(probabilityUp: 0.95, level: 0.80, elapsed: 726) == .expired)
    }

    private func record(probabilityUp: Double) -> PredictionRecord {
        PredictionRecord(ticker: "KXBTC15M-TEST", openTime: Date(timeIntervalSince1970: 0), closeTime: Date(timeIntervalSince1970: 900),
                         predictedAt: Date(timeIntervalSince1970: 180), strike: 80_000, spotAtPrediction: 80_010,
                         proxyOpenAverage: nil, probabilityUp: probabilityUp, marketYesMid: probabilityUp,
                         features: [.headStart: 0.4], contributions: [.headStart: 0.1], excludedFeatures: [], callDelay: 180)
    }

    @Test func lockingTakesTheModelsViewThenButKeepsTheTrainingSnapshot() {
        let r = record(probabilityUp: 0.62)
        r.waitLevel = 0.80
        #expect(r.isAwaitingCall)
        let locked = Date(timeIntervalSince1970: 400)
        r.lockCall(at: locked, probabilityUp: 0.17, spot: 79_950, yesMid: 0.18, yesBid: 0.17, yesAsk: 0.19,
                   contributions: [.headStart: -0.5])
        #expect(!r.isAwaitingCall)
        #expect(r.lockedAt == locked && r.predictedAt == locked)
        #expect(r.predictedUp == false && r.probabilityUp == 0.17)
        #expect(r.spotAtPrediction == 79_950 && r.marketYesAsk == 0.19)
        #expect(r.contributions[.headStart] == -0.5)
        // The training snapshot and its call time are untouched.
        #expect(r.features[.headStart] == 0.4)
        #expect(r.callDelay == 180)
    }

    @Test func aCallThatNeverLockedIsANoCall() {
        let engine = BotEngine()
        let waiting = record(probabilityUp: 0.70)
        waiting.waitLevel = 0.80
        #expect(engine.isNoCall(waiting))
        let locked = record(probabilityUp: 0.70)
        locked.waitLevel = 0.80
        locked.lockedAt = locked.predictedAt
        #expect(engine.isNoCall(locked) == (engine.minimumCallConfidence > 0.70))
        // Records from before 2.28 (no wait level) are judged by the threshold alone, as before.
        #expect(!record(probabilityUp: 0.70).isAwaitingCall)
    }
}

@MainActor
struct LockTimeTests {
    private func record(lockedAfter seconds: TimeInterval, wait: Double = 0, locked: Bool = true, settled: Bool = true) -> PredictionRecord {
        let open = Date(timeIntervalSince1970: 1_000_000)
        let r = PredictionRecord(ticker: "T\(seconds)-\(wait)-\(locked)-\(settled)", openTime: open, closeTime: open.addingTimeInterval(900),
                                 predictedAt: open.addingTimeInterval(seconds), strike: 1, spotAtPrediction: 1, proxyOpenAverage: nil,
                                 probabilityUp: 0.8, marketYesMid: 0.8, features: [:], contributions: [:], excludedFeatures: [])
        r.waitLevel = wait
        if wait > 0 && locked { r.lockedAt = r.predictedAt }
        if settled { r.actualUp = true }
        return r
    }

    @Test func offsetsReadAsMinutesAndSeconds() {
        #expect(PredictionRecord.offsetText(180) == "+3:00")
        #expect(PredictionRecord.offsetText(372.4) == "+6:12")
        #expect(PredictionRecord.offsetText(-5) == "+0:00")
    }

    @Test func theAverageCountsSettledCallsThatLocked() throws {
        let calls = [
            record(lockedAfter: 180),                                 // no wait, at the call time
            record(lockedAfter: 420, wait: 0.8),                      // waited, locked at +7
            record(lockedAfter: 180, wait: 0.8, locked: false),       // never locked: left out
            record(lockedAfter: 600, settled: false),                 // not settled yet: left out
        ]
        let lock = try #require(PredictionRecord.averageLock(calls))
        #expect(lock.seconds == 300)
        #expect(lock.calls == 2)
        #expect(lock.waited == 1)
        #expect(PredictionRecord.averageLock([]) == nil)
    }
}

@MainActor
struct SimilarCallZoneTests {
    private func call(_ i: Int, confidence: Double, up: Bool = true, lockedAfter: TimeInterval, distance: Double, settled: Bool = true) -> PredictionRecord {
        let open = Date(timeIntervalSince1970: 1_000_000 + Double(i) * 900)
        let strike = 80_000.0
        let r = PredictionRecord(ticker: "W\(i)", openTime: open, closeTime: open.addingTimeInterval(900),
                                 predictedAt: open.addingTimeInterval(lockedAfter), strike: strike,
                                 spotAtPrediction: strike + (up ? distance : -distance), proxyOpenAverage: nil,
                                 probabilityUp: up ? confidence : 1 - confidence, marketYesMid: nil,
                                 features: [:], contributions: [:], excludedFeatures: [])
        if settled { r.actualUp = up }
        return r
    }

    @Test func quartilesInterpolate() {
        #expect(PredictionRecord.quartile([1, 2, 3, 4, 5], 0.25) == 2)
        #expect(PredictionRecord.quartile([1, 2, 3, 4], 0.75) == 3.25)
        #expect(PredictionRecord.quartile([7], 0.25) == 7)
    }

    @Test func theZoneIsTheMiddleHalfOfSimilarCalls() throws {
        // Twelve settled 72% calls, Up and Down, locked at +3:00…+3:55, $10…$65 on the called side.
        var past = (0..<12).map { i in
            call(i, confidence: 0.72, up: i % 2 == 0, lockedAfter: 180 + Double(i) * 5, distance: 10 + Double(i) * 5)
        }
        past.append(call(50, confidence: 0.91, lockedAfter: 600, distance: 300))            // another band: ignored
        past.append(call(51, confidence: 0.73, lockedAfter: 180, distance: 20, settled: false)) // not settled: ignored
        let current = call(99, confidence: 0.74, lockedAfter: 200, distance: 15)
        let zone = try #require(PredictionRecord.similarCallZone(for: current, in: past + [current]))
        #expect(zone.count == 12)
        #expect(zone.bandLow == 70 && zone.bandHigh == 75)
        #expect(abs(zone.lockStart - 193.75) < 1e-9 && abs(zone.lockEnd - 221.25) < 1e-9)
        // Distances are measured on the called side, whichever side that was.
        #expect(abs(zone.distanceLow - 23.75) < 1e-9 && abs(zone.distanceHigh - 51.25) < 1e-9)
    }

    @Test func tooFewCallsWidenTheBandThenGiveUp() {
        let current = call(99, confidence: 0.72, lockedAfter: 180, distance: 15)
        // 6 in 70–75% and 6 in 65–70%: too few in the band, enough when widened to 65–80%.
        let past = (0..<6).map { call($0, confidence: 0.72, lockedAfter: 180, distance: 10) }
            + (6..<12).map { call($0, confidence: 0.67, lockedAfter: 180, distance: 10) }
        let zone = PredictionRecord.similarCallZone(for: current, in: past)
        #expect(zone?.count == 12)
        #expect(zone?.bandLow == 65 && zone?.bandHigh == 80)
        #expect(PredictionRecord.similarCallZone(for: current, in: Array(past.prefix(5))) == nil)
    }
}
