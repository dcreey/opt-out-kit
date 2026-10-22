import XCTest
import OptOutKitCore
@testable import OptOutKit

private struct CountingSubmitter: FormSubmitter {
    let box: CallBox
    func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome {
        box.calls += 1
        return dryRun ? .filledNotSubmitted : .submitted(awaitingEmail: false)
    }
}
private final class CallBox: @unchecked Sendable { var calls = 0 }

@MainActor
final class AutoProtectionTests: XCTestCase {
    private func model() -> AppModel {
        AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                 defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
    }
    private func withProfile(_ m: AppModel) throws -> Person {
        var me = try XCTUnwrap(m.selectedPerson)
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]
        me.emails = ["pat@example.com"]
        me.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")]
        m.update(me)
        m.setContactEmail("pat@example.com")
        return me
    }

    func testNothingRunsUntilThePersonSaysYes() async throws {
        let m = model()
        XCTAssertFalse(m.autoSettings.hasDecided)
        await m.runDueAutomation()
        XCTAssertNil(m.autoSettings.lastScan)
        XCTAssertNil(m.autoSettings.lastOptOut, "no daily scan and no weekly opt-out before the first-run answer")
    }

    func testSayingYesTurnsOnBothAndNoTurnsBothOff() {
        let m = model()
        m.setAuto(scan: true, optOut: true)
        XCTAssertTrue(m.autoSettings.scanEnabled && m.autoSettings.optOutEnabled && m.autoSettings.hasDecided)
        m.setAuto(scan: true, optOut: false)
        XCTAssertTrue(m.autoSettings.scanEnabled); XCTAssertFalse(m.autoSettings.optOutEnabled)
        m.setAuto(scan: false, optOut: false)
        XCTAssertFalse(m.autoSettings.scanEnabled || m.autoSettings.optOutEnabled)
        XCTAssertTrue(m.autoSettings.hasDecided, "the answer is remembered, so the first-run banner does not come back")
    }

    func testOptOutRunSendsToSitesWithAFormAndRecordsOnlyWhatWasSent() async throws {
        let m = model()
        let me = try withProfile(m)
        let box = CallBox()
        await m.runAutoOptOut(for: me, automaticOnly: false, submitter: CountingSubmitter(box: box))
        let sites = m.directory.filter { $0.optOutForm != nil }
        XCTAssertGreaterThan(sites.count, 50, "the directory has many forms")
        let rows = try XCTUnwrap(m.optOutRun[me.id])
        let sent = rows.filter { if case .submitted = $0.result { return true } else { return false } }
        XCTAssertEqual(sent.count, box.calls, "every call was recorded as a send")
        XCTAssertEqual(m.progress.optOutAttempts.count, sent.count, "only sends are remembered")
        XCTAssertNotNil(m.autoSettings.lastOptOut)
    }

    func testRunningAgainStraightAwaySendsNothingNew() async throws {
        let m = model()
        let me = try withProfile(m)
        let box = CallBox()
        await m.runAutoOptOut(for: me, automaticOnly: false, submitter: CountingSubmitter(box: box))
        let first = box.calls
        XCTAssertGreaterThan(first, 0)
        await m.runAutoOptOut(for: me, automaticOnly: false, submitter: CountingSubmitter(box: box))
        XCTAssertEqual(box.calls, first, "each site is sent at most once a week")
    }

    func testPreviewFillsFormsButRecordsNothingAndKeepsTheClockStopped() async throws {
        let m = model()
        let me = try withProfile(m)
        let box = CallBox()
        await m.runAutoOptOut(for: me, dryRun: true, automaticOnly: false, submitter: CountingSubmitter(box: box))
        XCTAssertGreaterThan(box.calls, 0)
        XCTAssertTrue(m.progress.optOutAttempts.isEmpty)
        XCTAssertNil(m.autoSettings.lastOptOut)
        XCTAssertTrue(m.optOutRun[me.id]!.contains { $0.result == .dryRunReady })
    }

    func testAMinorIsStillOptedOutButNeverScanned() async throws {
        let m = model()
        m.setAuto(scan: true, optOut: true)
        let kid = try XCTUnwrap(m.addPerson(named: "Kim Example"))
        var k = kid; k.isMinor = true; k.emails = ["k@example.com"]; k.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")]
        m.update(k)
        m.setContactEmail("pat@example.com")
        let box = CallBox()
        await m.runAutoOptOut(for: k, automaticOnly: false, submitter: CountingSubmitter(box: box))
        XCTAssertGreaterThan(box.calls, 0, "opt-out requests are not searches")
        XCTAssertFalse(k.canBeSearched())
    }

    func testAPersonWithNoEmailIsToldWhatToAddNotSentGuesses() async throws {
        let m = model()
        let me = try XCTUnwrap(m.selectedPerson)         // no name or email yet
        let box = CallBox()
        await m.runAutoOptOut(for: me, automaticOnly: false, submitter: CountingSubmitter(box: box))
        XCTAssertEqual(box.calls, 0)
        XCTAssertTrue(m.optOutRun[me.id]!.contains { if case .needsData = $0.result { return true } else { return false } }
                      || m.optOutRun[me.id]!.allSatisfy { if case .needsYou = $0.result { return true } else { return false } })
    }
}
