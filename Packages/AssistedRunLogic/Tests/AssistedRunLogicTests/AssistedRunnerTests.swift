import XCTest
import OptOutKitCore
@testable import AssistedRunLogic

// MARK: Scripted fakes

@MainActor
private final class ScriptedPage: AssistedPage {
    var blockerScript: [[AssistedBlocker]]          // what blockers() returns on each call; the last entry repeats
    var outcomes: [SubmitOutcome]                   // what send() returns on each call
    private(set) var refills = 0, sends = 0, polls = 0, closed = false
    init(blockers: [[AssistedBlocker]] = [[]], outcomes: [SubmitOutcome] = [.submitted(awaitingEmail: false)]) {
        self.blockerScript = blockers; self.outcomes = outcomes
    }
    func blockers() async -> [AssistedBlocker] { defer { polls += 1 }; return blockerScript[min(polls, blockerScript.count - 1)] }
    func refill() async { refills += 1 }
    func send() async -> SubmitOutcome { defer { sends += 1 }; return outcomes[min(sends, outcomes.count - 1)] }
    func close() { closed = true }
}

@MainActor
private final class ScriptedDriver: AssistedDriver {
    var pages: [String: ScriptedPage?]
    private(set) var prepared: [String] = []
    init(_ pages: [String: ScriptedPage?]) { self.pages = pages }
    func prepare(_ form: OptOutForm, plan: FillPlan) async -> AssistedPage? {
        let key = form.page.host ?? ""
        prepared.append(key)
        return pages[key] ?? nil
    }
}

@MainActor
private func items(_ hosts: [String]) -> [AssistedRunner.Item] {
    hosts.map { host in
        let form = OptOutForm(page: URL(string: "https://\(host)/optout")!, method: "post", action: nil,
                              fields: [FormField(type: "email", name: "email", label: "Email")], hops: 1)
        let entry = DirectoryEntry(id: host.replacingOccurrences(of: ".", with: "_"), domain: host, name: host, bucket: "direct", tier: .B,
                                   automation: .guided, confidence: nil, optOutURL: nil, optOutForm: form, family: nil, familyParent: nil,
                                   template: nil, searchCheck: nil, signals: nil, profiled: nil)
        return AssistedRunner.Item(entry: entry, form: form, plan: FillPlan(values: [], verdict: .ready))
    }
}

@MainActor
private final class SlowDriver: AssistedDriver {
    let slow: String
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    init(slow: String) { self.slow = slow }
    func release() { released = true; gate?.resume(); gate = nil }
    func prepare(_ form: OptOutForm, plan: FillPlan) async -> AssistedPage? {
        if form.page.host == slow, !released { await withCheckedContinuation { gate = $0 } }
        return ScriptedPage()
    }
}

private final class Sink: @unchecked Sendable { var rows: [(String, AutoOptOutResult)] = [] }

@MainActor
final class AssistedRunnerTests: XCTestCase {
    private func runner(_ hosts: [String], _ driver: ScriptedDriver, _ sink: Sink) -> AssistedRunner {
        let r = AssistedRunner(items: items(hosts), driver: driver) { entry, result in sink.rows.append((entry.domain, result)) }
        r.pollInterval = 0.01; r.pauseAfterSent = 0; r.waitLimit = 0.3
        return r
    }

    func testASiteWithNoBlockerIsFilledAndSentWithoutAnyHelp() async {
        let page = ScriptedPage()
        let sink = Sink()
        let r = runner(["a.example"], ScriptedDriver(["a.example": page]), sink)
        await r.run()
        XCTAssertEqual(sink.rows.map(\.1), [.submitted(awaitingEmail: false)])
        XCTAssertEqual(page.refills, 1)
        XCTAssertTrue(page.closed)
        XCTAssertTrue(r.finished)
    }

    func testItWaitsForTheCheckThenRefillsAndSendsOnlyAfterItClears() async {
        let page = ScriptedPage(blockers: [[.check("a reCAPTCHA checkbox")], [.check("a reCAPTCHA checkbox")], []])
        let sink = Sink()
        let r = runner(["a.example"], ScriptedDriver(["a.example": page]), sink)
        var phases: [AssistedRunner.Phase] = []
        let watcher = Task { @MainActor in
            while !r.finished { phases.append(r.phase); try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        await r.run(); watcher.cancel()
        XCTAssertTrue(phases.contains(.waitingForCheck), "the person was asked to solve the check")
        XCTAssertEqual(page.sends, 1, "sent exactly once, and only after the check cleared")
        XCTAssertGreaterThanOrEqual(page.polls, 3)
        XCTAssertEqual(sink.rows.first?.1, .submitted(awaitingEmail: false))
    }

    func testATermsPromptIsLeftForThePersonToAcceptThemselves() async {
        let page = ScriptedPage(blockers: [[.terms, .check("a reCAPTCHA checkbox")], [.terms], []])
        let sink = Sink()
        let r = runner(["a.example"], ScriptedDriver(["a.example": page]), sink)
        var sawTerms = false
        let watcher = Task { @MainActor in while !r.finished { if r.phase == .waitingForTerms { sawTerms = true }; try? await Task.sleep(nanoseconds: 2_000_000) } }
        await r.run(); watcher.cancel()
        XCTAssertTrue(sawTerms)
        XCTAssertEqual(page.sends, 1)
    }

    func testACertificationBoxIsLeftForThePersonToTickThemselves() async {
        let page = ScriptedPage(blockers: [[.certify("I certify that I am the subject of this request"), .check("a reCAPTCHA checkbox")], [.check("a reCAPTCHA checkbox")], []])
        let sink = Sink()
        let r = runner(["a.example"], ScriptedDriver(["a.example": page]), sink)
        var sawCertification = false
        let watcher = Task { @MainActor in while !r.finished { if r.phase == .waitingForCertification { sawCertification = true }; try? await Task.sleep(nanoseconds: 2_000_000) } }
        await r.run(); watcher.cancel()
        XCTAssertTrue(sawCertification, "the person was asked to tick the confirmation themselves")
        XCTAssertEqual(page.sends, 1, "and it was sent only after they had")
    }

    func testItTimesOutInsteadOfWaitingForever() async {
        let page = ScriptedPage(blockers: [[.check("a bot check")]])
        let sink = Sink()
        let r = runner(["a.example", "b.example"], ScriptedDriver(["a.example": page, "b.example": ScriptedPage()]), sink)
        await r.run()
        XCTAssertEqual(page.sends, 0, "nothing was sent while the check was still there")
        XCTAssertEqual(sink.rows[0].1, .needsYou("timed out waiting for the check"))
        XCTAssertEqual(sink.rows[1].1, .submitted(awaitingEmail: false), "it carries on to the next site")
    }

    func testSkipMovesOnWithoutSending() async {
        let page = ScriptedPage(blockers: [[.check("a bot check")]])
        let sink = Sink()
        let r = runner(["a.example", "b.example"], ScriptedDriver(["a.example": page, "b.example": ScriptedPage()]), sink)
        r.waitLimit = 30
        let task = Task { @MainActor in await r.run() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        r.skip()
        await task.value
        XCTAssertEqual(page.sends, 0)
        XCTAssertEqual(sink.rows[0].1, .needsYou("skipped"))
        XCTAssertEqual(sink.rows.count, 2)
    }

    func testSkippingTheLastSiteEndsTheRun() async {
        let sink = Sink()
        let r = runner(["a.example", "b.example"], ScriptedDriver(["a.example": ScriptedPage(), "b.example": ScriptedPage(blockers: [[.check("a bot check")]])]), sink)
        r.waitLimit = 30
        let task = Task { @MainActor in await r.run() }
        for _ in 0..<200 where r.index < 1 { try? await Task.sleep(nanoseconds: 10_000_000) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        r.skip()
        await task.value
        XCTAssertTrue(r.finished, "nothing is left: the run ends and shows its summary")
        XCTAssertEqual(sink.rows.last?.1, .needsYou("skipped"))
    }

    func testSkippingWhileAPageIsStillLoadingMovesOnAtOnce() async {
        let sink = Sink()
        let driver = SlowDriver(slow: "a.example")
        let r = AssistedRunner(items: items(["a.example", "b.example"]), driver: driver) { entry, result in sink.rows.append((entry.domain, result)) }
        r.pollInterval = 0.01; r.pauseAfterSent = 0; r.waitLimit = 30
        let task = Task { @MainActor in await r.run() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(r.index, 0); XCTAssertEqual(r.phase, .loading)
        r.skip()
        for _ in 0..<200 where r.index < 1 { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(r.index, 1, "it did not wait for the slow page")
        XCTAssertEqual(sink.rows.first?.1, .needsYou("skipped"))
        driver.release()
        await task.value
        XCTAssertTrue(r.finished)
    }

    func testTheNextSiteLoadsWhileThePersonStillWorksOnTheCurrentOne() async {
        let slow = ScriptedPage(blockers: [[.check("a bot check")], [.check("a bot check")], [.check("a bot check")], []])
        let driver = ScriptedDriver(["a.example": slow, "b.example": ScriptedPage()])
        let r = runner(["a.example", "b.example"], driver, Sink())
        let task = Task { @MainActor in await r.run() }
        for _ in 0..<50 where driver.prepared.count < 2 { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(driver.prepared, ["a.example", "b.example"], "b was already loading before a finished")
        XCTAssertEqual(r.current?.entry.domain, "a.example")
        await task.value
    }

    func testASiteThatShowsNoConfirmationWaitsForThePersonThenRecordsItAsIncomplete() async {
        let page = ScriptedPage(outcomes: [.failed("no success message was shown")])
        let sink = Sink()
        let r = runner(["a.example"], ScriptedDriver(["a.example": page]), sink)
        let task = Task { @MainActor in await r.run() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(r.phase, .needsMore("no success message was shown"), "it stays on the page so the person can finish the extra step")
        XCTAssertTrue(sink.rows.isEmpty)
        r.next()
        await task.value
        XCTAssertEqual(sink.rows[0].1, .failed("no success message was shown"))
    }

    func testACheckThatAppearsAfterSendingIsWaitedForAgain() async {
        let page = ScriptedPage(outcomes: [.challenged("a reCAPTCHA puzzle"), .submitted(awaitingEmail: false)])
        let sink = Sink()
        let r = runner(["a.example"], ScriptedDriver(["a.example": page]), sink)
        await r.run()
        XCTAssertEqual(page.sends, 2)
        XCTAssertEqual(sink.rows[0].1, .submitted(awaitingEmail: false))
    }

    func testAPageThatWillNotLoadIsSkippedShownAsSkippedAndTheRunContinues() async {
        let sink = Sink()
        let r = runner(["a.example", "b.example"], ScriptedDriver(["a.example": nil, "b.example": ScriptedPage()]), sink)
        await r.run()
        XCTAssertEqual(sink.rows[0].1, .needsYou(AssistedRunner.unloadable), "skipped, not recorded as a failed attempt")
        XCTAssertEqual(sink.rows[1].1, .submitted(awaitingEmail: false))
        XCTAssertEqual(r.skippedCount, 1, "the screen is told to show the skip animation")
        XCTAssertTrue(r.finished)
    }

    func testAPageThatWillNotLoadAsTheOnlySiteEndsTheRun() async {
        let r = runner(["a.example"], ScriptedDriver(["a.example": nil]), Sink())
        await r.run()
        XCTAssertTrue(r.finished); XCTAssertEqual(r.skippedCount, 1)
    }
}


final class EmailFollowUpWordingTests: XCTestCase {
    func testThePortalsCheckYourEmailPageIsTrackedAsAFollowUp() {
        let page = "Check your email\nYour request is logged, and today's date is when our deadlines start. We've emailed a confirmation link to the address you gave. Nothing is removed until that link is clicked."
        XCTAssertTrue(FormRun.mentionsEmailFollowUp(page))
        XCTAssertEqual(FormRun.classifyConfirmed(page), .submitted(awaitingEmail: true))
        XCTAssertFalse(FormRun.mentionsEmailFollowUp("Your request is recorded. There is nothing else for you to do."))
    }
}

@MainActor
final class EmailInsteadTests: XCTestCase {
    private func item(_ host: String, email: String?) -> AssistedRunner.Item {
        let form = OptOutForm(page: URL(string: "https://\(host)/optout")!, method: "post", action: nil, fields: [FormField(type: "email", name: "email", label: "Email")], hops: 1)
        let entry = DirectoryEntry(id: host.replacingOccurrences(of: ".", with: "_"), domain: host, name: host, bucket: "direct", tier: .B, automation: .guided,
                                   optOutForm: form, contactEmail: email)
        return AssistedRunner.Item(entry: entry, form: form, plan: FillPlan(values: [], verdict: .ready))
    }

    func testASiteThatDidNotLoadOffersAnEmailWaitsForTheAnswerAndIsDoneOnceItIsSent() async {
        let driver = ScriptedDriverForEmail()
        var reported: [AutoOptOutResult] = []
        let r = AssistedRunner(items: [item("dead.example", email: "privacy@dead.example")], driver: driver) { _, result in reported.append(result) }
        r.pollInterval = 0.01; r.pauseAfterSent = 0
        let run = Task { @MainActor in await r.run() }
        for _ in 0..<200 where r.emailOffer == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(r.emailOffer?.domain, "dead.example", "the person is offered an email for the site that failed")
        XCTAssertFalse(r.finished, "the next site waits for the answer")
        r.answerEmailOffer(sent: true)
        await run.value
        XCTAssertEqual(r.results["dead_example"], .emailed)
        XCTAssertEqual(reported.last, .emailed, "saved as done, so the queue and the period count it, not only this screen")
        XCTAssertNil(r.emailOffer)
    }

    func testNoOfferWithoutAnAddressAndNoneForAPlainSkip() async {
        let r = AssistedRunner(items: [item("dead.example", email: nil)], driver: ScriptedDriverForEmail()) { _, _ in }
        r.pollInterval = 0.01; r.pauseAfterSent = 0
        await r.run()
        XCTAssertNil(r.emailOffer); XCTAssertTrue(r.finished)
    }
}

@MainActor
private final class ScriptedDriverForEmail: AssistedDriver {
    func prepare(_ form: OptOutForm, plan: FillPlan) async -> AssistedPage? { nil }
}

@MainActor
final class NoFormReasonTests: XCTestCase {
    private final class NoFormDriver: AssistedDriver {
        func prepare(_ form: OptOutForm, plan: FillPlan) async -> AssistedPage? { nil }
        func failureReason(for form: OptOutForm) -> String? { "noform" }
    }
    private func entry(_ host: String, email: String?) -> (DirectoryEntry, OptOutForm) {
        let form = OptOutForm(page: URL(string: "https://\(host)/contact-us")!, method: "post", action: nil, fields: [FormField(type: "email", name: "email", label: "Email")], hops: 1)
        return (DirectoryEntry(id: host.replacingOccurrences(of: ".", with: "_"), domain: host, name: host, bucket: "direct", tier: .B, automation: .guided, optOutForm: form, contactEmail: email), form)
    }

    func testAPageWithNoFormWaitsOnTheNoFormScreenForTheEmailInsteadOfCallingItUnloadable() async {
        let (e, form) = entry("contact.example", email: "privacy@contact.example")
        var got: [AutoOptOutResult] = []
        let r = AssistedRunner(items: [AssistedRunner.Item(entry: e, form: form, plan: FillPlan(values: [], verdict: .ready))], driver: NoFormDriver()) { _, res in got.append(res) }
        r.pollInterval = 0.01; r.pauseAfterSent = 0
        let run = Task { @MainActor in await r.run() }
        for _ in 0..<200 where r.emailOffer == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(r.phase, .noForm, "says no form exists, send an email instead")
        r.answerEmailOffer(sent: false)
        XCTAssertEqual(r.phase, .noForm); XCTAssertFalse(r.finished, "\"No\" to the mail prompt keeps waiting; it is not an answer")
        r.answerEmailOffer(sent: true); await run.value
        XCTAssertEqual(got.last, .emailed); XCTAssertTrue(r.finished)
    }

    func testAnEmailOnlySiteLoadsNothingAndCanBeSkipped() async {
        let (e, form) = entry("mail.example", email: "privacy@mail.example")
        var item = AssistedRunner.Item(entry: e, form: form, plan: FillPlan(values: [], verdict: .ready)); item.emailOnly = true
        var got: [AutoOptOutResult] = []
        let r = AssistedRunner(items: [item], driver: ScriptedDriverNeverLoads()) { _, res in got.append(res) }
        r.pollInterval = 0.01; r.pauseAfterSent = 0
        let run = Task { @MainActor in await r.run() }
        for _ in 0..<200 where r.phase != .noForm { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(r.phase, .noForm)
        r.skip(); await run.value
        XCTAssertEqual(got.last, .needsYou("skipped")); XCTAssertEqual(r.skippedCount, 1); XCTAssertTrue(r.finished)
    }

    private final class ScriptedDriverNeverLoads: AssistedDriver {
        func prepare(_ form: OptOutForm, plan: FillPlan) async -> AssistedPage? { XCTFail("an email-only site loads no page"); return nil }
    }
}

@MainActor
final class BlockWidgetTests: XCTestCase {
    func testABlockedProfileMessageAdvancesButTheBlockButtonAloneDoesNot() {
        XCTAssertEqual(FormRun.classifyConfirmed("Your profile has been blocked."), .submitted(awaitingEmail: false))
        XCTAssertEqual(FormRun.classifyConfirmed("The profile was successfully blocked. Changes may take 48 hours."), .submitted(awaitingEmail: false))
        if case .submitted = FormRun.classifyConfirmed("Name: Riva N Reed Age: 36 Block Profile") { XCTFail("a Block Profile button is not a confirmation") }
    }

    func testUSATraceAndItsSisterSiteAreBlockWidgets() {
        func item(_ host: String) -> AssistedRunner.Item {
            let form = OptOutForm(page: URL(string: "https://\(host)/your-privacy/")!, method: "post", action: nil, fields: [], hops: 1)
            let entry = DirectoryEntry(id: host, domain: host, name: host, bucket: "direct", tier: .B, automation: .guided, optOutForm: form)
            return AssistedRunner.Item(entry: entry, form: form, plan: FillPlan(values: [], verdict: .ready))
        }
        XCTAssertTrue(item("usatrace.com").blockWidget)
        XCTAssertTrue(item("quickpeopletrace.com").blockWidget)
        XCTAssertFalse(item("infotracer.com").blockWidget)
        XCTAssertTrue(item("open-public-records.com").handsOff)
        XCTAssertFalse(item("open-public-records.com").blockWidget)
        XCTAssertFalse(item("infotracer.com").handsOff)
    }
}

@MainActor
final class RateLimitTests: XCTestCase {
    func testABarePageSayingTooManyRequestsIsARateLimitNotAFailedForm() {
        XCTAssertEqual(FormRun.classify("Too many requests!!"), .failed(AutoOptOut.rateLimited))
        XCTAssertEqual(AutoOptOut.result(for: .failed(AutoOptOut.rateLimited)), .needsYou(AutoOptOut.rateLimited), "so no failed attempt is recorded against the site")
        XCTAssertNil(AutoOptOut.attempt(for: .needsYou(AutoOptOut.rateLimited), now: Date()))
    }

    private func familyItems(_ hosts: [String]) -> [AssistedRunner.Item] {
        hosts.map { host in
            let form = OptOutForm(page: URL(string: "https://\(host)/optout")!, method: "post", action: nil,
                                  fields: [FormField(type: "text", name: "InfoPay_Core_Components[fname]", label: "First name")], hops: 1)
            let entry = DirectoryEntry(id: host.replacingOccurrences(of: ".", with: "_"), domain: host, name: host, bucket: "direct", tier: .B, automation: .guided, optOutForm: form)
            return AssistedRunner.Item(entry: entry, form: form, plan: FillPlan(values: [], verdict: .ready))
        }
    }

    private final class Pages: AssistedDriver {
        func prepare(_ form: OptOutForm, plan: FillPlan) async -> AssistedPage? { Page() }
    }
    private final class Page: AssistedPage {
            func blockers() async -> [AssistedBlocker] { [] }
        func refill() async {}
        func send() async -> SubmitOutcome { .submitted(awaitingEmail: false) }
        func close() {}
    }

    func testTheSecondSiteOfOneCompanyWaitsBeforeItIsSent() async {
        let r = AssistedRunner(items: familyItems(["a.example", "b.example"]), driver: Pages()) { _, _ in }
        r.pollInterval = 0.01; r.pauseAfterSent = 0; r.familyGap = 0.5
        var sawPacing = false
        let run = Task { @MainActor in await r.run() }
        let start = Date()
        while !r.finished, Date().timeIntervalSince(start) < 5 {
            if case .pacing = r.phase { sawPacing = true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await run.value
        XCTAssertTrue(sawPacing, "it showed that it was waiting")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.45, "the second send came after the gap")
        XCTAssertEqual(r.results.values.filter { if case .submitted = $0 { return true } else { return false } }.count, 2)
    }
}

final class LooksFinishedTests: XCTestCase {
    func testCompletionMessagesAreRecognisedAndPlainThanksIsNot() {
        for t in ["Your removal is complete.", "Your record has been removed.", "Opt-out confirmed", "Your email has been verified.", "You have been opted out."] {
            XCTAssertTrue(FormRun.looksFinished(t), t)
        }
        for t in ["Thank you for your request", "Enter your email to remove your record", "We received your request"] {
            XCTAssertFalse(FormRun.looksFinished(t), t)
        }
    }
}
