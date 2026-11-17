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

    /// peoplewhiz.com: its removal page opens on a "Search Now" form (first name, last name, city, state) under "Remove Your Personal Information From Our Search Results".
    /// That search is the first step of the removal and is filled; the same search box at the top of its privacy policy is not.
    func testASearchStepUnderARemoveYourInformationHeadingIsFilledButAPlainSearchBoxIsNot() {
        func search(head: String) -> LiveForm {
            var f = LiveForm(token: "s", action: "https://www.peoplewhiz.com/remove-my-info", method: "get", visible: true,
                             fields: ["First Name", "Last Name", "City"].enumerated().map { LiveField(token: "s-\($0.offset)", name: $0.element, type: "text", label: $0.element, required: false, visible: true) }
                                + [LiveField(token: "s-3", name: "state", type: "select", label: "State", required: false, visible: true)],
                             buttons: ["Search Now"], text: "")
            f.head = head
            return f
        }
        XCTAssertEqual(LiveFormPicker.pick([search(head: "Remove Your Personal Information From Our Search Results")], pageContext: "/remove-my-info Remove My Info - PeopleWhiz")?.token, "s")
        XCTAssertEqual(LiveFormPicker.pick([search(head: "")], pageContext: "/remove-my-info Remove My Info - PeopleWhiz")?.token, "s", "the heading may sit where the form's own lookup cannot see it; the page's address and title say it too")
        XCTAssertNil(LiveFormPicker.pick([search(head: "Search Public Records")], pageContext: "/privacy background checks PeopleWhiz Privacy Policy"), "a search box on a policy page is not an opt-out")
    }

    /// Veraset's footer box: one email input, a plain "Submit" button, and only "By subscribing, you consent to our Privacy Policy and receive updates" around it.
    func testAFooterNewsletterBoxWithAPrivacyLinkIsNotAnOptOutForm() {
        var box = LiveForm(token: "n", action: "", method: "get", visible: true,
                           fields: [LiveField(token: "n-0", name: "Email", type: "email", label: "Enter your email", required: true, visible: true)],
                           buttons: ["Submit"], text: "")
        box.ctx = "By subscribing, you consent to our Privacy Policy and receive updates."
        XCTAssertNil(LiveFormPicker.pick([box], pageContext: "/legal/do-not-sell-request Do Not Sell Request"), "a newsletter box is never filled, even on a do-not-sell page")
    }

    /// Enformion's footer "Stay Updated" form: first name, last name, business email, industry and a "Submit" button, on a page about the right to opt out.
    func testABusinessFooterFormIsNotFilledOnADoNotSellPage() {
        func field(_ i: Int, _ type: String, _ label: String) -> LiveField { LiveField(token: "b-\(i)", name: label, type: type, label: label, required: true, visible: true) }
        var footer = LiveForm(token: "b", action: "", method: "post", visible: true,
                              fields: [field(0, "text", "First name*"), field(1, "text", "Last name*"), field(2, "email", "Business email*"), field(3, "select", "Industry*")],
                              buttons: ["Submit"], text: "")
        footer.ctx = "Stay Updated"
        XCTAssertNil(LiveFormPicker.pick([footer], pageContext: "https://www.enformion.com/do-not-sell/ Do Not Sell My Personal Information Right to Opt-Out"))
        let real = LiveForm(token: "r", action: "", method: "post", visible: true,
                            fields: [field(0, "text", "First name"), field(1, "text", "Last name"), field(2, "email", "Email")], buttons: ["Submit"], text: "Do Not Sell/Right to Opt-out")
        XCTAssertEqual(LiveFormPicker.pick([footer, real], pageContext: "Right to Opt-out")?.token, "r")
    }

    /// Peoplefinders' "Record Suppression Form": name, phone, birth date and address, with an email box the page ships switched off ("opt-out"). It comes after the emailed link.
    func testAFormWhoseEmailBoxIsSwitchedOffIsNotFilled() {
        func field(_ i: Int, _ type: String, _ label: String, disabled: Bool? = nil) -> LiveField { LiveField(token: "p-\(i)", name: "", type: type, label: label, required: true, visible: true, disabled: disabled) }
        let later = LiveForm(token: "p", action: "", method: "post", visible: true,
                             fields: [field(0, "text", "First Name"), field(1, "text", "Last Name"), field(2, "email", "Email", disabled: true), field(3, "tel", "Phone"), field(4, "text", "Street Address")],
                             buttons: ["Submit"], text: "Record Suppression Form Please fill out the form below and then press the Submit button. we will locate your record and remove it")
        XCTAssertNil(LiveFormPicker.pick([later], pageContext: "Opt Out - PeopleFinders Do Not Sell My Personal Information Right to Opt-out"))
        let first = LiveForm(token: "q", action: "", method: "post", visible: true,
                             fields: [field(0, "text", "First Name"), field(1, "text", "Last Name"), field(2, "email", "Email")], buttons: ["Submit"], text: "Right to Opt-Out")
        XCTAssertEqual(LiveFormPicker.pick([later, first], pageContext: "Right to Opt-out")?.token, "q")
    }

    /// Forms the Chrome load check (2026-11-13) found being picked on pages about privacy: contact, quote, consultation, newsletter, sign-in and navigation "forms".
    func testContactQuoteNewsletterLoginAndNavigationFormsAreNotOptOutForms() {
        func f(_ token: String, _ fields: [(String, String)], buttons: [String], text: String, ctx: String? = nil) -> LiveForm {
            var form = LiveForm(token: token, action: "", method: "post", visible: true,
                                fields: fields.enumerated().map { LiveField(token: "\(token)-\($0.offset)", name: $0.element.1, type: $0.element.0, label: $0.element.1, required: false, visible: true) },
                                buttons: buttons, text: text)
            form.ctx = ctx; return form
        }
        let ctx = "Right to Opt-out Privacy Request"
        let reportBox = f("a", [("text", "Name"), ("email", "Email"), ("tel", "Telephone"), ("textarea", "Your Message")], buttons: ["Submit"], text: "What to report Name Email Your Message")
        let quote = f("b", [("text", "Name"), ("email", "Email"), ("tel", "Phone"), ("text", "Website"), ("textarea", "Question or comments")], buttons: ["GET A QUOTE"], text: "")
        let consult = f("c", [("text", "Full Name"), ("email", "Email Address"), ("textarea", "Describe Your Research")], buttons: ["SUBMIT REQUEST"], text: "Request a Consultation")
        let news = f("d", [("email", "Enter your email"), ("checkbox", "I agree to receive communications from us")], buttons: ["Submit"], text: "Join the newsletter to stay updated")
        let login = f("e", [("text", "User Name"), ("password", "Password:"), ("email", "Email"), ("text", "First"), ("text", "Last")], buttons: ["Submit Your Request"], text: "Please identify yourself")
        let nav = f("g", [("checkbox", "Open navigation menu"), ("radio", "Close submenu")], buttons: ["Open navigation menu"], text: "")
        let human = f("h", [("checkbox", "I am human")], buttons: [], text: "Confirm you are human")
        for form in [reportBox, quote, consult, news, login, nav, human] { XCTAssertNil(LiveFormPicker.pick([form], pageContext: ctx), form.token) }
        var headed = f("i", [("text", "Name"), ("email", "Email"), ("tel", "Telephone"), ("textarea", "Your Message")], buttons: ["Submit"], text: "Name Email Telephone Your Message")
        headed.head = "What to report"
        XCTAssertNil(LiveFormPicker.pick([headed], pageContext: ctx), "the heading above the form says what it is")
        let masked = f("m", [("text", "Name"), ("password", "Last 4 digits of Social Security Number"), ("email", "Email Address")], buttons: ["Submit Request"], text: "Non-Disclosure/Opt-Out Request")
        XCTAssertEqual(LiveFormPicker.pick([masked], pageContext: ctx)?.token, "m", "a masked box is not an account password")
        let jump = f("j", [("select", "DATA PRODUCTS"), ("select", "QUICK NAVIGATION")], buttons: [], text: "")
        XCTAssertNil(LiveFormPicker.pick([jump], pageContext: "/california-privacy-rights"), "a jump-to menu is not a request")
        var choose = f("k", [("select", "Please choose from the following options")], buttons: [], text: "Opt out Delete my information"); choose.head = "Privacy Rights Form"
        XCTAssertEqual(LiveFormPicker.pick([choose], pageContext: "/privacy-rights")?.token, "k", "a request-type menu under a privacy heading is the first step of a request")
        let real = f("r", [("text", "First name"), ("text", "Last name"), ("email", "Email")], buttons: ["Submit Privacy Request"], text: "Your privacy rights")
        XCTAssertEqual(LiveFormPicker.pick([reportBox, quote, real], pageContext: ctx)?.token, "r")
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

    /// OneTrust's privacy portal: the only form asks "State of Residence" and a captcha, and the page says what it is for in its intro.
    func testAPortalFormThatOnlyAsksForTheStateIsPickedFromThePagesIntro() {
        let portal = form("p", [("text", "State of Residence"), ("text", "Captcha")], buttons: ["Submit"], text: "State of Residence Submit")
        XCTAssertNil(LiveFormPicker.pick([portal], pageContext: "/webform/1/2"), "with nothing saying what the page is for, it is not taken for an opt-out")
        let intro = "/webform/1/2 Privacy Web Form You may have rights with respect to your personal information. Complete this form to exercise these rights."
        XCTAssertEqual(LiveFormPicker.pick([portal], pageContext: intro)?.token, "p")
    }

    /// affordablebackgroundchecks.com: no request form and no email, only a contact form. On that site the contact form is the opt-out (the request goes in its message box);
    /// its people search above it is not, and on any other site a contact form is still refused.
    func testTheContactFormOfASiteThatTakesRequestsOnlyThereIsPickedAndNoOtherContactFormIs() {
        let search = form("f0", [(type: "text", label: "FIRST NAME"), (type: "text", label: "LAST NAME"), (type: "select-one", label: "state")], buttons: ["Search Now"])
        let contact = form("f1", [(type: "text", label: "YOUR NAME"), (type: "email", label: "YOUR EMAIL"), (type: "select-one", label: "subject"), (type: "textarea", label: "YOUR MESSAGE")], buttons: ["Send Message"])
        let page = "/contact.php Contact Us | Affordable Background Checks"
        XCTAssertEqual(LiveFormPicker.pick([search, contact], pageContext: page)?.token, "f1")
        XCTAssertNil(LiveFormPicker.pick([search, contact], pageContext: "/contact Contact Us | Some Other Site"), "a contact form is refused anywhere else")
    }
}
