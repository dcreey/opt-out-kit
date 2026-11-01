import XCTest
import WebKit
import OptOutKitCore
@testable import OptOutKit

/// Every way out of a site in the assisted run that involves email or Skip, driven the way the screen drives it (runner + handoff), no UI.
@MainActor
final class EmailAndSkipFlowTests: XCTestCase {
    @MainActor private final class FakePage: AssistedPage {
        var blockerScript: [[AssistedBlocker]]; var outcome: SubmitOutcome
        private(set) var polls = 0, closed = false
        var webView: WKWebView? { nil }
        init(blockers: [[AssistedBlocker]], outcome: SubmitOutcome = .submitted(awaitingEmail: false)) { blockerScript = blockers; self.outcome = outcome }
        func blockers() async -> [AssistedBlocker] { defer { polls += 1 }; return blockerScript[min(polls, blockerScript.count - 1)] }
        func refill() async {}
        func send() async -> SubmitOutcome { outcome }
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
        await run.value
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
        r.skip(); await run.value
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
        await run.value
        XCTAssertEqual(log.rows.map(\.1), [.emailed]); XCTAssertEqual(r.skippedCount, 0)
    }

    // MARK: plain skip and Not working

    func testPlainSkipOnAFormPageNeverOffersEmailAndCountsAsSkipped() async {
        let log = Log()
        let (r, _) = make([item("a.example", email: "privacy@a.example")], Driver(["a.example": FakePage(blockers: waiting)]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.phase == .waitingForCheck)
        r.skip(); await run.value
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
        await run.value
        XCTAssertEqual(log.rows.map(\.1).last, .submitted(awaitingEmail: false), "the next site ran")
        XCTAssertEqual(r.results["a_example"], .emailed)
    }

    func testNotWorkingWithNoAddressMovesOnWithNoOffer() async {
        let log = Log()
        let (r, _) = make([item("a.example", email: nil)], Driver(["a.example": FakePage(blockers: waiting)]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.phase == .waitingForCheck)
        r.skip(reported: true); await run.value
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
        r.skip(); await run.value
        XCTAssertTrue(r.finished); XCTAssertEqual(log.rows.last?.0, "b.example")
    }

    // MARK: a site that is rejected or fails

    func testARejectedSiteWithAnAddressOffersEmailAndSkipMovesOn() async {
        let log = Log()
        let (r, _) = make([item("a.example", email: "privacy@a.example"), item("b.example", email: nil)],
                          Driver(["a.example": FakePage(blockers: [[]], outcome: .rejected("bad field")), "b.example": FakePage(blockers: [[]])]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.emailOffer != nil)
        XCTAssertEqual(r.emailOffer?.domain, "a.example")
        r.skip(); await run.value
        XCTAssertEqual(log.rows.map(\.0), ["a.example", "b.example"])
    }

    func testARejectedSiteWithNoAddressGetsNoOffer() async {
        let log = Log()
        let (r, _) = make([item("a.example", email: nil)], Driver(["a.example": FakePage(blockers: [[]], outcome: .rejected("bad field"))]), log)
        await r.run()
        XCTAssertNil(r.emailOffer); XCTAssertTrue(r.finished)
    }

    func testMarkAsDoneOnTheOfferCountsTheSiteAsEmailed() async {
        let log = Log()
        let (r, _) = make([item("a.example", email: "privacy@a.example")], Driver(["a.example": FakePage(blockers: [[]], outcome: .failed("no confirmation"))]), log)
        let run = Task { @MainActor in await r.run() }
        await wait(r.emailOffer != nil)
        r.answerEmailOffer(sent: true); await run.value
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
        r.skip(); await run.value
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
        await run.value
        XCTAssertEqual(log.emailed, 1, "saved once")
        XCTAssertEqual(log.rows.filter { $0.1 == .emailed }.count, 1)
    }
}
