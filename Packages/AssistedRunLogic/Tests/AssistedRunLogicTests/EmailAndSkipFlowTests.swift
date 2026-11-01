import XCTest
import OptOutKitCore
@testable import AssistedRunLogic

/// Every way out of a site in the assisted run that involves email or Skip, driven the way the screen drives it (runner + handoff), no UI.
///
/// Expected behavior (each line is pinned by a test below, or by EmailHandoffTests / Core's skip tests where noted):
///
/// Emailing a site
/// - Other mail app (Gmail, Outlook, ...): "Did you send it?" is asked the moment the app is opened, so it is waiting on return. Nothing may cover it,
///   including the "This site did not go through" dialog. Yes saves the site as emailed; No saves nothing.
/// - In-app Mail composer: Send saves the site as emailed; Cancel saves nothing. The result counts even if the sheet cleared its own state first.
/// - Emailed from a live form page: the site ends as Emailed (green check), never as Skipped, and the run moves to the next site.
/// - A No on a form page keeps the site open. A No on a failed site's offer moves on. A No on the no-form screen keeps waiting.
/// - An answer to a question that was never asked, or a second answer to the same one, changes nothing and saves once.
///
/// Skip
/// - Skip this site always moves to the next site, whatever the site is waiting on: the form page, the no-form screen, or the email offer.
/// - A plain skip never offers email and counts as skipped. "Not working" on a site with an address offers email; with no address it just moves on.
/// - A rejected or failed site with an address offers email; Mark as done on the offer saves it as emailed; Skip on the offer moves on.
///
/// Skipped sites coming back (Core's CoreTests, "ASkipWaitsAWeek..." and neighbours; not yet tested end to end through the app model)
/// - A skipped site leaves the batch, waits a week, then returns with a reminder. Skipping again restarts the week. "Forever" never returns.
///   Finishing a skipped site ends its skip.
@MainActor
final class EmailAndSkipFlowTests: XCTestCase {
    @MainActor private final class FakePage: AssistedPage {
        var blockerScript: [[AssistedBlocker]]; var outcome: SubmitOutcome
        private(set) var polls = 0, sends = 0, closed = false
        init(blockers: [[AssistedBlocker]], outcome: SubmitOutcome = .submitted(awaitingEmail: false)) { blockerScript = blockers; self.outcome = outcome }
        func blockers() async -> [AssistedBlocker] { defer { polls += 1 }; return blockerScript[min(polls, blockerScript.count - 1)] }
        func refill() async {}
        func send() async -> SubmitOutcome { sends += 1; return outcome }
        func close() { closed = true }
    }
    @MainActor private final class Driver: AssistedDriver {
        var pages: [String: FakePage]; var noForm: Set<String>
        init(_ pages: [String: FakePage], noForm: Set<String> = []) { self.pages = pages; self.noForm = noForm }
        func prepare(_ form: OptOutForm, plan: FillPlan) async -> AssistedPage? { pages[form.page.host ?? ""] }
        func failureReason(for form: OptOutForm) -> String? { noForm.contains(form.page.host ?? "") ? "noform" : nil }
    }
    private final class Log { var rows: [(String, AutoOptOutResult)] = []; var emailed = 0 }

    private func item(_ host: String, email: String?) -> AssistedRunner.Item {
        let form = OptOutForm(page: URL(string: "https://\(host)/optout")!, method: "post", action: nil, fields: [FormField(type: "email", name: "email", label: "Email")], hops: 1)
        let entry = DirectoryEntry(id: host.replacingOccurrences(of: ".", with: "_"), domain: host, name: host, bucket: "direct", tier: .B, automation: .guided, optOutForm: form, contactEmail: email)
        return AssistedRunner.Item(entry: entry, form: form, plan: FillPlan(values: [], verdict: .ready))
    }
    private func make(_ items: [AssistedRunner.Item], _ driver: Driver, _ log: Log) -> (AssistedRunner, EmailHandoff) {
        let r = AssistedRunner(items: items, driver: driver) { e, res in log.rows.append((e.domain, res)) }
        r.pollInterval = 0.01; r.pauseAfterSent = 0; r.waitLimit = 30
        let h = EmailHandoff(runner: r); h.markEmailed = { _ in log.emailed += 1 }
        return (r, h)
    }
    /// Waits for the run to end without hanging the suite when an assertion above it has already failed.
    private func join(_ run: Task<Void, Never>, _ r: AssistedRunner) async {
        for _ in 0..<600 where !r.finished { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(r.finished, "the run did not finish")
        if r.finished { await run.value } else { run.cancel() }
    }
    private func wait(_ cond: @autoclosure () -> Bool) async { for _ in 0..<600 where !cond() { try? await Task.sleep(nanoseconds: 5_000_000) } }
    private func batch(_ r: AssistedRunner, _ host: String) -> EmailBatch { EmailBatch.single(entries: [r.current!.entry]).first! }
    private let url = URL(string: "mailto:privacy@a.example")!
    private let waiting = [[AssistedBlocker.check("a bot check")]]       // the page stays up until the person acts

    // MARK: emailing a site that has a form

    func testEmailingFromTheFormPageEndsTheSiteAsEmailedNotSkippedAndTheNextSiteRuns() async {
        let log = Log()
        let (r, h) = make([item("a.example", email: "privacy@a.example"), item("b.example", email: nil)],
                          Driver(["a.example": FakePage(blockers: waiting), "b.example": FakePage(blockers: [[]])]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.phase == .waitingForCheck)
        h.open(batch(r, "a.example"), composesInApp: false, url: url) { _ in }
        XCTAssertNil(r.emailOffer, "a live form page has no offer, the person chose to email")
        h.answer(sent: true)
        await join(run, r)
        XCTAssertEqual(log.rows.map(\.1), [.emailed, .submitted(awaitingEmail: false)])
        XCTAssertEqual(r.skippedCount, 0, "not counted as skipped"); XCTAssertEqual(r.celebrate, 2, "green check for the email and for the next send")
        XCTAssertEqual(log.emailed, 1)
    }

    func testSayingNoToDidYouSendItOnAFormPageKeepsTheSiteOpen() async {
        let log = Log()
        let (r, h) = make([item("a.example", email: "privacy@a.example")], Driver(["a.example": FakePage(blockers: waiting)]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.phase == .waitingForCheck)
        h.open(batch(r, "a.example"), composesInApp: false, url: url) { _ in }
        h.answer(sent: false)
        XCTAssertFalse(r.finished); XCTAssertEqual(log.emailed, 0); XCTAssertEqual(log.rows.count, 0)
        XCTAssertFalse(h.active)
        r.skip(); await join(run, r)
        XCTAssertEqual(log.rows.map(\.1), [.needsYou("skipped")])
    }

    func testSendingInTheComposerFromAFormPageEndsTheSiteAsEmailed() async {
        let log = Log()
        let (r, h) = make([item("a.example", email: "privacy@a.example")], Driver(["a.example": FakePage(blockers: waiting)]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.phase == .waitingForCheck)
        let b = batch(r, "a.example")
        h.open(b, composesInApp: true, url: nil) { _ in }
        h.composeFinished(b, sent: true)
        await join(run, r)
        XCTAssertEqual(log.rows.map(\.1), [.emailed]); XCTAssertEqual(r.skippedCount, 0)
    }

    // MARK: plain skip and Not working

    func testPlainSkipOnAFormPageNeverOffersEmailAndCountsAsSkipped() async {
        let log = Log()
        let (r, _) = make([item("a.example", email: "privacy@a.example")], Driver(["a.example": FakePage(blockers: waiting)]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.phase == .waitingForCheck)
        r.skip(); await join(run, r)
        XCTAssertEqual(log.rows.map(\.1), [.needsYou("skipped")]); XCTAssertEqual(r.skippedCount, 1); XCTAssertNil(r.emailOffer)
    }

    func testNotWorkingOffersTheEmailAndSendingItFinishesTheSite() async {
        let log = Log()
        let (r, h) = make([item("a.example", email: "privacy@a.example"), item("b.example", email: nil)],
                          Driver(["a.example": FakePage(blockers: waiting), "b.example": FakePage(blockers: [[]])]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.phase == .waitingForCheck)
        r.skip(reported: true)
        await wait(r.emailOffer != nil)
        XCTAssertEqual(r.emailOffer?.domain, "a.example")
        h.open(EmailBatch.single(entries: [r.emailOffer!]).first!, composesInApp: false, url: url) { _ in }
        h.answer(sent: true)
        await join(run, r)
        XCTAssertEqual(log.rows.map(\.1).last, .submitted(awaitingEmail: false), "the next site ran")
        XCTAssertEqual(r.results["a_example"], .emailed)
    }

    func testNotWorkingWithNoAddressMovesOnWithNoOffer() async {
        let log = Log()
        let (r, _) = make([item("a.example", email: nil)], Driver(["a.example": FakePage(blockers: waiting)]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.phase == .waitingForCheck)
        r.skip(reported: true); await join(run, r)
        XCTAssertNil(r.emailOffer); XCTAssertTrue(r.finished)
    }

    func testSkippingTheNotWorkingOfferMovesToTheNextSite() async {
        let log = Log()
        let (r, _) = make([item("a.example", email: "privacy@a.example"), item("b.example", email: nil)],
                          Driver(["a.example": FakePage(blockers: waiting), "b.example": FakePage(blockers: [[]])]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.phase == .waitingForCheck)
        r.skip(reported: true)
        await wait(r.emailOffer != nil)
        r.skip(); await join(run, r)
        XCTAssertTrue(r.finished); XCTAssertEqual(log.rows.last?.0, "b.example")
    }

    // MARK: a site that is rejected or fails

    func testARejectedSiteStaysOnItsPageUntilNextThenOffersEmailAndSkipMovesOn() async {
        let log = Log()
        let (r, _) = make([item("a.example", email: "privacy@a.example"), item("b.example", email: nil)],
                          Driver(["a.example": FakePage(blockers: [[]], outcome: .rejected("bad field")), "b.example": FakePage(blockers: [[]])]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.phase == .needsMore("bad field"))
        XCTAssertNil(r.emailOffer, "the person is still on the page, finishing it themselves")
        r.next()
        await wait(r.emailOffer != nil)
        XCTAssertEqual(r.emailOffer?.domain, "a.example")
        r.skip(); await join(run, r)
        XCTAssertEqual(log.rows.map(\.0), ["a.example", "b.example"])
    }

    func testARejectedSiteWithNoAddressGetsNoOffer() async {
        let log = Log()
        let (r, _) = make([item("a.example", email: nil)], Driver(["a.example": FakePage(blockers: [[]], outcome: .rejected("bad field"))]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.phase == .needsMore("bad field"))
        r.next(); await join(run, r)
        XCTAssertNil(r.emailOffer)
    }

    func testMarkAsDoneOnTheOfferCountsTheSiteAsEmailed() async {
        let log = Log()
        let (r, _) = make([item("a.example", email: "privacy@a.example")], Driver(["a.example": FakePage(blockers: [[]], outcome: .failed("no confirmation"))]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.phase == .needsMore("no confirmation"))
        r.next()
        await wait(r.emailOffer != nil)
        r.answerEmailOffer(sent: true); await join(run, r)
        XCTAssertEqual(log.rows.last?.1, .emailed)
    }

    // MARK: no-form sites in a sequence, and the handoff guards

    func testANoFormSiteWaitsThenSkipMovesToTheNextSite() async {
        let log = Log()
        let (r, _) = make([item("a.example", email: "privacy@a.example"), item("b.example", email: nil)],
                          Driver(["b.example": FakePage(blockers: [[]])], noForm: ["a.example"]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.phase == .noForm)
        XCTAssertFalse(r.finished)
        r.skip(); await join(run, r)
        XCTAssertEqual(log.rows.map(\.0), ["a.example", "b.example"]); XCTAssertEqual(log.rows.first?.1, .needsYou("skipped"))
    }

    func testAnswersWithNothingOpenAndDoubleAnswersDoNothing() async {
        let log = Log()
        let (r, h) = make([item("a.example", email: "privacy@a.example")], Driver([:], noForm: ["a.example"]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.phase == .noForm)
        h.answer(sent: true); h.composeFinished(batch(r, "a.example"), sent: false)
        XCTAssertEqual(log.emailed, 0); XCTAssertFalse(r.finished, "an answer to a question never asked changes nothing")
        h.open(batch(r, "a.example"), composesInApp: false, url: url) { _ in }
        h.answer(sent: true); h.answer(sent: true)
        await join(run, r)
        XCTAssertEqual(log.emailed, 1, "saved once")
        XCTAssertEqual(log.rows.filter { $0.1 == .emailed }.count, 1)
    }

    // MARK: going back to the previous site

    func testBackReopensThePreviousSiteWithoutChangingEitherSiteAndNothingIsSentForThePerson() async {
        let log = Log()
        let a = FakePage(blockers: [[]]), b = FakePage(blockers: waiting)
        let (r, _) = make([item("a.example", email: nil), item("b.example", email: nil)], Driver(["a.example": a, "b.example": b]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.index == 1 && r.phase == .waitingForCheck)
        XCTAssertEqual(log.rows.map(\.0), ["a.example"])
        XCTAssertTrue(r.canGoBack)
        r.back()
        XCTAssertTrue(r.goingBack, "the screen can show the loading mark at once")
        XCTAssertEqual(r.index, 0, "and moves to the earlier site straight away")
        XCTAssertFalse(r.canGoBack, "a second tap while it loads does nothing")
        await wait(r.index == 0 && r.phase == .reviewing)
        XCTAssertFalse(r.goingBack, "the loading mark is gone once the earlier site is on screen")
        XCTAssertEqual(r.phase, .reviewing, "the earlier site is shown as it is, not sent again")
        XCTAssertTrue(r.revisiting)
        XCTAssertEqual(log.rows.map(\.0), ["a.example"], "leaving b recorded nothing: not skipped, not failed")
        XCTAssertEqual(r.skippedCount, 0)
        r.next()
        await wait(r.index == 1 && r.phase == .waitingForCheck)
        XCTAssertFalse(r.revisiting)
        XCTAssertEqual(log.rows.count, 1, "going back and forward left a's result as it was")
        r.skip(); await join(run, r)
        XCTAssertEqual(log.rows.map(\.0), ["a.example", "b.example"])
    }

    func testTheFirstSiteHasNothingBefore() async {
        let log = Log()
        let (r, _) = make([item("a.example", email: nil)], Driver(["a.example": FakePage(blockers: waiting)]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.phase == .waitingForCheck)
        XCTAssertFalse(r.canGoBack); r.back()
        XCTAssertEqual(r.index, 0); XCTAssertEqual(log.rows.count, 0)
        r.skip(); await join(run, r)
    }

    func testASkippedSiteDoneNowAfterGoingBackIsRecordedAsDone() async {
        let log = Log()
        let (r, _) = make([item("a.example", email: nil), item("b.example", email: nil)],
                          Driver(["a.example": FakePage(blockers: waiting), "b.example": FakePage(blockers: waiting)]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.index == 0 && r.phase == .waitingForCheck)
        r.skip()
        await wait(r.index == 1 && r.phase == .waitingForCheck)
        XCTAssertEqual(log.rows.last?.1, .needsYou("skipped"))
        r.back()
        await wait(r.index == 0 && r.phase == .reviewing)
        await r.markDone()                                   // they did it by hand on the page
        await wait(r.index == 1 && r.phase == .waitingForCheck)
        XCTAssertEqual(log.rows.map(\.1), [.needsYou("skipped"), .submitted(awaitingEmail: false)], "now done")
        r.skip(); await join(run, r)
    }

    func testSkippingOrLeavingASiteVisitedAgainDoesNotOverwriteItsResult() async {
        let log = Log()
        let (r, _) = make([item("a.example", email: "privacy@a.example"), item("b.example", email: nil)],
                          Driver(["a.example": FakePage(blockers: [[]]), "b.example": FakePage(blockers: waiting)]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.index == 1 && r.phase == .waitingForCheck)
        r.back()
        await wait(r.index == 0 && r.phase == .reviewing)
        r.skip()
        await wait(r.index == 1 && r.phase == .waitingForCheck)
        XCTAssertEqual(log.rows.map(\.1), [.submitted(awaitingEmail: false)], "a stays sent")
        XCTAssertEqual(r.skippedCount, 0); XCTAssertNil(r.emailOffer, "no email offer for a site only looked at")
        r.skip(); await join(run, r)
    }

    func testGoingBackTwiceWalksBackTwoSites() async {
        let log = Log()
        let (r, _) = make([item("a.example", email: nil), item("b.example", email: nil), item("c.example", email: nil)],
                          Driver(["a.example": FakePage(blockers: [[]]), "b.example": FakePage(blockers: [[]]), "c.example": FakePage(blockers: waiting)]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.index == 2 && r.phase == .waitingForCheck)
        r.back(); await wait(r.index == 1 && r.phase == .reviewing)
        r.back(); await wait(r.index == 0 && r.phase == .reviewing)
        XCTAssertFalse(r.canGoBack)
        r.next(); await wait(r.index == 1 && r.phase == .reviewing)
        r.next(); await wait(r.index == 2 && r.phase == .waitingForCheck)
        r.skip(); await join(run, r)
        XCTAssertEqual(log.rows.map(\.0), ["a.example", "b.example", "c.example"])
    }

    func testBackFromTheEmailOfferLeavesTheSiteUntouched() async {
        let log = Log()
        let (r, _) = make([item("a.example", email: nil), item("b.example", email: "privacy@b.example")],
                          Driver(["a.example": FakePage(blockers: [[]])], noForm: ["b.example"]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.phase == .noForm)
        r.back()
        await wait(r.index == 0 && r.phase == .reviewing)
        XCTAssertEqual(log.rows.map(\.0), ["a.example"])
        r.next(); await wait(r.phase == .noForm)
        r.skip(); await join(run, r)
    }

    // MARK: "Send it for me" turned off

    func testWithSendingForThePersonOffTheFormIsFilledButNothingIsPressedAndNextLeavesItNotDone() async {
        let log = Log()
        let page = FakePage(blockers: [[]])
        let (r, _) = make([item("a.example", email: nil), item("b.example", email: nil)], Driver(["a.example": page, "b.example": FakePage(blockers: [[]])]), log)
        var auto = false
        r.autoSubmit = { auto }
        let run = Task { @MainActor in await r.run() }
        await wait(r.phase == .manualSend)
        XCTAssertEqual(page.sends, 0, "the app did not press send")
        XCTAssertEqual(log.rows.count, 0)
        auto = true                                       // turning it back on later does not send a page the person is already finishing
        r.next()
        await wait(r.index == 1)
        XCTAssertEqual(page.sends, 0)
        XCTAssertEqual(log.rows.first?.1, .needsYou("you sent it yourself and we saw no confirmation"), "not recorded as sent, and not as failed")
        await join(run, r)
        XCTAssertEqual(log.rows.last?.0, "b.example")
    }

    func testMarkAsDoneAfterSendingItYourselfRecordsTheSiteAsSent() async {
        let log = Log()
        let (r, _) = make([item("a.example", email: nil)], Driver(["a.example": FakePage(blockers: [[]])]), log)
        r.autoSubmit = { false }
        let run = Task { @MainActor in await r.run() }
        await wait(r.phase == .manualSend)
        await r.markDone()
        await join(run, r)
        XCTAssertEqual(log.rows.map(\.1), [.submitted(awaitingEmail: false)])
    }

    func testWithSendingForThePersonOnTheAppSendsAsBefore() async {
        let log = Log()
        let page = FakePage(blockers: [[]])
        let (r, _) = make([item("a.example", email: nil)], Driver(["a.example": page]), log)
        r.autoSubmit = { true }
        await join(Task { @MainActor in await r.run() }, r)
        XCTAssertEqual(page.sends, 1); XCTAssertEqual(log.rows.map(\.1), [.submitted(awaitingEmail: false)])
    }
}
