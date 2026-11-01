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

    /// A country-code menu beside the phone box already says +1, so the box takes the number alone; and what the person typed is not overwritten.
    func testAPhoneBoxBesideACountryCodeMenuTakesTheNumberAloneAndPersonEditsSurviveARefill() async throws {
        let html = """
        <html><body><form id="f" onsubmit="event.preventDefault()">
          <label>First name *<input name="fn"></label><label>Last name *<input name="ln"></label>
          <label>Email *<input type="email" name="em"></label>
          <div><select name="cc"><option value="us" selected>United States (+1)</option><option value="mx">Mexico (+52)</option></select>
          <input type="tel" name="phone" placeholder="Phone number"></div>
          <button type="submit">Opt out</button></form></body></html>
        """
        var me = pat; me.phones = ["+1 773 633 1564"]
        let session = WebViewSession.make()
        defer { session.close() }
        try await session.loadHTML(html)
        let forms = await session.discoverForms(waitForFrames: false)
        let form = try XCTUnwrap(forms.first)
        let plan = FormFiller.plan(for: form.asOptOutForm(page: URL(string: "https://local.test/")!), signals: nil, person: me)
        _ = await session.fillLive(plan.values)
        func read(_ n: String) async -> String { (await session.evalLive("document.querySelector('[name=\"\(n)\"]').value") as? String) ?? "" }
        let phone = await read("phone")
        XCTAssertEqual(phone, "7736331564", "digits only, no +1, spaces or punctuation: \(phone)")
        // The person retypes the first name (a real keystroke marks the box; the test marks it the same way) and a refill leaves it.
        _ = await session.evalLive("(function(){var e=document.querySelector('[name=\"fn\"]'); e.value='Patricia'; e.setAttribute('data-ook-user','1');})()")
        _ = await session.fillLive(plan.values)
        let first = await read("fn")
        XCTAssertEqual(first, "Patricia")
        // A box holding something we did not type is left alone even when the person never touched it (no user mark), until it matches what we typed.
        _ = await session.evalLive("(function(){var e=document.querySelector('[name=\"ln\"]'); e.value='Smith-Jones'; e.removeAttribute('data-ook-user');})()")
        _ = await session.fillLive(plan.values)
        let last = await read("ln")
        XCTAssertEqual(last, "Smith-Jones")
    }

    /// Plain digits go in first; a box that then shows an error gets the other shapes until it accepts one.
    func testAPhoneBoxThatRejectsPlainDigitsIsRetriedInOtherShapes() async throws {
        let html = """
        <html><body><form id="f" onsubmit="event.preventDefault()">
          <label>First name *<input name="fn"></label><label>Email *<input type="email" name="em"></label>
          <input type="tel" name="phone" placeholder="Phone" oninput="this.setAttribute('aria-invalid', /^\\d{3}-\\d{3}-\\d{4}$/.test(this.value) ? 'false' : 'true')">
          <button type="submit">Opt out</button></form></body></html>
        """
        var me = pat; me.phones = ["+1 773 633 1564"]
        let session = WebViewSession.make()
        defer { session.close() }
        try await session.loadHTML(html)
        let forms = await session.discoverForms(waitForFrames: false)
        let form = try XCTUnwrap(forms.first)
        let plan = FormFiller.plan(for: form.asOptOutForm(page: URL(string: "https://local.test/")!), signals: nil, person: me)
        _ = await session.fillLive(plan.values)
        let phone = (await session.evalLive("document.querySelector('[name=\"phone\"]').value") as? String) ?? ""
        let dbg = (await session.evalLive("document.querySelector('[name=\"phone\"]').outerHTML") as? String) ?? ""
        XCTAssertEqual(phone, "773-633-1564", dbg)
    }

    /// A box holding exactly what the app typed earlier is replaced when the plan changes (another person, a corrected email).
    func testAValueTheAppTypedIsReplacedWhenThePlanChanges() async throws {
        let html = "<html><body><form id=\"f\" onsubmit=\"event.preventDefault()\"><label>Email *<input type=\"email\" name=\"em\"></label><button type=\"submit\">Opt out</button></form></body></html>"
        let session = WebViewSession.make()
        defer { session.close() }
        try await session.loadHTML(html)
        let forms = await session.discoverForms(waitForFrames: false)
        let form = try XCTUnwrap(forms.first).asOptOutForm(page: URL(string: "https://local.test/")!)
        var second = pat; second.emails = ["new@example.com"]
        _ = await session.fillLive(FormFiller.plan(for: form, signals: nil, person: pat).values)
        _ = await session.fillLive(FormFiller.plan(for: form, signals: nil, person: second).values)
        let email = (await session.evalLive("document.querySelector('[name=\"em\"]').value") as? String) ?? ""
        XCTAssertEqual(email, "new@example.com")
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

    // MARK: what the person chose is theirs

    private func read(_ session: WebViewSession, _ js: String) async -> String { "\(await session.evalLive(js) ?? "")" }

    /// Tiles that toggle, with a state the page marks in its own way (no aria-pressed, no "selected" class), like the "Select request type(s)" page.
    private let tilePage = """
        <html><body><form id="f" onsubmit="event.preventDefault()">
        <h3>* Select request type(s)</h3>
        <div id="grid">
          <button type="button" class="tile" id="del">Request to delete personal information</button>
          <button type="button" class="tile" id="know">Request to Know - Specific Pieces of Personal Information</button>
          <button type="button" class="tile" id="optout">Request to Opt-Out (Do Not Sell or Share My Personal Information)</button>
          <button type="button" class="tile" id="sale">Request to Opt-Out (Sale of Personal Information)</button>
        </div>
        <input name="em"><button type="submit">Submit</button></form>
        <script>window.clicks=0; document.querySelectorAll('.tile').forEach(function(b){b.addEventListener('click',function(){window.clicks++; b.classList.toggle('on');});});</script>
        </body></html>
        """
    private func tiles(_ session: WebViewSession) async -> String { await read(session, "[].map.call(document.querySelectorAll('.tile'),function(b){return b.classList.contains('on')?b.id:''}).filter(Boolean).join(',')") }
    /// What a real tap does: the page toggles the tile and the app is told it was the person's (the test marks it the way a trusted event does).
    private func personTaps(_ session: WebViewSession, _ id: String) async {
        _ = await session.evalLive("(function(){var b=document.getElementById('\(id)'); b.click(); b.setAttribute('data-ook-user','1');})()")
    }

    func testTilesTheAppChoseOnceAreNotTappedAgainOnARefill() async throws {
        let session = WebViewSession.make(); defer { session.close() }
        try await session.loadHTML(tilePage)
        let first = await session.chooseTileButtons()
        let chosen = await tiles(session)
        XCTAssertEqual(first, 1); XCTAssertEqual(chosen, "del", "the deletion tile is chosen at first")
        for _ in 0..<3 { _ = await session.chooseTileButtons() }
        let after = await tiles(session)
        let clicks = await read(session, "window.clicks")
        XCTAssertEqual(after, "del", "refills leave it on: a tile that toggles would have been switched off")
        XCTAssertEqual(clicks, "1", "tapped once, never again")
    }

    func testAPersonAddingAnotherTileKeepsItAndTheAppDoesNotChooseForThem() async throws {
        let session = WebViewSession.make(); defer { session.close() }
        try await session.loadHTML(tilePage)
        _ = await session.chooseTileButtons()
        await personTaps(session, "optout")                              // multi select: opt-out as well
        for _ in 0..<3 { _ = await session.chooseTileButtons() }
        let kept = await tiles(session)
        XCTAssertEqual(kept, "del,optout", "both stay on")
    }

    func testAPersonUnselectingTheAppsTileAndPickingAnotherIsNotUndone() async throws {
        let session = WebViewSession.make(); defer { session.close() }
        try await session.loadHTML(tilePage)
        _ = await session.chooseTileButtons()
        await personTaps(session, "del")                                  // off again
        await personTaps(session, "sale")
        for _ in 0..<3 { _ = await session.chooseTileButtons() }
        let kept = await tiles(session)
        XCTAssertEqual(kept, "sale", "the app does not wipe their choice or bring its own back")
    }

    func testATileTheAppHasNotYetChosenIsLeftAloneOnceThePersonTappedFirst() async throws {
        let session = WebViewSession.make(); defer { session.close() }
        try await session.loadHTML(tilePage)
        await personTaps(session, "know")                                 // the person got there before the first fill
        let n = await session.chooseTileButtons()
        let kept = await tiles(session)
        XCTAssertEqual(n, 0); XCTAssertEqual(kept, "know")
    }

    private let boxesPage = """
        <html><body><form id="f" onsubmit="event.preventDefault()">
        <h2>Do Not Sell My Personal Information</h2>
        <fieldset><legend>Request</legend>
          <label><input type="radio" name="t" value="optout"> Do not sell or share my information</label>
          <label><input type="radio" name="t" value="remove"> Remove my information</label>
          <label><input type="radio" name="t" value="access"> Access my information</label></fieldset>
        <label><input type="checkbox" name="c" value="optout"> Opt out of targeted advertising</label>
        <label><input type="checkbox" name="c" value="delete"> Request deletion of my information</label>
        <label><input type="checkbox" name="c" value="access"> Request access to my information</label>
        <label>Type<select name="s"><option value="">Select</option><option value="o">Opt-out of sale</option><option value="d">Delete my data</option><option value="k">Know what you hold</option></select></label>
        <input name="em"><button type="submit">Send</button></form></body></html>
        """
    private func state(_ session: WebViewSession) async -> String {
        await read(session, "(function(){var f=document.getElementById('f'); var o=[]; f.querySelectorAll('input[type=radio]:checked,input[type=checkbox]:checked').forEach(function(e){o.push(e.name+'='+e.value);}); o.push('s='+f.s.value); return o.join(',');})()")
    }

    func testBoxesAndMenusTheAppSetAreNotRedoneAfterThePersonChangedThem() async throws {
        let session = WebViewSession.make(); defer { session.close() }
        try await session.loadHTML(boxesPage)
        let forms = await session.discoverForms(waitForFrames: false); let form = try XCTUnwrap(forms.first)
        _ = await session.chooseRequestOptions(form: form.token)
        let first = await state(session)
        XCTAssertTrue(first.contains("t=remove") && first.contains("c=optout") && first.contains("c=delete") && first.contains("s=d"), first)
        // The person: unticks opt-out, ticks access too, picks the other radio and another menu entry.
        _ = await session.evalLive("""
            (function(){var f=document.getElementById('f');
              function mark(e){e.setAttribute('data-ook-user','1');}
              var cs=f.querySelectorAll('input[name=c]'); cs[0].checked=false; mark(cs[0]); cs[2].checked=true; mark(cs[2]);
              var rs=f.querySelectorAll('input[name=t]'); rs[0].checked=true; mark(rs[0]);
              f.s.value='d'; mark(f.s);})()
            """)
        let theirs = await state(session)
        for _ in 0..<3 { _ = await session.chooseRequestOptions(form: form.token) }
        let after = await state(session)
        XCTAssertEqual(after, theirs, "refills change nothing the person set")
    }

    func testABoxTheAppTickedIsNotTickedAgainAfterItWasUntickedEvenWithoutAUserMark() async throws {
        let session = WebViewSession.make(); defer { session.close() }
        try await session.loadHTML(boxesPage)
        let forms = await session.discoverForms(waitForFrames: false); let form = try XCTUnwrap(forms.first)
        _ = await session.chooseRequestOptions(form: form.token)
        _ = await session.evalLive("document.querySelectorAll('input[name=c]')[0].checked=false")
        _ = await session.chooseRequestOptions(form: form.token)
        let optOutBox = await read(session, "document.querySelectorAll('input[name=c]')[0].checked")
        XCTAssertEqual(optOutBox, "0", "the app chose once; it does not choose again")
    }

    // MARK: where only one can be chosen, deletion beats opt-out

    func testASingleChoiceOfTilesTakesDeletionEvenWhenOptOutComesFirst() async throws {
        let session = WebViewSession.make(); defer { session.close() }
        try await session.loadHTML("""
            <html><body><form><h3>Select request type</h3><div>
              <button type="button" class="tile" id="optout">Request to Opt-Out (Do Not Sell or Share My Personal Information)</button>
              <button type="button" class="tile" id="sale">Request to Opt-Out (Sale of Personal Information)</button>
              <button type="button" class="tile" id="del">Request to delete personal information</button>
            </div><input name="em"></form>
            <script>document.querySelectorAll('.tile').forEach(function(b){b.addEventListener('click',function(){b.classList.toggle('on');});});</script></body></html>
            """)
        _ = await session.chooseTileButtons()
        let chosen = await tiles(session)
        XCTAssertEqual(chosen, "del")
    }

    func testASingleChoiceOfRadiosAndAMenuTakeDeletionEvenWhenOptOutComesFirst() async throws {
        let html = """
            <html><body><form id="f" onsubmit="event.preventDefault()">
            <fieldset><legend>Request</legend>
              <label><input type="radio" name="t" value="optout"> Do not sell or share my information</label>
              <label><input type="radio" name="t" value="delete"> Delete my personal information</label>
              <label><input type="radio" name="t" value="access"> Access my information</label></fieldset>
            <label>Type<select name="s"><option value="">Select</option><option value="o">Opt-out of sale</option><option value="d">Delete my data</option></select></label>
            <input name="em"><button type="submit">Send</button></form></body></html>
            """
        let session = WebViewSession.make(); defer { session.close() }
        try await session.loadHTML(html)
        let forms = await session.discoverForms(waitForFrames: false); let form = try XCTUnwrap(forms.first)
        _ = await session.chooseRequestOptions(form: form.token)
        let got = await read(session, "(function(){var f=document.getElementById('f'); return f.querySelector('input[name=t]:checked').value+','+f.s.value;})()")
        XCTAssertEqual(got, "delete,d")
    }

    func testAPageThatStartsOnOptOutIsMovedToDeletionUnlessThePersonChose() async throws {
        let html = """
            <html><body><form id="f" onsubmit="event.preventDefault()">
            <label><input type="radio" name="t" value="optout" checked> Do not sell my information</label>
            <label><input type="radio" name="t" value="delete"> Delete my personal information</label>
            <input name="em"><button type="submit">Send</button></form></body></html>
            """
        let session = WebViewSession.make(); defer { session.close() }
        try await session.loadHTML(html)
        let forms = await session.discoverForms(waitForFrames: false); let form = try XCTUnwrap(forms.first)
        _ = await session.chooseRequestOptions(form: form.token)
        let first = await read(session, "document.querySelector('input[name=t]:checked').value")
        XCTAssertEqual(first, "delete")
        _ = await session.evalLive("(function(){var r=document.querySelector('input[name=t][value=optout]'); r.checked=true; r.setAttribute('data-ook-user','1');})()")
        _ = await session.chooseRequestOptions(form: form.token)
        let kept = await read(session, "document.querySelector('input[name=t]:checked').value")
        XCTAssertEqual(kept, "optout", "the person's own choice of opt-out stays")
    }

    func testALandingPageWithBothLinksGoesToDeletion() async throws {
        let html = """
            <html><body>
            <button id="o" onclick="document.title='optout'">Opt out of the sale of my personal information</button>
            <button id="d" onclick="document.title='delete'">Delete my personal information</button>
            </body></html>
            """
        let session = WebViewSession.make(); defer { session.close() }
        try await session.loadHTML(html)
        let clicked = await session.advanceToRequestForm()
        let title = await read(session, "document.title")
        XCTAssertEqual(title, "delete", "clicked: \(clicked ?? "nothing")")
    }

    func testOnlyFormsThatAreSpecificallyOptOutsAreSentAfterTheFirst() async throws {
        let html = """
            <html><body>
            <h3>Opt out by email</h3><form id="a" onsubmit="event.preventDefault()"><input type="email" placeholder="E-mail"><button type="submit">Opt me out</button></form>
            <h3>Stay in touch</h3><form id="b" onsubmit="event.preventDefault()"><input type="email" placeholder="Your email"><button type="submit">Subscribe to our newsletter</button></form>
            <h3>Questions?</h3><form id="c" onsubmit="event.preventDefault()"><input name="n" placeholder="Name"><input type="email" placeholder="Email"><textarea placeholder="How can we help?"></textarea><button type="submit">Send message</button></form>
            <h3>Opt out of Mobile ID</h3><form id="d" onsubmit="event.preventDefault()"><input placeholder="Device ID"><button type="submit">Opt me out</button></form>
            </body></html>
            """
        let session = WebViewSession.make(); defer { session.close() }
        try await session.loadHTML(html)
        let forms = await session.discoverForms(waitForFrames: false)
        let context = await session.pageContext()
        let optOuts = forms.filter { LiveFormPicker.isDedicatedOptOut($0, pageContext: context) }
        XCTAssertEqual(optOuts.count, 2, "the email opt-out and the device-ID opt-out; not the newsletter or the contact form: \(forms.map { $0.buttons })")
        XCTAssertTrue(optOuts.allSatisfy { $0.buttons.joined().lowercased().contains("opt me out") })
    }

    /// realsourcedata.com is a Tally form: the question is a heading and each box points at it with aria-labelledby, with no placeholder, name or label tag.
    func testBoxesLabelledByAHeadingThroughAriaLabelledbyAreFilled() async throws {
        func field(_ id: String, _ question: String, type: String = "text") -> String {
            "<div><h3 id=\"label_\(id)\">\(question)</h3><div><input id=\"\(id)\" type=\"\(type)\" placeholder=\"\" required aria-labelledby=\"label_\(id)\"></div></div>"
        }
        let html = """
            <html><body><h1>Do Not Sell My Personal Information</h1><form id="t" onsubmit="event.preventDefault()">
            \(field("a1", "First Name"))\(field("a2", "Last Name"))\(field("a3", "Street Address"))\(field("a4", "City"))\(field("a5", "State"))
            \(field("a6", "Zip Code"))\(field("a7", "Phone Number", type: "tel"))\(field("a8", "Email", type: "email"))
            <button type="submit">Send</button></form></body></html>
            """
        var me = pat; me.phones = ["773 633 1564"]
        let session = WebViewSession.make(); defer { session.close() }
        try await session.loadHTML(html)
        let forms = await session.discoverForms(waitForFrames: false)
        let form = try XCTUnwrap(forms.first)
        XCTAssertEqual(form.fields.map(\.label), ["First Name", "Last Name", "Street Address", "City", "State", "Zip Code", "Phone Number", "Email"], "the heading is the box's label")
        let plan = FormFiller.plan(for: form.asOptOutForm(page: URL(string: "https://local.test/")!), signals: nil, person: me)
        _ = await session.fillLive(plan.values)
        func value(_ id: String) async -> String { "\(await session.evalLive("document.getElementById('\(id)').value") ?? "")" }
        let got = [await value("a1"), await value("a2"), await value("a3"), await value("a4"), await value("a5"), await value("a6"), await value("a8")]
        XCTAssertEqual(got, ["Pat", "Example", "1 Main St", "Springfield", "IL", "62701", "pat@example.com"])
        let phone = await value("a7"); XCTAssertEqual(phone, "7736331564")
    }
}
