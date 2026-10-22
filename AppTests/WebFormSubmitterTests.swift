import XCTest
import OptOutKitCore
@testable import OptOutKit

/// The form filler, run against LOCAL test pages that imitate opt-out forms. No real site is contacted and no real
/// person's details are used: the profile is a made-up "Pat Example".
@MainActor
final class WebFormSubmitterTests: XCTestCase {
    private let pat = Person(displayName: "Pat", names: [NameEntry(kind: .legal, name: "Pat Example")],
                            addresses: [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")], emails: ["pat@example.com"])

    private func plan(_ fields: [(String, String, String)]) -> FillPlan {
        let form = OptOutForm(page: URL(string: "https://x.example/optout")!, method: "post", action: nil,
                              fields: fields.map { FormField(type: $0.0, name: $0.1, label: $0.2) }, hops: 1)
        return FormFiller.plan(for: form, signals: nil, person: pat)
    }

    /// A form that, when submitted, replaces the page with what it received, so the test can read it back.
    private func page(extra: String = "", message: String = "Thank you. Your request has been received. Check your email to confirm.") -> String {
        """
        <html><body>
        <form id="f" onsubmit="event.preventDefault(); document.body.innerHTML = '<p>\(message)</p><pre id=got>' + [first.value, last.value, email.value, state.value, city.value, ack.checked].join('|') + '</pre>';">
          <input name="first" placeholder="First Name*"><input name="last" placeholder="Last Name*">
          <input type="email" name="email"><input name="city">
          <select name="state"><option value="">Choose</option><option value="CA">California</option><option value="IL">Illinois</option></select>
          <input type="checkbox" name="ack">
          <button type="submit">Submit request</button>
        </form>\(extra)
        </body></html>
        """
    }

    private let fields: [(String, String, String)] = [("text", "first", "First Name*"), ("text", "last", "Last Name*"), ("email", "email", "Email"),
                                                      ("text", "city", "City"), ("select", "state", "State")]

    func testFillsTheFormFromTheProfileAndReportsTheSuccessMessage() async {
        let outcome = await WebFormSubmitter(maxWait: 8).submit(html: page(), plan: plan(fields), dryRun: false)
        XCTAssertEqual(outcome, .submitted(awaitingEmail: true))
    }

    func testTheValuesReallyReachedTheFieldsIncludingTheDropdown() async {
        // The page echoes what it received into the message the classifier reads.
        let echo = page(message: "Thank you. We have received: ")
        let outcome = await WebFormSubmitter(maxWait: 8).submit(html: echo, plan: plan(fields), dryRun: false)
        XCTAssertEqual(outcome, .submitted(awaitingEmail: false))
        // Read the received values with a second run that keeps the echo visible.
        let session = WebFormEchoProbe()
        let got = await session.run(html: echo, plan: plan(fields))
        XCTAssertEqual(got, "Pat|Example|pat@example.com|IL|Springfield|false", "dropdown picked Illinois by code; the checkbox stayed unticked")
    }

    func testADryRunFillsButNeverSends() async {
        let outcome = await WebFormSubmitter(maxWait: 6).submit(html: page(), plan: plan(fields), dryRun: true)
        XCTAssertEqual(outcome, .filledNotSubmitted)
    }

    func testAVisibleBotCheckStopsTheRunAndIsNeverSolved() async {
        let challenge = page(extra: "<iframe src=\"https://www.google.com/recaptcha/api2/bframe\" style=\"width:300px;height:400px\"></iframe>")
        let outcome = await WebFormSubmitter(maxWait: 6).submit(html: challenge, plan: plan(fields), dryRun: false)
        guard case .challenged(let why) = outcome else { return XCTFail("expected challenged, got \(outcome)") }
        XCTAssertTrue(why.contains("reCAPTCHA"))
    }

    func testABotCheckPageTextStopsTheRun() async {
        let outcome = await WebFormSubmitter(maxWait: 6).submit(html: "<body>Just a moment... checking your browser</body>", plan: plan(fields), dryRun: false)
        guard case .challenged = outcome else { return XCTFail("expected challenged, got \(outcome)") }
    }

    func testATermsPromptStopsTheRunWithoutAcceptingIt() async {
        let gate = "<div role=dialog>ACCEPTABLE USE POLICY AND TERMS. You must agree to continue. <button onclick=\"document.title='ACCEPTED'\">I Agree</button></div>"
        let outcome = await WebFormSubmitter(maxWait: 6).submit(html: page(extra: gate), plan: plan(fields), dryRun: false)
        guard case .challenged(let why) = outcome else { return XCTFail("expected challenged, got \(outcome)") }
        XCTAssertTrue(why.contains("terms"))
    }

    func testAcceptableUseTextInAPageFooterIsNotATermsPrompt() async {
        // Many sites repeat their acceptable-use text at the bottom of every page. With no "I agree" button there is nothing to accept.
        let footer = "<div id=\"footer\">ACCEPTABLE USE POLICY AND TERMS. You must follow these rules when using this site and must not misuse the records you find.</div>"
        let outcome = await WebFormSubmitter(maxWait: 8).submit(html: page(extra: footer), plan: plan(fields), dryRun: false)
        XCTAssertEqual(outcome, .submitted(awaitingEmail: true), "a footer is not a blocker")
    }

    func testAnUntickedCertificationBoxStopsTheRunAndIsNeverTickedForTheirOwner() async {
        let cert = "<label><input type=\"checkbox\" name=\"certify\"> I authorize you to contact me and I certify that I am the subject of this request.</label>"
        let outcome = await WebFormSubmitter(maxWait: 6).submit(html: page(extra: cert), plan: plan(fields), dryRun: false)
        guard case .challenged(let why) = outcome else { return XCTFail("expected challenged, got \(outcome)") }
        XCTAssertTrue(why.contains("certification"))
    }

    func testAnOptionalAgentBoxIsNotABlockerForSomeoneSubmittingForThemselves() async {
        let agent = "<label><input type=\"checkbox\" name=\"agent\"> I am an authorized agent submitting this request on behalf of someone else.</label>"
        let outcome = await WebFormSubmitter(maxWait: 8).submit(html: page(extra: agent), plan: plan(fields), dryRun: false)
        XCTAssertEqual(outcome, .submitted(awaitingEmail: true), "the agent box stays unticked and does not stop the form")
    }

    func testNoSuccessMessageMeansNothingIsClaimed() async {
        let silent = page(message: "Okay.")
        let outcome = await WebFormSubmitter(maxWait: 8).submit(html: silent, plan: plan(fields), dryRun: false)
        guard case .failed = outcome else { return XCTFail("expected failed, got \(outcome)") }
    }

    func testAFlaggedFieldIsReportedAsRejected() async {
        let bad = page(message: "Error: email is invalid. Please try again.")
        let outcome = await WebFormSubmitter(maxWait: 8).submit(html: bad, plan: plan(fields), dryRun: false)
        guard case .rejected = outcome else { return XCTFail("expected rejected, got \(outcome)") }
    }

    func testAPageWithoutTheFormFieldsFailsInsteadOfPretending() async {
        let outcome = await WebFormSubmitter(maxWait: 6).submit(html: "<body>Nothing to fill in here.</body>", plan: plan(fields), dryRun: false)
        guard case .failed = outcome else { return XCTFail("expected failed, got \(outcome)") }
    }
}

/// Fills a local page and reads back what the form had in it, to prove the values landed where they should.
@MainActor
private struct WebFormEchoProbe {
    func run(html: String, plan: FillPlan) async -> String {
        // Same steps as a real run, but the page stores what it received in document.title instead of sending it.
        let probe = html.replacingOccurrences(of: "document.body.innerHTML =", with: "document.title = [first.value, last.value, email.value, state.value, city.value, ack.checked].join('|'); document.body.innerHTML =")
        let result = await WebFormSubmitter(maxWait: 8).submitReturningTitle(html: probe, plan: plan)
        return result
    }
}
