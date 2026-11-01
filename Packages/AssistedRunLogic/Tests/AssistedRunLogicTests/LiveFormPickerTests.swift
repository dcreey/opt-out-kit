import XCTest
import OptOutKitCore
@testable import AssistedRunLogic

/// Which form on a page is the opt-out: the picking rules for live pages, tested on plain descriptions of forms, no web view.
final class LiveFormPickerTests: XCTestCase {
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

    private func form(_ token: String, _ fields: [(type: String, label: String)], buttons: [String], text: String = "", ctx: String? = nil) -> LiveForm {
        var f = LiveForm(token: token, action: "", method: "post", visible: true,
                         fields: fields.enumerated().map { LiveField(token: "\(token)-\($0.offset)", name: $0.element.label, type: $0.element.type, label: $0.element.label, required: false, visible: true) },
                         buttons: buttons, text: text)
        f.ctx = ctx
        return f
    }

    /// nordicdataresources.com: an email opt-out, a device-ID opt-out, and (on other pages) newsletter and contact forms. Only forms whose own words say opt-out are sent after the first.
    func testOnlyFormsThatAreSpecificallyOptOutsAreSentAfterTheFirst() {
        let email = form("a", [("email", "E-mail")], buttons: ["Opt me out"], text: "Opt out by email")
        let device = form("d", [("radio", "GAID"), ("radio", "IDFA"), ("text", "Device ID")], buttons: ["Opt me out"], text: "Opt out of Mobile ID")
        let newsletter = form("b", [("email", "Your email")], buttons: ["Subscribe to our newsletter"], text: "Stay in touch")
        let contact = form("c", [("text", "Name"), ("email", "Email"), ("textarea", "How can we help?")], buttons: ["Send message"], text: "Questions?")
        let ctx = "Opt-Out Information"
        XCTAssertTrue(LiveFormPicker.isDedicatedOptOut(email, pageContext: ctx))
        XCTAssertTrue(LiveFormPicker.isDedicatedOptOut(device, pageContext: ctx))
        XCTAssertFalse(LiveFormPicker.isDedicatedOptOut(newsletter, pageContext: ctx))
        XCTAssertFalse(LiveFormPicker.isDedicatedOptOut(contact, pageContext: ctx), "a contact form on an opt-out page is still a contact form")
    }

    /// Melissa's suppression list for deceased people is not the opt-out of a living person.
    func testAFormForADeceasedPersonIsScoredBelowTheRealOptOut() {
        let deceased = form("x", [("text", "First name"), ("text", "Last name"), ("email", "Email")], buttons: ["Opt out"], text: "Deceased suppression request: add a deceased person to the list")
        let real = form("y", [("text", "First Name"), ("text", "Last Name"), ("email", "Email")], buttons: ["Opt out"], text: "Consumer privacy request")
        XCTAssertGreaterThan(LiveFormPicker.score(real), LiveFormPicker.score(deceased))
        XCTAssertEqual(LiveFormPicker.pick([deceased, real])?.token, "y", "even when the deceased form comes first on the page")
    }

    func testTheLiveFormBecomesAFormTheFillerReadsWithTheHeadingAsLabel() {
        let f = form("t", [("text", "First Name"), ("text", "Street Address")], buttons: ["Send"])
        let asForm = f.asOptOutForm(page: URL(string: "https://x.example/")!)
        XCTAssertEqual(asForm.fields.map(\.label).map { $0.components(separatedBy: " | ").first }, ["First Name", "Street Address"])
        XCTAssertEqual(asForm.fields.map(\.name), ["t-0", "t-1"], "each box is found again by its token")
    }
}
