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

    func testTheFinishedPageIsPhotographedAndThePictureIsNotBlank() async throws {
        let html = page(extra: "<div style='height:300px;background:#1f7a3c;color:white;font-size:28px'>CONFIRMATION SHOWN</div>")
        let report = await FormRun.run(url: nil, html: html, plan: plan(fields), dryRun: false, maxWait: 8, capture: true)
        XCTAssertEqual(report.outcome, .submitted(awaitingEmail: true))
        let data = try XCTUnwrap(report.screenshot, "a screenshot was taken")
        let image = try XCTUnwrap(UIImage(data: data))
        XCTAssertGreaterThan(image.size.width, 300)
        // Not a blank white page: sample a column of pixels and expect some that are not white.
        let cg = try XCTUnwrap(image.cgImage)
        let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var nonWhite = 0, dark = 0
        for y in stride(from: 0, to: cg.height, by: 3) { for x in stride(from: 0, to: cg.width, by: 3) {
            let i = (y * cg.width + x) * 4
            if px[i] < 200 { nonWhite += 1 }
            if px[i] < 20 && px[i + 1] < 20 && px[i + 2] < 20 { dark += 1 }
        } }
        XCTAssertGreaterThan(nonWhite, 50, "the picture shows the page's text, not a blank sheet")
        XCTAssertLessThan(dark, (cg.width / 3) * (cg.height / 3) / 2, "and it is not a black sheet")
        let preview = await FormRun.run(url: nil, html: html, plan: plan(fields), dryRun: true, maxWait: 8, capture: false)
        XCTAssertNil(preview.screenshot)
    }

    func testAPageWithNoBackgroundIsPhotographedOnWhiteNotBlack() async throws {
        let report = await FormRun.run(url: nil, html: page(), plan: plan(fields), dryRun: false, maxWait: 8, capture: true)
        let image = try XCTUnwrap(UIImage(data: try XCTUnwrap(report.screenshot)))
        let cg = try XCTUnwrap(image.cgImage)
        let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let corner = (cg.height - 5) * cg.width * 4 + 5 * 4          // an empty corner of the page
        XCTAssertGreaterThan(Int(px[corner]), 235, "a page with no background shows white, not black")
    }

    func testOnlyNewTextCountsAndAnErrorIsNeverAConfirmation() {
        let before = "Opt out\nSome footer: your request has been received by our team in the past\nFirst name"
        let after = "Opt out\nSome footer: your request has been received by our team in the past\nThere was a problem with your submission. Please review the fields below."
        XCTAssertEqual(WebFormSubmitter.classifyAfterSending(before: before, after: after), .rejected("the site showed an error after sending"))
        XCTAssertEqual(WebFormSubmitter.classifyAfterSending(before: before, after: before), .failed("nothing on the page changed after sending"))
        XCTAssertEqual(WebFormSubmitter.classifyAfterSending(before: before, after: before + "\nThank you. We have received your request."), .submitted(awaitingEmail: false))
        XCTAssertEqual(FormRun.classify("Welcome to the Privacy Rights Portal. Click the Data Subject Rights tab."), .failed("no success message was shown"))
    }

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
