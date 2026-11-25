import XCTest
import OptOutKitCore
@testable import AssistedRunLogic

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
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"
        me.emails = ["pat@example.com"]
        me.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")]
        m.update(me)
        m.setContactEmail("pat@example.com")
        return me
    }

    /// The automatic page shows the current run only: what an earlier run sent or failed is not in its groups once a new run has started. "Every site, all runs"
    /// combines them: a site sent in any run is sent there, one that was tried and never sent needs the person.
    func testTheAutomaticPageShowsOnlyTheCurrentRunAndAllRunsCombinesThem() throws {
        let m = model()
        let me = try withProfile(m)
        let ids = m.automaticSites(for: me).prefix(3).map(\.id)
        XCTAssertEqual(ids.count, 3)
        let (a, b, c) = (ids[0], ids[1], ids[2])
        let earlier = Date().addingTimeInterval(-3 * 86_400), started = Date().addingTimeInterval(-3600), now = Date().addingTimeInterval(-60)
        m.recordAttemptForTesting(OptOutAttempt(date: earlier, outcome: "submitted"), site: a)          // the last run sent a
        m.recordAttemptForTesting(OptOutAttempt(date: earlier, outcome: "challenged", detail: "a check"), site: b)
        m.recordAttemptForTesting(OptOutAttempt(date: now, outcome: "failed", detail: "no form"), site: c)          // this run: c did not go through
        m.setRunStartedForTesting(started)
        let current = Dictionary(m.activityRows(for: me).map { ($0.id, $0.group) }, uniquingKeysWith: { x, _ in x })
        XCTAssertEqual(current[c], .needsYou, "this run's result is shown")
        XCTAssertNotEqual(current[a], .sent, "the earlier run's send is not this run's")
        XCTAssertNotEqual(current[b], .needsYou, "nor its check")
        XCTAssertEqual(current.values.filter { $0 == .sent }.count, 0, "nothing was sent in this run yet")

        let all = Dictionary(m.allRunsRows(for: me).map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        XCTAssertEqual(all[a]?.group, .sent); XCTAssertEqual(all[b]?.group, .needsYou); XCTAssertEqual(all[c]?.group, .needsYou)
        XCTAssertTrue(all[a]?.line.contains("once") == true, "\(all[a]?.line ?? "")")
        // In the automatic page's words (decided 2026-11-24): tried and never sent is moved to semi-automatic, with how often it was tried.
        XCTAssertEqual(all[b]?.line.hasPrefix("Tried once, never sent: "), true, all[b]?.line ?? "")
        XCTAssertTrue(m.allRunsRows(for: me).allSatisfy { [.needsYou, .sent, .noAction, .notTried].contains($0.group) }, "only the four groups of every run")
        XCTAssertTrue(m.allRunsRows(for: me).contains { $0.group == .notTried }, "sites no run has reached are still to do")
    }

    /// Before any run, both pages count the same sites still to do: every site a full pass takes on (a new person saw 490 on the automatic page and 36 on
    /// "Every site, all runs"), in the same words.
    func testBothPagesCountTheSameSitesStillToDoBeforeAnyRun() throws {
        let m = model()
        let me = try withProfile(m)
        let page = m.activityRows(for: me).filter { $0.group == .notTried }.map(\.id)
        let all = m.allRunsRows(for: me).filter { $0.group == .notTried }.map(\.id)
        XCTAssertGreaterThan(page.count, 100)
        XCTAssertEqual(Set(all), Set(page), "the same sites still to do on both pages")
        XCTAssertTrue(m.allRunsRows(for: me).allSatisfy { $0.group == .notTried && $0.line == "No run has tried it yet" })
    }

    /// Both pages count the same sites, so their totals agree (decided 2026-11-24: "Every site, all runs" showed 595 and the automatic page 503): every site
    /// the run takes on and every site any attempt has reached. A site tried before that a run no longer takes on is in the semi-automated queue on both.
    func testBothPagesCountTheSameSitesSoTheirTotalsAgree() throws {
        let m = model()
        let me = try withProfile(m)
        let automatic = m.automaticSites(for: me)
        let outside = try XCTUnwrap(m.directory.first { !AutoOptOut.backgroundAttemptable(m.resolved($0), person: me, progress: m.progress) && $0.onlyFor == nil },
                                    "a site the run does not take on")
        let earlier = Date().addingTimeInterval(-40 * 86_400), now = Date().addingTimeInterval(-60)
        m.recordAttemptForTesting(OptOutAttempt(date: earlier, outcome: "failed", detail: "no success message was shown"), site: outside.id)
        m.recordAttemptForTesting(OptOutAttempt(date: earlier, outcome: "submitted"), site: automatic[0].id)
        m.recordAttemptForTesting(OptOutAttempt(date: now, outcome: "challenged", detail: "a reCAPTCHA checkbox"), site: automatic[1].id)
        m.setRunStartedForTesting(Date().addingTimeInterval(-3600))
        let page = m.activityRows(for: me), all = m.allRunsRows(for: me)
        XCTAssertEqual(Set(page.map(\.id)), Set(all.map(\.id)), "the same sites on both pages")
        XCTAssertEqual(page.count, all.count, "so the totals agree")
        XCTAssertEqual(page.first { $0.id == outside.id }?.group, .needsYou, "tried before, no longer the run's: in the semi-automated queue")
        XCTAssertEqual(all.first { $0.id == outside.id }?.group, .needsYou)
    }

    /// A second run in a period puts every site in one of five groups (decided 2026-11-24: the first run's sends were among 323 "Not tried"): moved to
    /// semi-automatic (this run's failures and an earlier run's human check), sent (by this run), no action needed (set aside), handled previously (sent by an
    /// earlier run this period) and still to do.
    func testASecondRunInAPeriodSortsEverySiteIntoFiveGroups() throws {
        let m = model()
        let me = try withProfile(m)
        let ids = m.automaticSites(for: me).prefix(5).map(\.id)
        XCTAssertEqual(ids.count, 5)
        let (sentBefore, checkBefore, sentNow, setAside, untried) = (ids[0], ids[1], ids[2], ids[3], ids[4])
        let first = Date().addingTimeInterval(-3600 * 5), started = Date().addingTimeInterval(-3600), now = Date().addingTimeInterval(-60)
        m.startPeriodForTesting(); m.setLastFullRunForTesting(first)          // the first run, a full pass, finished this period: this one is a repeat
        m.recordAttemptForTesting(OptOutAttempt(date: first, outcome: "submitted"), site: sentBefore)
        m.recordAttemptForTesting(OptOutAttempt(date: first, outcome: "challenged", detail: "a reCAPTCHA checkbox"), site: checkBefore)
        m.setRunStartedForTesting(started)
        m.recordAttemptForTesting(OptOutAttempt(date: now, outcome: "submitted"), site: sentNow)
        m.skipSite(setAside)
        let rows = Dictionary(m.activityRows(for: me).map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        XCTAssertEqual(rows[sentBefore]?.group, .earlier, "handled previously")
        XCTAssertTrue(rows[sentBefore]?.line.hasSuffix("in an earlier run") == true, rows[sentBefore]?.line ?? "")
        XCTAssertEqual(rows[checkBefore]?.group, .needsYou, "an earlier run's human check is in the semi-automated queue")
        XCTAssertTrue(rows[checkBefore]?.line.hasPrefix("Blocked by a human check") == true, rows[checkBefore]?.line ?? "")
        XCTAssertEqual(rows[sentNow]?.group, .sent)
        XCTAssertEqual(rows[setAside]?.group, .noAction, "no action needed")
        XCTAssertEqual(rows[setAside]?.line, "You set it aside")
        XCTAssertEqual(rows[untried]?.group, .notTried, "still to do")
        XCTAssertGreaterThan(m.runNowCount(for: me), 0, "and Run now tries the ones still to do")
    }

    /// One line above the counts gives the last and next run dates (the page's other status lines were taken out, 2026-11-24).
    func testThePageHasOneLineWithTheLastAndNextRun() async throws {
        let m = model()
        let me = try withProfile(m)
        XCTAssertFalse(m.runDatesLine?.hasPrefix("Last run") ?? false, "nothing has run yet")
        m.setAuto(scan: false, optOut: true)
        await m.runAutoOptOut(for: me, submitter: CountingSubmitter(box: CallBox()))
        let line = try XCTUnwrap(m.runDatesLine)
        XCTAssertTrue(line.hasPrefix("Last run " + Loc.date(Date())), line)
        if m.autoSettings.nextOptOutDate() != nil { XCTAssertTrue(line.contains(" · Next run "), line) }
    }

    /// The Queue tab's card says only how many sites the run has looked at (decided 2026-11-25); the total below the day's work is the Sites tab's own
    /// "Done" count, so the two screens always agree.
    func testTheCardSaysWhatWasScannedAndTheTotalIsTheSitesTabsDoneCount() throws {
        XCTAssertEqual(AppModel.activityCountsLine(.init(groups: [.sent: 10, .earlier: 334, .noAction: 14, .needsYou: 240])), "Scanned 598 sites")
        XCTAssertEqual(AppModel.activityCountsLine(.init(groups: [.sent: 6, .needsYou: 1, .notTried: 61])), "Scanned 7 sites", "sites still to do were not scanned")
        XCTAssertTrue(AppModel.ActivityCounts(groups: [.sent: 10, .earlier: 334, .noAction: 14, .needsYou: 240]).complete, "complete once the run has nothing left to try, whatever moved to the person")
        XCTAssertFalse(AppModel.ActivityCounts(groups: [.sent: 5, .notTried: 1]).complete, "not while a site is still to do")

        let m = model()
        let me = try withProfile(m)
        XCTAssertEqual(m.doneSiteCount, m.siteRows().done.count)
        let sites = m.activityRows(for: me).map(\.id)
        XCTAssertGreaterThan(sites.count, 3)
        let site = { (id: String) in try XCTUnwrap(m.directory.first { $0.id == id }) }
        m.recordAttemptForTesting(OptOutAttempt(date: Date(), outcome: "submitted"), site: sites[0])                    // sent, in Solve and send
        m.recordSiteCheckForTesting(.removed, site: try site(sites[1]))                                               // no record of the person
        m.recordAttemptForTesting(OptOutAttempt(date: Date().addingTimeInterval(-400 * 86_400), outcome: "submitted"), site: sites[2])   // a send that ran out
        m.skipSite(sites[3], forever: true)                                                                            // set aside
        let done = Set(m.siteRows().done.compactMap { $0.entry?.id })
        XCTAssertEqual(m.doneSiteCount, done.count, "the home total is the Sites tab's Done count")
        XCTAssertTrue(done.contains(sites[0]) && done.contains(sites[1]), "a send that holds and a site with no record of the person are done")
        XCTAssertFalse(done.contains(sites[2]), "a send that ran out is due again, not done")
        XCTAssertFalse(done.contains(sites[3]), "a site set aside is skipped, not done")
    }

    /// The card's numbers are worked out again when a run ends (away from the main thread), so the Queue tab shows them without working them out as it draws.
    func testTheQueueCardsNumbersAreWorkedOutWhenARunEnds() async throws {
        let m = model()
        let me = try withProfile(m)
        m.setAuto(scan: false, optOut: true)
        XCTAssertNil(m.activityCounts, "nothing worked out yet")
        await m.runAutoOptOut(for: me, submitter: CountingSubmitter(box: CallBox()))
        var waited = 0
        while m.activityCounts == nil && waited < 200 { try await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
        let counts = try XCTUnwrap(m.activityCounts, "the run's end worked the numbers out")
        XCTAssertEqual(counts.total, m.activityRows(for: me).count, "the same sites as the page")
    }

    /// A site done in Solve and send updates the card once the person pauses: three sites in a row work the numbers out once, not three times.
    func testSitesDoneInSolveAndSendUpdateTheCardOnceThePersonPauses() async throws {
        let m = model()
        let me = try withProfile(m)
        let rows = m.activityRows(for: me)
        m.noteActivity(rows)
        let before = try XCTUnwrap(m.activityCounts)
        let semi = rows.filter { $0.group != .sent && $0.group != .earlier }.prefix(3).compactMap { r in m.directory.first { $0.id == r.id } }
        XCTAssertEqual(semi.count, 3)
        for e in semi { m.recordAssisted(e, .submitted(awaitingEmail: false), for: me) }
        var waited = 0
        let optedOut = { (c: AppModel.ActivityCounts?) in (c?[.sent] ?? 0) + (c?[.earlier] ?? 0) }          // the page's Sent and Handled previously
        while optedOut(m.activityCounts) < optedOut(before) + 3 && waited < 300 { try await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
        XCTAssertEqual(optedOut(m.activityCounts), optedOut(before) + 3, "the numbers count them")
        XCTAssertEqual(m.countsRefreshes, 1, "worked out once for the three")
    }

    /// A new run starts the page afresh; a run that is stopped and carried on, or a Re-test all of a pass under way, is the same run.
    func testANewRunStartsThePageAfreshAndACarriedOnRunDoesNot() {
        var s = AutoSettings()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        s.startFullRetest(now: t0)
        XCTAssertEqual(s.runStarted, t0)
        s.startFullRetest(now: t0.addingTimeInterval(600))
        XCTAssertEqual(s.runStarted, t0, "a full pass under way carries on")
        s.passStarted = nil; s.passKind = nil
        s.startFullRetest(now: t0.addingTimeInterval(86_400))
        XCTAssertEqual(s.runStarted, t0.addingTimeInterval(86_400), "a new pass is a new run")
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
        // Sites that share one opt-out page are sent once and each gets the result, so there are never fewer sends recorded than calls made.
        XCTAssertGreaterThanOrEqual(sent.count, box.calls)
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
        var k = kid; k.isMinor = true; k.birthdate = "2015-05-01"; k.emails = ["k@example.com"]; k.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")]
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
        // The run does not start: the person is asked for their current address first, and nothing is sent or recorded.
        XCTAssertNil(m.optOutRun[me.id])
    }
}
