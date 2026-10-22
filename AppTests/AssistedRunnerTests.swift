import XCTest
import WebKit
import OptOutKitCore
@testable import OptOutKit

// MARK: Scripted fakes

@MainActor
private final class ScriptedPage: AssistedPage {
    var blockerScript: [[AssistedBlocker]]          // what blockers() returns on each call; the last entry repeats
    var outcomes: [SubmitOutcome]                   // what send() returns on each call
    private(set) var refills = 0, sends = 0, polls = 0, closed = false
    var webView: WKWebView? { nil }
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

    func testAPageThatWillNotLoadIsReportedAndTheRunContinues() async {
        let sink = Sink()
        let r = runner(["a.example", "b.example"], ScriptedDriver(["a.example": nil, "b.example": ScriptedPage()]), sink)
        await r.run()
        XCTAssertEqual(sink.rows[0].1, .failed("the page would not load"))
        XCTAssertEqual(sink.rows[1].1, .submitted(awaitingEmail: false))
    }

    func testTheAppModelQueuesOnlySitesItCanFillAndHasNotSentRecently() throws {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        var me = try XCTUnwrap(m.selectedPerson)
        XCTAssertTrue(m.assistedItems(for: me).isEmpty, "with no name or email there is nothing to fill in")
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.emails = ["pat@example.com"]
        me.addresses = [Address(city: "Springfield", state: "IL")]
        m.update(me)
        let queue = m.assistedItems(for: me)
        XCTAssertGreaterThan(queue.count, 50)
        // once a site is recorded as sent it leaves the queue for a week
        let first = try XCTUnwrap(queue.first)
        m.recordAssisted(first.entry, .submitted(awaitingEmail: false), for: me)
        XCTAssertFalse(m.assistedItems(for: me).contains { $0.id == first.id })
    }
}

// MARK: The real web view, against a local page that imitates a bot check cleared by a person

@MainActor
final class WebAssistedDriverTests: XCTestCase {
    private let pat = Person(displayName: "Pat", names: [NameEntry(kind: .legal, name: "Pat Example")],
                            addresses: [Address(city: "Springfield", state: "IL")], emails: ["pat@example.com"])

    private func page(removeAfterMs: Int, blocker: String) -> String {
        """
        <html><body>
        <form id="f" onsubmit="event.preventDefault(); document.body.innerHTML = '<p>Thank you. Your request has been received.</p>';">
          <input name="first" placeholder="First Name*"><input name="last" placeholder="Last Name*"><input type="email" name="email">
          <button type="submit">Submit request</button>
        </form>
        \(blocker)
        <script>setTimeout(function(){ var b=document.getElementById('block'); if(b) b.remove(); }, \(removeAfterMs));</script>
        </body></html>
        """
    }

    private func item() -> AssistedRunner.Item {
        let form = OptOutForm(page: URL(string: "https://x.example/optout")!, method: "post", action: nil,
                              fields: [FormField(type: "text", name: "first", label: "First Name*"), FormField(type: "text", name: "last", label: "Last Name*"),
                                       FormField(type: "email", name: "email", label: "Email")], hops: 1)
        let entry = DirectoryEntry(id: "x_example", domain: "x.example", name: "x.example", bucket: "direct", tier: .B, automation: .guided,
                                   confidence: nil, optOutURL: nil, optOutForm: form, family: nil, familyParent: nil, template: nil,
                                   searchCheck: nil, signals: nil, profiled: nil)
        return AssistedRunner.Item(entry: entry, form: form, plan: FormFiller.plan(for: form, signals: nil, person: pat))
    }

    func testFillsTheFormWaitsForAPersonToClearTheCheckThenSendsAndReadsTheConfirmation() async {
        let challenge = "<iframe id=\"block\" src=\"https://www.google.com/recaptcha/api2/bframe\" style=\"width:300px;height:400px\"></iframe>"
        let sink = Sink()
        let runner = AssistedRunner(items: [item()], driver: WebAssistedDriver(htmlOverride: page(removeAfterMs: 6500, blocker: challenge))) { e, r in sink.rows.append((e.domain, r)) }
        runner.pollInterval = 0.3; runner.pauseAfterSent = 0
        var sawCheck = false
        let watcher = Task { @MainActor in while !runner.finished { if runner.phase == .waitingForCheck { sawCheck = true }; try? await Task.sleep(nanoseconds: 50_000_000) } }
        await runner.run(); watcher.cancel()
        XCTAssertTrue(sawCheck, "the bot check was shown to the person first")
        XCTAssertEqual(sink.rows.first?.1, .submitted(awaitingEmail: false), "after the check cleared it was sent and the confirmation was read")
    }

    func testATermsPromptIsWaitedForNotAccepted() async {
        let gate = "<div id=\"block\" role=\"dialog\">ACCEPTABLE USE POLICY AND TERMS. You must agree to continue. <button onclick=\"document.title='CLICKED'\">I Agree</button></div>"
        let sink = Sink()
        let runner = AssistedRunner(items: [item()], driver: WebAssistedDriver(htmlOverride: page(removeAfterMs: 6500, blocker: gate))) { e, r in sink.rows.append((e.domain, r)) }
        runner.pollInterval = 0.3; runner.pauseAfterSent = 0
        var sawTerms = false
        let watcher = Task { @MainActor in while !runner.finished { if runner.phase == .waitingForTerms { sawTerms = true }; try? await Task.sleep(nanoseconds: 50_000_000) } }
        await runner.run(); watcher.cancel()
        XCTAssertTrue(sawTerms, "the person was asked to accept the terms themselves")
        XCTAssertEqual(sink.rows.first?.1, .submitted(awaitingEmail: false))
    }

    func testAPageWithNoBlockerIsSentStraightAway() async {
        let sink = Sink()
        let runner = AssistedRunner(items: [item()], driver: WebAssistedDriver(htmlOverride: page(removeAfterMs: 100, blocker: ""))) { e, r in sink.rows.append((e.domain, r)) }
        runner.pollInterval = 0.2; runner.pauseAfterSent = 0
        await runner.run()
        XCTAssertEqual(sink.rows.first?.1, .submitted(awaitingEmail: false))
    }
}
