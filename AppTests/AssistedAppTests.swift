import XCTest
import WebKit
import OptOutKitCore
@testable import OptOutKit

private final class Sink: @unchecked Sendable { var rows: [(String, AutoOptOutResult)] = [] }

@MainActor
final class AssistedQueueTests: XCTestCase {

    func testTheAppModelQueuesOnlySitesItCanFillAndHasNotSentRecently() throws {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        var me = try XCTUnwrap(m.selectedPerson)
        XCTAssertTrue(m.assistedItems(for: me).isEmpty, "with no name or email there is nothing to fill in")
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"; me.emails = ["pat@example.com"]
        me.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")]
        m.update(me); m.setContactEmail("pat@example.com")
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
                            addresses: [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")], emails: ["pat@example.com"])

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

    /// nordicdataresources.com: an email form, a cookie button and a device-ID form on one page. Both forms are sent, the device-ID one with this phone's IDFA.
    func testEveryOptOutFormOnAPageIsFilledAndSentIncludingTheDeviceIDOne() async throws {
        let html = """
            <html><body>
            <h3>Opt out of segments by email</h3>
            <form id="e" onsubmit="event.preventDefault(); document.getElementById('log').innerText += ' EMAIL-SENT:' + this.querySelector('input[type=email]').value;">
              <input id="email-input" type="email" placeholder="E-mail"><button type="submit" class="optOutBtn">Opt me out</button></form>
            <h3>Opt out of third-party cookies</h3><button id="cookie-btn" class="optOutBtn">Click to opt out</button>
            <h3>Opt out of Mobile ID</h3>
            <form id="m" novalidate onsubmit="event.preventDefault(); document.getElementById('log').innerText += ' MAID-SENT:' + this.querySelector('input[type=radio]:checked').value + ':' + this.querySelector('input[type=text]').value;">
              <label><input type="radio" name="id_type" value="AdID" checked> GAID</label><label><input type="radio" name="id_type" value="IDFA"> IDFA</label>
              <input id="maid-input" type="text" placeholder="Device ID"><button type="submit" class="optOutBtn">Opt me out</button></form>
            <p id="log">LOG</p>
            </body></html>
            """
        let id = "11111111-2222-3333-4444-555555555555"
        let driver = WebAssistedDriver(htmlOverride: html, person: pat, advertisingID: id)
        let form = OptOutForm(page: URL(string: "https://x.example/opt-out/")!, method: "get", action: nil, fields: [FormField(type: "email", name: "email-input", label: "E-mail")], hops: 1)
        let prepared = await driver.prepare(form, plan: FormFiller.plan(for: form, signals: nil, person: pat))
        let page = try XCTUnwrap(prepared)
        defer { page.close() }
        _ = await page.send()
        let more = await page.moreForms()
        XCTAssertTrue(more, "the second form is next")
        _ = await page.send()
        let none = await page.moreForms()
        XCTAssertFalse(none, "and that was all of them (the cookie button is not a form)")
        let log = await page.pageText()
        XCTAssertTrue(log.contains("EMAIL-SENT:pat@example.com"), log)
        XCTAssertTrue(log.contains("MAID-SENT:IDFA:\(id)"), "this phone's IDFA, not the Android GAID: \(log)")
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
