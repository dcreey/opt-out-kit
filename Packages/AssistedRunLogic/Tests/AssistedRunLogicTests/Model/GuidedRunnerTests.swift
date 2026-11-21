import XCTest
import WebKit
import OptOutKitCore
@testable import AssistedRunLogic

@MainActor
private final class ScriptedGuidedPage: GuidedPage {
    var url: URL? = URL(string: "https://x.example/start")
    var text = "Welcome"
    var blockerScript: [[AssistedBlocker]] = [[]]
    var sendOutcomes: [SubmitOutcome] = [.submitted(awaitingEmail: false)]
    var fillCount = 1
    var scanCount = 1
    private(set) var scans = 0
    private(set) var loaded: [URL] = [], fills = 0, sends = 0, polls = 0, closed = false
    var webView: WKWebView? { nil }
    var whileLoading: (() -> Void)?
    func load(_ url: URL) async { loaded.append(url); self.url = url; whileLoading?() }
    func currentURL() -> URL? { url }
    func visibleText() async -> String { text }
    func fill(_ values: [FieldValue]) async -> Int { fills += 1; return fillCount }
    func scanAndFill(person: Person) async -> Int { scans += 1; return scanCount }
    func blockers() async -> [AssistedBlocker] { defer { polls += 1 }; return blockerScript[min(polls, blockerScript.count - 1)] }
    func send(_ values: [FieldValue]) async -> SubmitOutcome { defer { sends += 1 }; return sendOutcomes[min(sends, sendOutcomes.count - 1)] }
    func close() { closed = true }
}

private final class Log: @unchecked Sendable { var steps: [Int] = []; var sent: [AutoOptOutResult] = []; var issues: [IssueKind] = [] }

@MainActor
final class GuidedRunnerTests: XCTestCase {
    private let pat = Person(displayName: "Pat", names: [NameEntry(kind: .legal, name: "Pat Example")], emails: ["pat@example.com"])

    private func runner(_ plan: GuidedPlan, page: ScriptedGuidedPage, log: Log, resume: Int = 0, fill: [FieldValue] = []) -> GuidedRunner {
        let r = GuidedRunner(plan: plan, resumeAt: resume, person: pat, fillValues: fill, page: page,
                             onStepCompleted: { log.steps.append($0) }, onSent: { log.sent.append($0) }, onIssue: { log.issues.append($0) })
        r.pollInterval = 0.01
        return r
    }

    private func brokerPlan() -> GuidedPlan {
        let b = Broker(id: "pc", name: "PeopleConnect", tier: .C, covers: nil, signals: nil, fields: nil, steps: [
            Step(open: URL(string: "https://x.example/start")!),
            Step(copy: "email"),
            Step(say: "Enter your email and continue.", doneWhen: .init(urlContains: "verify")),
            Step(waitForEmail: .init(subject: "Confirm", withinMinutes: 15)),
            Step(say: "Check the birthdate.", confirm: true),
        ], recheckDays: 30, verified: nil)
        return GuidedPlanner.plan(for: b)
    }

    private func settle(_ r: GuidedRunner, until check: () -> Bool, seconds: Double = 3) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !check(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    private func manualPlan() -> GuidedPlan {
        GuidedPlanner.plan(for: DirectoryEntry(id: "m", domain: "manual.example", name: "m", bucket: "direct", tier: .B, automation: .guided, signals: []))
    }

    func testASiteWithNoKnownFormIsScannedAndFilledOnceAndAgainOnRequest() async {
        let page = ScriptedGuidedPage(), log = Log()
        let r = runner(manualPlan(), page: page, log: log)
        let task = Task { await r.run() }
        await settle(r) { r.flow.index >= 2 }
        XCTAssertEqual(page.scans, 1, "the page is scanned for the form and filled")
        XCTAssertEqual(page.fills, 0, "there were no known fields to fill")
        XCTAssertEqual(r.flow.index, 2, "filled: the person checks and submits next")
        r.fillAgain()
        await settle(r) { page.scans >= 2 }
        XCTAssertEqual(page.scans, 2, "the menu button tries the scan again, at any step")
        r.cancel(); await task.value
    }

    func testAScanThatFindsNoFormIsNotRepeatedEveryTickAndLeavesNextToThePerson() async {
        let page = ScriptedGuidedPage(), log = Log()
        page.scanCount = 0
        let r = runner(manualPlan(), page: page, log: log)
        let task = Task { await r.run() }
        await settle(r, until: { page.scans >= 1 })
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(page.scans, 1, "one scan per page, not one per poll")
        XCTAssertEqual(r.flow.index, 1)
        r.cancel(); await task.value
    }

    /// Crash reports from builds 37 and 40: the person tapped Next while the first page was still loading, the flow ended, and the runner unwrapped a step that was gone.
    func testTheFlowEndingWhileTheFirstPageLoadsDoesNotCrash() async {
        let page = ScriptedGuidedPage(), log = Log()
        let b = Broker(id: "one", name: "One", tier: .C, covers: nil, signals: nil, fields: nil,
                       steps: [Step(open: URL(string: "https://x.example/start")!)], recheckDays: 30, verified: nil)
        let r = runner(GuidedPlanner.plan(for: b), page: page, log: log)
        page.whileLoading = { r.next(); r.next() }
        await r.run()
        XCTAssertEqual(page.loaded.count, 1)
        XCTAssertNotNil(r.ending, "the run ends cleanly")
    }

    func testLoadingThePageFinishesTheOpenStepAndTheCountIsShown() async {
        let page = ScriptedGuidedPage(), log = Log()
        let r = runner(brokerPlan(), page: page, log: log)
        XCTAssertEqual(r.flow.progressLabel, "Step 1 of 5")
        let task = Task { await r.run() }
        await settle(r) { r.flow.index >= 1 }
        XCTAssertEqual(page.loaded.map(\.absoluteString), ["https://x.example/start"])
        XCTAssertEqual(r.flow.progressLabel, "Step 2 of 5")
        XCTAssertEqual(log.steps, [0])
        r.cancel(); await task.value
    }

    func testCopyingTheValueFinishesTheCopyStepAndPutsItOnTheClipboard() async {
        let phone = HeadlessPlatform(); AppPlatformHolder.current = phone
        let page = ScriptedGuidedPage(), log = Log()
        let r = runner(brokerPlan(), page: page, log: log)
        let task = Task { await r.run() }
        await settle(r) { r.flow.index == 1 }
        r.copyCurrent()
        XCTAssertEqual(phone.clipboard.last, "pat@example.com")
        XCTAssertEqual(r.flow.index, 2, "copying finished that step")
        XCTAssertEqual(log.steps, [0, 1])
        r.cancel(); await task.value
    }

    func testCopyingWithNoValueOnTheProfileSaysSoAndNeverCompletesTheStep() async {
        let page = ScriptedGuidedPage(), log = Log()
        let r = GuidedRunner(plan: brokerPlan(), person: Person(displayName: "NoEmail"), page: page, onStepCompleted: { log.steps.append($0) })
        r.pollInterval = 0.01
        let task = Task { await r.run() }
        await settle(r) { r.flow.index == 1 }
        r.copyCurrent()
        XCTAssertEqual(r.flow.index, 1, "nothing was copied, so the step is not done")
        XCTAssertTrue((r.status ?? "").contains("not on your profile"))
        r.cancel(); await task.value
    }

    func testNavigatingToTheRightPageFinishesAManualLookingStepByItself() async {
        let page = ScriptedGuidedPage(), log = Log()
        let r = runner(brokerPlan(), page: page, log: log, resume: 2)
        let task = Task { await r.run() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(r.flow.index, 2, "still waiting: the page has not changed yet")
        page.url = URL(string: "https://x.example/verify?token=1")          // the person submitted the form and the site moved on
        await settle(r) { r.flow.index == 3 }
        XCTAssertEqual(r.flow.index, 3, "the app saw the navigation and moved to the next step")
        XCTAssertEqual(r.status, "Step 3 done: we saw you finish it.")
        XCTAssertEqual(log.steps, [2])
        r.cancel(); await task.value
    }

    func testStepsItCannotDetectNeedTheNextButtonAndTheFlowFinishes() async {
        let page = ScriptedGuidedPage(), log = Log()
        let r = runner(brokerPlan(), page: page, log: log, resume: 3)
        let task = Task { await r.run() }
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(r.flow.progressLabel, "Step 4 of 5", "the email step has no detector: we cannot read the inbox")
        r.next()
        XCTAssertEqual(r.flow.progressLabel, "Step 5 of 5")
        r.next()
        await task.value
        XCTAssertEqual(r.ending, .finished)
        XCTAssertEqual(log.steps, [3, 4])
        XCTAssertTrue(page.closed)
    }

    func testCancelClosesThePageAndRecordsNothingElse() async {
        let page = ScriptedGuidedPage(), log = Log()
        let r = runner(brokerPlan(), page: page, log: log)
        let task = Task { await r.run() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        r.cancel()
        await task.value
        XCTAssertEqual(r.ending, .cancelled)
        XCTAssertTrue(page.closed)
        XCTAssertTrue(log.issues.isEmpty, "cancelling is not reporting a problem")
    }

    func testNotWorkingRecordsTheReasonAndClosesTheFlow() async {
        let page = ScriptedGuidedPage(), log = Log()
        let r = runner(brokerPlan(), page: page, log: log)
        let task = Task { await r.run() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        r.report(.brokenLink)
        await task.value
        XCTAssertEqual(log.issues, [.brokenLink])
        XCTAssertEqual(r.ending, .reported(.brokenLink))
        XCTAssertTrue(page.closed)
    }

    // MARK: a directory site: the app fills and sends, the person clears the check

    private func directoryPlan() -> (GuidedPlan, [FieldValue]) {
        let form = OptOutForm(page: URL(string: "https://x.example/optout")!, method: "post", action: nil,
                              fields: [FormField(type: "email", name: "email", label: "Email")], hops: 1)
        let entry = DirectoryEntry(id: "x", domain: "x.example", name: "x.example", bucket: "direct", tier: .B, automation: .guided, optOutForm: form)
        return (GuidedPlanner.plan(for: entry), FormFiller.plan(for: form, signals: nil, person: pat).values)
    }

    func testFillThenWaitForThePersonToClearTheCheckThenSendAndAddTheEmailStep() async {
        let page = ScriptedGuidedPage(), log = Log()
        page.blockerScript = [[.check("a reCAPTCHA checkbox")], [.check("a reCAPTCHA checkbox")], []]
        page.sendOutcomes = [.submitted(awaitingEmail: true)]
        let (plan, values) = directoryPlan()
        let r = runner(plan, page: page, log: log, fill: values)
        XCTAssertEqual(r.flow.progressLabel, "Step 1 of 4")
        let task = Task { await r.run() }
        await settle(r) { r.flow.total == 5 }
        XCTAssertEqual(page.sends, 1, "sent exactly once, after the check cleared")
        XCTAssertGreaterThan(page.fills, 0, "the app filled the form itself")
        XCTAssertEqual(r.flow.total, 5, "the total grew to include the email step")
        XCTAssertEqual(r.flow.progressLabel, "Step 5 of 5")
        XCTAssertEqual(log.sent, [.submitted(awaitingEmail: true)])
        r.next()
        await task.value
        XCTAssertEqual(r.ending, .finished)
    }

    func testWithAutoSendOffTheGuideFillsButNeverPressesSendAndNoticesTheConfirmation() async {
        let page = ScriptedGuidedPage(), log = Log()
        page.text = "Opt out form"
        let (plan, values) = directoryPlan()
        let r = runner(plan, page: page, log: log, fill: values)
        r.autoSubmit = { false }
        let task = Task { await r.run() }
        await settle(r) { r.status?.contains("Press the page") == true }
        XCTAssertEqual(page.sends, 0, "the app did not press send")
        XCTAssertGreaterThan(page.fills, 0, "but it filled the form")
        page.text = "Opt out form\nThank you. Your request has been received."      // the person pressed the page's own button
        await settle(r) { !log.sent.isEmpty }
        XCTAssertEqual(log.sent, [.submitted(awaitingEmail: false)], "the confirmation was noticed and saved")
        XCTAssertEqual(page.sends, 0)
        r.cancel(); await task.value
    }

    func testIfSendingCannotBeConfirmedThePersonFinishesItAndTapsNext() async {
        let page = ScriptedGuidedPage(), log = Log()
        page.sendOutcomes = [.failed("no success message was shown")]
        let (plan, values) = directoryPlan()
        let r = runner(plan, page: page, log: log, fill: values)
        let task = Task { await r.run() }
        await settle(r) { r.flow.current?.action == .send && (r.status ?? "").contains("could not confirm") }
        XCTAssertTrue((r.status ?? "").contains("tap Next step"))
        XCTAssertEqual(r.flow.current?.action, .send, "it does not pretend the form was sent")
        r.next()
        await task.value
        XCTAssertEqual(r.ending, .finished)
        XCTAssertTrue(log.sent.isEmpty, "nothing was recorded as sent")
    }
}

@MainActor
final class GuidedHealingTests: XCTestCase {
    /// A page that shows an error until the runner loads the healed address.
    private final class MovedPage: GuidedPage {
        var url: URL? = URL(string: "https://x.example/optout")
        var broken = true
        private(set) var loaded: [URL] = []
        var webView: WKWebView? { nil }
        func load(_ u: URL) async { loaded.append(u); url = u }
        func currentURL() -> URL? { url }
        func visibleText() async -> String { broken && url?.path == "/optout" ? "Page not found\nOops! That page can't be found." : "Request Portal. Opt out here." }
        func fill(_ values: [FieldValue]) async -> Int { 1 }
        func blockers() async -> [AssistedBlocker] { [] }
        func send(_ values: [FieldValue]) async -> SubmitOutcome { .submitted(awaitingEmail: false) }
        func close() {}
    }

    private let pat = Person(displayName: "Pat", names: [NameEntry(kind: .legal, name: "Pat Example")])
    private func plan() -> GuidedPlan {
        let form = OptOutForm(page: URL(string: "https://x.example/optout")!, method: "post", action: nil,
                              fields: [FormField(type: "email", name: "email", label: "Email")], hops: 1)
        return GuidedPlanner.plan(for: DirectoryEntry(id: "x", domain: "x.example", name: "x.example", bucket: "direct", tier: .B, automation: .guided, optOutForm: form))
    }

    func testABrokenPageIsHealedBeforeThePersonSeesAnError() async {
        let page = MovedPage()
        var healCalls = 0
        let r = GuidedRunner(plan: plan(), person: pat, page: page, healer: { healCalls += 1; return URL(string: "https://x.example/request-portal/") })
        r.pollInterval = 0.01
        let task = Task { await r.run() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(healCalls, 1)
        XCTAssertEqual(page.loaded.last?.path, "/request-portal", "the new page was loaded")
        XCTAssertGreaterThan(r.flow.index, 0, "and the open step counted as done")
        r.cancel(); await task.value
    }

    func testWhenTheLinkIsDeadAndNothingNewIsFoundThePersonIsToldToFindItThemselves() async {
        let page = MovedPage()
        let r = GuidedRunner(plan: plan(), person: pat, page: page, healer: { nil })
        r.pollInterval = 0.01
        let task = Task { await r.run() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(r.status?.contains("find it yourself") == true, r.status ?? "nil")
        XCTAssertNil(r.ending, "the guide stays open so they can look around the site")
        r.cancel(); await task.value
    }

    func testAWorkingLinkIsNotHealed() async {
        let page = MovedPage(); page.broken = false
        var calls = 0
        let r = GuidedRunner(plan: plan(), person: pat, page: page, healer: { calls += 1; return nil })
        r.pollInterval = 0.01
        let task = Task { await r.run() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(calls, 0)
        r.cancel(); await task.value
    }

    func testReportingABrokenLinkTriesToHealFirstThenReportsIfItCannot() async {
        let page = MovedPage()
        page.url = URL(string: "https://x.example/other")        // not an error page, so only the person's report triggers healing
        var reported: [IssueKind] = []
        let r = GuidedRunner(plan: plan(), person: pat, page: page, onIssue: { reported.append($0) }, healer: { nil })
        r.pollInterval = 0.01
        let task = Task { await r.run() }
        try? await Task.sleep(nanoseconds: 60_000_000)
        r.report(.brokenLink)
        await task.value
        XCTAssertEqual(reported, [.brokenLink], "nothing newer was found, so the report stands")
        XCTAssertEqual(r.ending, .reported(.brokenLink))
    }

    func testReportingABrokenLinkThatCanBeHealedKeepsTheGuideGoing() async {
        let page = MovedPage(); page.broken = false
        page.url = URL(string: "https://x.example/other")
        var reported: [IssueKind] = []
        let r = GuidedRunner(plan: plan(), person: pat, page: page, onIssue: { reported.append($0) }, healer: { URL(string: "https://x.example/request-portal") })
        r.pollInterval = 0.01
        let task = Task { await r.run() }
        try? await Task.sleep(nanoseconds: 60_000_000)
        r.report(.brokenLink)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(reported.isEmpty, "it found a newer page, so the site is not reported")
        XCTAssertNotEqual(r.ending, .reported(.brokenLink))
        XCTAssertEqual(page.loaded.last?.path, "/request-portal")
        r.cancel(); await task.value
    }
}

@MainActor
final class ListingGuideTests: XCTestCase {
    private final class SitePage: GuidedPage {
        var url: URL? = URL(string: "about:blank")
        private(set) var loaded: [URL] = []
        private(set) var filled: [[FieldValue]] = []
        var webView: WKWebView? { nil }
        func load(_ u: URL) async { loaded.append(u); url = u }
        func currentURL() -> URL? { url }
        func visibleText() async -> String { "A page" }
        func fill(_ values: [FieldValue]) async -> Int { filled.append(values); return values.count }
        func blockers() async -> [AssistedBlocker] { [] }
        func send(_ values: [FieldValue]) async -> SubmitOutcome { .submitted(awaitingEmail: true) }
        func close() {}
    }

    private let pat = Person(displayName: "Pat", names: [NameEntry(kind: .legal, name: "Pat Example")], emails: ["pat@example.com"])
    private func entry() -> DirectoryEntry {
        let form = OptOutForm(page: URL(string: "https://www.spokeo.com/optout")!, method: "get", action: nil,
                              fields: [FormField(type: "url", name: "url", label: "Enter URL here"), FormField(type: "email", name: "email", label: "Email")], hops: 1)
        let check = SearchCheck(status: .calibrated, searchURL: "https://www.spokeo.com/{first}-{last}", validPage: ["Spokeo"], noResults: nil,
                                ignoreLocation: nil, calibration: nil, method: nil, body: nil, needsBrowser: nil, candidate: nil, checked: nil)
        return DirectoryEntry(id: "spokeo_com", domain: "spokeo.com", name: "spokeo.com", bucket: "direct", tier: .A, automation: .guided,
                              optOutURL: form.page, optOutForm: form, searchCheck: check)
    }

    func testTheGuideSearchesForThePersonThenFillsTheirPickedListingIntoTheForm() async throws {
        let e = entry()
        let search = try XCTUnwrap(e.listingSearchURL(for: pat))
        let page = SitePage()
        let sentinel = FormFiller.plan(for: e.optOutForm!, signals: nil, person: pat).values
        let r = GuidedRunner(plan: GuidedPlanner.listingPlan(for: e, search: search), person: pat, fillValues: sentinel, page: page)
        r.pollInterval = 0.01
        let task = Task { await r.run() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(page.loaded.first, search, "it opened the site's results for this person")
        XCTAssertEqual(r.flow.index, 0)

        r.next()                                         // still on the results
        XCTAssertEqual(r.flow.index, 0)
        XCTAssertTrue(r.status?.contains("first") == true)

        let mine = URL(string: "https://www.spokeo.com/Pat-Example/Chicago-IL/p123")!
        page.url = mine                                   // the person taps their listing in the browser
        try await Task.sleep(nanoseconds: 60_000_000)
        r.next()                                         // "This is my listing"
        XCTAssertEqual(r.flow.chosenListing, mine)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(page.loaded.last?.path, "/optout", "then the opt-out page opened")
        let lastFill = try XCTUnwrap(page.filled.last)
        XCTAssertEqual(lastFill.first { $0.name == "url" }?.candidates, [mine.absoluteString], "their listing went into the form")
        XCTAssertEqual(lastFill.first { $0.name == "email" }?.candidates, ["pat@example.com"])
        r.cancel(); await task.value
    }

    func testAMinorOrPublicFigureIsNeverSearchedSoThereIsNoListingFlow() {
        var kid = pat; kid.isMinor = true
        XCTAssertNil(entry().listingSearchURL(for: kid))
    }

    func testSpokeoItselfGetsTheListingFlowFromTheShippedData() throws {
        let model = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                             defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        var me = try XCTUnwrap(model.selectedPerson)
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"; me.emails = ["pat@example.com"]
        me.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")]
        model.update(me); model.setContactEmail("pat@example.com")
        let spokeo = try XCTUnwrap(model.brokers.first { $0.id == "spokeo" })
        XCTAssertEqual(OptOutMethods.classify(spokeo, in: model.directory).method, .semiAutomatic)
        let runner = try XCTUnwrap(model.guidedRunner(for: spokeo))
        XCTAssertEqual(runner.flow.plan.steps.first?.title, "Open your own listing")
        let peopleconnect = try XCTUnwrap(model.brokers.first { $0.id == "peopleconnect" })
        XCTAssertEqual(model.guidedRunner(for: peopleconnect)?.flow.plan.steps.first?.title, "Open suppression.peopleconnect.us", "other walkthroughs are unchanged")
    }
}

@MainActor
final class NextSiteOfferTests: XCTestCase {
    private func entry(_ d: String) -> DirectoryEntry {
        DirectoryEntry(id: d, domain: d, name: d, bucket: "direct", tier: .B, automation: .guided, signals: [])
    }
    private func row(_ d: String, _ e: DirectoryEntry?) -> SiteRow {
        SiteRow(domain: d, entry: e, task: nil, status: .todo, date: nil, inRegion: true)
    }

    func testTheOfferIsTheFirstSiteStillUpNextThatWasNotJustWalkedThrough() {
        var rows = SiteRows()
        rows.todo = [row("a.example", entry("a.example")), row("none.example", nil), row("b.example", entry("b.example")), row("c.example", entry("c.example"))]
        XCTAssertEqual(rows.nextToOffer(excluding: ["a.example"])?.domain, "b.example", "skips the site just finished and rows with no page of their own")
        XCTAssertEqual(rows.nextToOffer(excluding: ["a.example", "b.example"])?.domain, "c.example")
        XCTAssertNil(rows.nextToOffer(excluding: ["a.example", "b.example", "c.example"]), "nothing left: no question is asked")
    }
}
