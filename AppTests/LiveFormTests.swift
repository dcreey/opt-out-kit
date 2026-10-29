import XCTest
import OptOutKitCore
@testable import OptOutKit

/// The live form path, against local pages that copy the traps found on real opt-out pages (a cookie prompt over the form, a free-trial form
/// above the real one, "who is this request for" choices, a request-type list, a button that does not say "submit"). Nothing is sent anywhere.
@MainActor
final class LiveFormTests: XCTestCase {
    private let pat = Person(displayName: "Pat", names: [NameEntry(kind: .legal, name: "Pat Example")],
                             addresses: [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")], emails: ["pat@example.com"])

    private func page(button: String = "OPT ME OUT") -> String {
        """
        <html><body>
        <div id="onetrust-banner"><button id="onetrust-reject-all-handler" onclick="document.getElementById('onetrust-banner').remove()">Reject All</button></div>
        <form id="trial" onsubmit="event.preventDefault()"><input type="email" name="email" placeholder="Enter your company email"><button type="submit">Get free trial</button></form>
        <form id="opt" onsubmit="event.preventDefault(); var d=new FormData(this); var got=[]; d.forEach(function(v,k){got.push(k+'='+v);}); document.body.innerHTML='<p>Your request has been received. Check your email to confirm.</p><pre>'+got.join('&')+'</pre>';">
          <h2>Do Not Sell My Personal Information</h2>
          <fieldset><legend>Who is this request for?</legend>
            <label><input type="radio" name="who" value="me" required> Myself</label>
            <label><input type="radio" name="who" value="dead"> A deceased individual</label>
            <label><input type="radio" name="who" value="agent"> Someone I'm authorized to represent</label></fieldset>
          <label>First name *<input name="fn"></label>
          <label>Last name *<input name="ln"></label>
          <label>Email *<input type="email" name="em"></label>
          <label>State *<select name="st"><option value="">Select</option><option value="IL">Illinois</option><option value="CA">California</option></select></label>
          <label>ZIP code<input name="zip"></label>
          <label><input type="checkbox" name="req" value="optout"> Opt out of targeted advertising</label>
          <label><input type="checkbox" name="req" value="access"> Request access to my information</label>
          <label><input type="checkbox" name="req" value="delete"> Request deletion of my information</label>
          <button type="button" onclick="this.form.requestSubmit()">\(button)</button>
        </form></body></html>
        """
    }

    func testItDeniesTheCookiePromptPicksTheRealFormChoosesTheOptOutOptionsAndPressesAButtonThatDoesNotSaySubmit() async {
        let report = await FormRun.runLive(url: nil, html: page(), person: pat, dryRun: false, maxWait: 6, capture: false)
        XCTAssertEqual(report.outcome, .submitted(awaitingEmail: true), FormRun.debugLastPageText)
        let got = FormRun.debugLastPageText
        for expected in ["who=me", "fn=Pat", "ln=Example", "em=pat@example.com", "st=IL", "zip=62701", "req=optout", "req=delete"] {
            XCTAssertTrue(got.contains(expected), "\(expected) in: \(got)")
        }
        XCTAssertFalse(got.contains("req=access"), "access is not part of an opt-out")
        XCTAssertFalse(got.contains("who=dead") || got.contains("who=agent"))
    }

    func testAPreviewFillsAndChoosesButSendsNothing() async {
        let report = await FormRun.runLive(url: nil, html: page(), person: pat, dryRun: true, maxWait: 6, capture: false)
        XCTAssertEqual(report.outcome, .filledNotSubmitted)
    }

    func testTheOptOutFormIsPickedOverMarketingForms() {
        func f(_ token: String, _ fields: [(String, String)], buttons: [String], text: String) -> LiveForm {
            LiveForm(token: token, action: "", method: "get", visible: true,
                     fields: fields.enumerated().map { LiveField(token: "\(token)-\($0.offset)", name: $0.element.1, type: $0.element.0, label: $0.element.1, required: false, visible: true) },
                     buttons: buttons, text: text)
        }
        let trial = f("f0", [("email", "email")], buttons: ["Get free trial"], text: "")
        let subscribe = f("f1", [("email", "email")], buttons: ["Subscribe"], text: "Subscribe")
        let real = f("f2", [("text", "First name"), ("text", "Last name"), ("email", "Email")], buttons: ["Submit Privacy Request"], text: "Your privacy rights")
        let optMeOut = f("f3", [("email", "E-mail")], buttons: ["OPT ME OUT"], text: "")
        let device = f("f4", [("text", "Enter device ID")], buttons: ["OPT ME OUT"], text: "AdID IDFA")
        XCTAssertEqual(LiveFormPicker.pick([trial, subscribe, real])?.token, "f2")
        XCTAssertEqual(LiveFormPicker.pick([optMeOut, device])?.token, "f3", "the email form, not the device-ID one")
        XCTAssertNil(LiveFormPicker.pick([trial, subscribe]), "a page with only marketing forms has no opt-out form")
    }

    /// Veraset's footer box: one email input, a plain "Submit" button, and only "By subscribing, you consent to our Privacy Policy and receive updates" around it.
    func testAFooterNewsletterBoxWithAPrivacyLinkIsNotAnOptOutForm() {
        var box = LiveForm(token: "n", action: "", method: "get", visible: true,
                           fields: [LiveField(token: "n-0", name: "Email", type: "email", label: "Enter your email", required: true, visible: true)],
                           buttons: ["Submit"], text: "")
        box.ctx = "By subscribing, you consent to our Privacy Policy and receive updates."
        XCTAssertNil(LiveFormPicker.pick([box], pageContext: "/legal/do-not-sell-request Do Not Sell Request"), "a newsletter box is never filled, even on a do-not-sell page")
    }

    func testALeadOrReportButtonIsNeverAnOptOutForm() {
        for label in ["Get My FAFSA Guide", "Show My Report FREE"] {
            let box = LiveForm(token: "l", action: "", method: "post", visible: true,
                               fields: [LiveField(token: "l-0", name: "email", type: "email", label: "Email", required: true, visible: true)],
                               buttons: [label], text: "Enter your email to continue")
            XCTAssertNil(LiveFormPicker.pick([box], pageContext: "/your-privacy-choices Your privacy choices"), label)
        }
    }

    /// Mediawallah, Skydeo: a newsletter box in a block that also holds the footer's "Do Not Sell My Personal Information" link.
    func testANewsletterBoxBesideADoNotSellLinkIsStillANewsletterBox() {
        var box = LiveForm(token: "n", action: "", method: "post", visible: true,
                           fields: [LiveField(token: "n-0", name: "EMAIL", type: "email", label: "Email", required: true, visible: true),
                                    LiveField(token: "n-1", name: "_mc4wp_honeypot", type: "text", label: "", required: false, visible: true)],
                           buttons: ["Submit"], text: "Email Submit")
        box.ctx = "Sign Up for Our Newsletter Access our exclusive insights and updates Do Not Sell My Personal Information Privacy Policy"
        XCTAssertNil(LiveFormPicker.pick([box], pageContext: "/donotsell Do Not Sell"))
    }
}
