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
