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

    /// A site whose page keeps working after its send button was pressed: the background run's watchdog learns from the page code itself that the form was
    /// sent (`SiteRun.markSent`, through `pressLiveSubmit`), and the wait after sending ends in time (`SiteRun.deadline`) to read what the page said, so the
    /// site has a real result and the page's message, not "sent, not confirmed" with nothing to show (build 49). A page given up before its send button was
    /// pressed is not marked sent.
    func testAfterSendingTheRunReadsWhatThePageSaidBeforeItsTimeIsUp() async {
        let pat = self.pat
        let busy = """
        <html><body><form id="opt" onsubmit="event.preventDefault(); document.getElementById('m').textContent='We could not process your request. Please try again later.'; setInterval(function(){ document.getElementById('s').textContent+='.'; }, 100);">
          <h2>Do Not Sell My Personal Information</h2>
          <label>First name *<input name="fn"></label><label>Last name *<input name="ln"></label><label>Email *<input type="email" name="em"></label>
          <button type="submit">Submit request</button></form><p id="m"></p><p id="s"></p></body></html>
        """
        // The fill takes a few seconds; after the press the page never settles, and the run still reads it before the cap.
        // The cap is generous (a slow CI machine took over 14 s just to fill the form), and the wait after sending is 60 s if nothing limits it: the cap is only
        // met in time when the wait stops early, 5 s before it (`SiteRun.deadline`), which is what this checks.
        let sent = await AutoOptOut.watched(idle: nil, cap: 24) { _ in
            await FormRun.runLive(url: nil, html: busy, person: pat, dryRun: false, maxWait: 60, capture: false)
        }
        XCTAssertTrue(sent.sent, "the send button had been pressed")
        XCTAssertNotNil(sent.value, "read in time, not given up")
        XCTAssertNotEqual(sent.value?.outcome, .submitted(awaitingEmail: false), "an error is not a confirmation")
        XCTAssertTrue(sent.value?.pageText?.contains("could not process your request") == true, "what the page said is kept: \(sent.value?.pageText ?? "nil")")

        // The same kind of page busy from the start, so the run gives up while it is still waiting for the page, before any send.
        let neverReady = "<html><body><p id=s></p><script>var n=0; setInterval(function(){ document.getElementById('s').textContent+='.'; }, 100);</script><form><input name=em type=email></form></body></html>"
        let unsent = await AutoOptOut.watched(idle: nil, cap: 2) { _ in
            await FormRun.runLive(url: nil, html: neverReady, person: pat, dryRun: false, maxWait: 20, capture: false)
        }
        XCTAssertNil(unsent.value)
        XCTAssertFalse(unsent.sent, "nothing was pressed")

        // A page stopped before sending (no opt-out form on it) keeps no page text: only a form that was sent does.
        let noForm = await FormRun.runLive(url: nil, html: "<html><body><h1>Privacy</h1><p>We respect your privacy.</p></body></html>", person: pat, dryRun: false, maxWait: 6, capture: false)
        XCTAssertNotEqual(noForm.outcome, .submitted(awaitingEmail: false))
        XCTAssertNil(noForm.pageText, "nothing was sent, so no page text is kept")
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

    /// forewarn.com: the "which law gives you this right" box is hidden until the person ticks a basis for the request. The app never ticks it (that is their claim to
    /// make), types the plain statement of the privacy laws into the law box once it shows, and never touches the box about a threat of harm.
    func testForewarnsLawBoxGetsTheApplicableLawOnceThePersonRevealsItAndTheThreatBoxStaysEmpty() async throws {
        let html = """
        <html><body><form id="f" onsubmit="event.preventDefault()">
          <label for="FirstName">Name*</label><input id="FirstName" name="First Name">
          <input id="LastName" name="Last Name">
          <label for="Email">Email Address*</label><input id="Email" type="email" name="Email">
          <label class="d-flex"><input id="legalRight" name="legalRight" type="checkbox" required
            onchange="document.getElementById('legal-right-wrapper').style.display=this.checked?'block':'none'">
            <span>I am an individual afforded a legal right to non-disclosure/opt-out due to a risk of harm or similar threat.</span></label>
          <div id="legal-right-wrapper" style="display: none;">
            <label class="my-3"><strong>Please specify the particular law that affords you protection and provide sufficient support for FOREWARN to determine whether you fall within the categories of persons protected by the law.</strong></label>
            <textarea id="legalInfo" name="legalInfo" placeholder="Please cite the particular, applicable law that affords you protection"></textarea></div>
          <label class="d-flex"><input id="personlRisk" name="personlRisk" type="checkbox"><span>I am an individual otherwise subject to a serious risk of physical harm.</span></label>
          <div id="threat-wrapper" style="display: none;">
            <label>Please describe the threat against you, and any supporting documentation you possess substantiating the threat</label>
            <textarea id="threatInfo" name="threatInfo"></textarea></div>
          <button type="submit">Submit</button></form></body></html>
        """
        let session = WebViewSession.make()
        defer { session.close() }
        try await session.loadHTML(html)
        func plan() async throws -> FillPlan {
            let forms = await session.discoverForms(waitForFrames: false)
            let form = try XCTUnwrap(forms.first)
            return FormFiller.plan(for: form.asOptOutForm(page: URL(string: "https://local.test/")!), signals: nil, person: pat)
        }
        func read(_ n: String) async -> String { (await session.evalLive("document.querySelector('[name=\"\(n)\"]').value") as? String) ?? "" }
        _ = await session.fillLive(try await plan().values)
        let ticked = (await session.evalLive("document.querySelector('[name=legalRight]').checked") as? Bool) ?? true
        XCTAssertFalse(ticked, "the basis for the request is the person's claim: never ticked for them")
        // The person ticks the basis; the law box shows; the next fill puts the applicable law in it.
        _ = await session.evalLive("(function(){var c=document.querySelector('[name=legalRight]'); c.checked=true; c.dispatchEvent(new Event('change',{bubbles:true})); return 1;})()")
        _ = await session.fillLive(try await plan().values, keepExisting: true)
        let law = await read("legalInfo")
        XCTAssertEqual(law, FormFiller.legalBasis(for: pat), "the applicable law is typed into the law box")
        XCTAssertGreaterThan(law.count, 50)
        // The threat box is never filled, even when the person reveals it.
        _ = await session.evalLive("(function(){var c=document.querySelector('[name=personlRisk]'); c.checked=true; document.getElementById('threat-wrapper').style.display='block'; return 1;})()")
        _ = await session.fillLive(try await plan().values, keepExisting: true)
        let threat = await read("threatInfo")
        XCTAssertEqual(threat, "", "the box about a threat of harm is never filled")
    }

    /// theorg.com: the opt-out page is a sentence and one "Continue" button; the form comes after it. The button is pressed on an opt-out page only when nothing else is
    /// on screen and it is the only one; the same word in a cookie prompt, or on a page that is not an opt-out, is never pressed.
    func testABareContinueOnAnOptOutPageIsPressedAndOneInACookiePromptOrOnAnotherPageIsNot() async throws {
        func html(title: String, cookie: Bool) -> String {
            """
            <html><head><title>\(title)</title></head><body>
            \(cookie ? "<div id=\"cookie-banner\"><button id=\"cb\">Continue</button></div>" : "<p>Your privacy matters to us.</p><button id=\"go\" onclick=\"document.getElementById('f').style.display='block'; this.remove()\">Continue</button>")
            <form id="f" style="display:none" onsubmit="event.preventDefault()"><label>First name *<input name="fn"></label><label>Email *<input type="email" name="em"></label><button type="submit">Submit request</button></form>
            </body></html>
            """
        }
        let session = WebViewSession.make(); defer { session.close() }
        try await session.loadHTML(html(title: "Opt-out | Example", cookie: false))
        let clicked = await session.advanceToRequestForm()
        XCTAssertEqual(clicked, "Continue")
        let shown = (await session.evalLive("getComputedStyle(document.getElementById('f')).display") as? String) ?? ""
        XCTAssertEqual(shown, "block", "the form is there after the button")

        try await session.loadHTML(html(title: "Welcome | Example", cookie: false))
        let other = await session.advanceToRequestForm()
        XCTAssertTrue(other == nil || other == "", "a Continue on a page that is not an opt-out is left alone")

        try await session.loadHTML(html(title: "Opt-out | Example", cookie: true))
        let banner = await session.advanceToRequestForm()
        XCTAssertTrue(banner == nil || banner == "", "a Continue in a cookie prompt is never pressed")
    }

    /// roundsky.com: one phone number over three boxes (limits 3, 3 and 4). Each takes its part; the whole number never goes in every box.
    func testAPhoneSplitOverThreeBoxesGetsOnePartInEach() async throws {
        let html = """
        <html><body><form id="f" onsubmit="event.preventDefault()">
          <label for="Name">FIRST NAME *</label><input id="Name" name="Name" placeholder="Ex : John" required>
          <label for="LName">LAST NAME *</label><input id="LName" name="LName" placeholder="Ex : Smith" required>
          <label for="Email">EMAIL *</label><input id="Email" type="email" name="Email" required>
          <label for="Phone">PHONE</label>
          <div><input id="Phone" type="tel" name="Phone" maxlength="3" placeholder="Ex : 855">
          <input id="Phone2" type="tel" name="Phone2" maxlength="3" placeholder="Ex : 826">
          <input id="Phone3" type="tel" name="Phone3" maxlength="4" placeholder="Ex : 6284"></div>
          <button type="submit">Submit</button></form></body></html>
        """
        var me = pat; me.phones = ["+1 773 633 1564"]
        let session = WebViewSession.make()
        defer { session.close() }
        try await session.loadHTML(html)
        let forms = await session.discoverForms(waitForFrames: false)
        let form = try XCTUnwrap(forms.first)
        let plan = FormFiller.plan(for: form.asOptOutForm(page: URL(string: "https://local.test/")!), signals: nil, person: me)
        _ = await session.fillLive(plan.values)
        _ = await session.fillLive(plan.values, keepExisting: true)
        func read(_ n: String) async -> String { (await session.evalLive("document.querySelector('[name=\"\(n)\"]').value") as? String) ?? "" }
        let parts = [await read("Phone"), await read("Phone2"), await read("Phone3")]
        XCTAssertEqual(parts, ["773", "633", "1564"])
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

    /// The kinds of box that used to be skipped, cut or mistyped: a message box with a small limit, a month picker, a date-and-time picker, an age-bracket menu,
    /// a rich-text (contenteditable) message box, a split street, a cell number, and an SSN box that must stay empty.
    func testEveryKindOfBoxIsFilledInItsOwnShapeAndTheOnesThatAreNotTheirsStayEmpty() async throws {
        let html = """
        <html><body><form id="f" onsubmit="event.preventDefault()">
          <label>First name *<input name="fn"></label><label>Email *<input type="email" name="em"></label>
          <label>Last 4 digits of SSN<input name="ssn"></label>
          <label>Cell number<input name="cell"></label>
          <label>House number<input name="hn"></label><label>Street name<input name="sn"></label>
          <label>Birth month<input type="month" name="bm"></label>
          <label>Date and time of request<input type="datetime-local" name="dt"></label>
          <label>Age range<select name="ar"><option value="">Select</option><option value="u18">Under 18</option><option value="a">18-34</option><option value="b">35 - 49</option><option value="c">50+</option></select></label>
          <label>Message<textarea name="msg" maxlength="90"></textarea></label>
          <label id="rtl">Details *</label><div id="rte" contenteditable="true" aria-labelledby="rtl" style="border:1px solid #000;min-height:40px"></div>
          <button type="submit">Opt out</button></form></body></html>
        """
        var me = pat; me.birthdate = "1980-01-31"; me.phones = ["312-555-0142"]; me.addresses = [Address(street: "12 Main St", city: "Springfield", state: "IL", zip: "62701")]
        let session = WebViewSession.make()
        defer { session.close() }
        try await session.loadHTML(html)
        let forms = await session.discoverForms(waitForFrames: false)
        let form = try XCTUnwrap(forms.first)
        XCTAssertTrue(form.fields.contains { $0.label.contains("Details") && $0.type == "textarea" }, "the rich-text box is found: \(form.fields.map(\.label))")
        let plan = FormFiller.plan(for: form.asOptOutForm(page: URL(string: "https://local.test/")!), signals: nil, person: me)
        _ = await session.fillLive(plan.values)
        func read(_ n: String) async -> String { (await session.evalLive("(function(){var e=document.querySelector('[name=\"\(n)\"]'); return e.value;})()") as? String) ?? "" }
        let ssn = await read("ssn"); XCTAssertEqual(ssn, "", "an SSN box is never filled")
        let cell = await read("cell"); XCTAssertEqual(cell, "3125550142")
        let hn = await read("hn"); XCTAssertEqual(hn, "12")
        let sn = await read("sn"); XCTAssertEqual(sn, "Main St")
        let bm = await read("bm"); XCTAssertEqual(bm, "1980-01")
        let dt = await read("dt"); XCTAssertTrue(dt.range(of: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}$", options: .regularExpression) != nil, dt)
        let ar = await read("ar"); XCTAssertEqual(ar, "b", "46 or so falls in a bracket: \(ar)")
        let msg = await read("msg"); XCTAssertTrue(!msg.isEmpty && msg.count <= 90, "fits the limit: \(msg.count)")
        let rte = (await session.evalLive("document.getElementById('rte').innerText") as? String) ?? ""
        XCTAssertTrue(rte.contains("personal information"), "the rich-text box holds the request: \(rte)")
    }

    /// nyne.ai: "Are you submitting this request for yourself?" is answered Yes (not "No, I am an authorized agent"); a box for a list of phone numbers keeps both.
    func testForYourselfIsAnsweredYesAndAPhoneListIsNotSquashedIntoOneNumber() async throws {
        let html = """
        <html><body><form id="f" onsubmit="event.preventDefault()">
          <label>First name *<input name="fn"></label><label>Email *<input type="email" name="em"></label>
          <label>Phone Numbers *<input name="pl"></label>
          <label>Are you submitting this request for yourself? *<select name="me"><option value="">Select</option><option value="n">No, I am an authorized agent</option><option value="y">Yes, for myself</option></select></label>
          <fieldset><legend>Are you submitting this request for yourself?</legend><label><input type="radio" name="r" value="n">No, I am an authorized agent</label><label><input type="radio" name="r" value="y">Yes</label></fieldset>
          <button type="submit">Opt out</button></form></body></html>
        """
        var me = pat; me.phones = ["312-555-0142", "773-555-0199"]
        let session = WebViewSession.make()
        defer { session.close() }
        try await session.loadHTML(html)
        let forms = await session.discoverForms(waitForFrames: false)
        let form = try XCTUnwrap(forms.first)
        let plan = FormFiller.plan(for: form.asOptOutForm(page: URL(string: "https://local.test/")!), signals: nil, person: me)
        _ = await session.fillLive(plan.values)
        _ = await session.chooseRequestOptions(form: form.token)
        let pl = (await session.evalLive("document.querySelector('[name=\"pl\"]').value") as? String) ?? ""
        XCTAssertEqual(pl, "312-555-0142, 773-555-0199", pl)
        let sel = (await session.evalLive("document.querySelector('[name=\"me\"]').value") as? String) ?? ""
        XCTAssertEqual(sel, "y", "the menu is answered Yes")
        let radio = (await session.evalLive("(document.querySelector('[name=\"r\"]:checked')||{}).value") as? String) ?? ""
        XCTAssertEqual(radio, "y", "the radio is answered Yes")
    }

    /// A State or Country the page ships with (a default such as "CA") gives way to the person's own; any other pre-filled box, and a State the person typed, stay.
    func testAStateOrCountryThePageShipsWithGivesWayToThePersonsOwnButOtherPrefilledBoxesStay() async throws {
        let html = """
        <html><body><form id="f" onsubmit="event.preventDefault()">
          <label>First name *<input name="fn" value="Link Name"></label><label>Email *<input type="email" name="em"></label>
          <label>State *<input name="st" value="CA"></label>
          <label>Country *<select name="co"><option value="">Select</option><option value="CA">Canada</option><option value="US" selected>United States</option></select></label>
          <label>Province *<select name="pr"><option value="">Select</option><option value="CA">California</option><option value="IL">Illinois</option></select></label>
          <button type="submit">Opt out</button></form></body></html>
        """
        let session = WebViewSession.make()
        defer { session.close() }
        try await session.loadHTML(html)
        let forms = await session.discoverForms(waitForFrames: false)
        let form = try XCTUnwrap(forms.first).asOptOutForm(page: URL(string: "https://local.test/")!)
        _ = await session.fillLive(FormFiller.plan(for: form, signals: nil, person: pat).values, keepExisting: true)
        func val(_ n: String) async -> String { (await session.evalLive("document.querySelector('[name=\"\(n)\"]').value") as? String) ?? "" }
        let st = await val("st"), fn = await val("fn"), co = await val("co")
        XCTAssertEqual(st, pat.addresses.first?.state, "the page's CA is replaced by the person's state")
        XCTAssertEqual(fn, "Link Name", "a pre-filled name stays")
        XCTAssertEqual(co, "US", "a country that already matches stays")
        // A State the person typed over the page's default is theirs and survives a refill.
        _ = await session.evalLive("(function(){var e=document.querySelector('[name=\"st\"]'); e.value='TX'; e.setAttribute('data-ook-user','1');})()")
        _ = await session.fillLive(FormFiller.plan(for: form, signals: nil, person: pat).values, keepExisting: true)
        let after = await val("st")
        XCTAssertEqual(after, "TX")
    }

    /// businessregistry.com caps its extra email boxes while the "Add email" button stays: pressing stops once a press adds no box, and the boxes named `emails` take the next emails.
    func testAPageThatCapsItsExtraBoxesIsNotPressedForeverAndNamedEmailBoxesTakeTheNextValues() async throws {
        let html = """
        <html><body><h1>Opt out of the sale of my personal information</h1>
        <form id="f" onsubmit="event.preventDefault()">
          <label>Full name *<input name="full_name"></label>
          <label>Email address *<input type="email" name="email"></label>
          <div id="more"><input type="email" name="emails" placeholder="another@example.com"></div>
          <div class="add-wrap"><button type="button" onclick="window.presses=(window.presses||0)+1; var m=document.getElementById('more'); if(m.children.length<2){var i=document.createElement('input'); i.type='email'; i.name='emails'; i.placeholder='another@example.com'; m.appendChild(i);}">+ Add email</button></div>
          <button type="submit">Opt out</button></form></body></html>
        """
        var me = pat; me.emails = ["pat@example.com", "pat.b@example.org", "pat.c@example.org", "pat.d@example.org", "pat.e@example.org"]
        let session = WebViewSession.make()
        defer { session.close() }
        try await session.loadHTML(html)
        let filled = await session.scanAndFill(person: me)
        XCTAssertGreaterThan(filled, 0)
        let presses = (await session.evalLive("window.presses||0") as? Int) ?? -1
        XCTAssertLessThanOrEqual(presses, 3, "pressing stops once the page adds no more boxes (pressed \(presses) times)")
        let vals = (await session.evalLive("JSON.stringify([].slice.call(document.querySelectorAll('[name=emails]')).map(function(e){return e.value;}))") as? String) ?? ""
        XCTAssertEqual(vals, "[\"pat.b@example.org\",\"pat.c@example.org\"]")
    }

    /// A button with no type inside a form submits it, so even one named "Add another email" is left alone; the form is never sent by the add step.
    func testAnAddButtonThatWouldSubmitTheFormIsNotPressed() async throws {
        let html = """
        <html><body><h1>Opt out of the sale of my personal information</h1>
        <form id="f" onsubmit="event.preventDefault(); window.sent=true;">
          <label>First name *<input name="fn"></label><label>Email *<input type="email" name="em"></label>
          <button onclick="window.clicked=true">Add another email</button>
          <button type="submit">Opt out</button></form></body></html>
        """
        var me = pat; me.emails = ["pat@example.com", "pat.old@example.org"]
        let session = WebViewSession.make()
        defer { session.close() }
        try await session.loadHTML(html)
        let forms = await session.discoverForms(waitForFrames: false)
        let form = try XCTUnwrap(forms.first)
        let n = await session.addAnotherBoxes(form: form.token, emails: 2, phones: 0)
        XCTAssertEqual(n, 0)
        let state = (await session.evalLive("String(window.clicked===true)+String(window.sent===true)") as? String) ?? ""
        XCTAssertEqual(state, "falsefalse")
    }

    /// Babelstreet: the birthdate rejects month-first, so it is retried day-first; today's date (valid either way) then follows the same shape.
    func testAnotherDateBoxFollowsTheShapeARetriedDateBoxSettledOn() async throws {
        let html = """
        <html><body><form id="f" onsubmit="event.preventDefault()">
          <label>First name *<input name="fn"></label><label>Email *<input type="email" name="em"></label>
          <label>Date of Birth<input name="dob" oninput="this.setAttribute('aria-invalid', /^(0[1-9]|[12]\\d|3[01])\\/(0[1-9]|1[0-2])\\/\\d{4}$/.test(this.value) ? 'false' : 'true')"></label>
          <label>Today's Date *<input name="today"></label>
          <button type="submit">Opt out</button></form></body></html>
        """
        var me = pat; me.birthdate = "1992-04-19"
        let session = WebViewSession.make()
        defer { session.close() }
        try await session.loadHTML(html)
        let forms = await session.discoverForms(waitForFrames: false)
        let form = try XCTUnwrap(forms.first)
        let plan = FormFiller.plan(for: form.asOptOutForm(page: URL(string: "https://local.test/")!), signals: nil, person: me)
        _ = await session.fillLive(plan.values)
        func read(_ n: String) async -> String { (await session.evalLive("document.querySelector('[name=\"\(n)\"]').value") as? String) ?? "" }
        let dob = await read("dob")
        XCTAssertEqual(dob, "19/04/1992", dob)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "dd/MM/yyyy"
        let today = await read("today")
        XCTAssertEqual(today, f.string(from: Date()), "today's date follows the day-first shape")
    }

    /// monitorbase.com: the page was sent on the first letter typed into the check. While the person has the cursor in it, or typed within 3 seconds, it is theirs.
    func testABotCheckBoxTheyAreTypingInHoldsTheSendUntilTheyStop() async throws {
        let html = "<html><body><form id=\"f\" onsubmit=\"event.preventDefault()\"><label>Email *<input type=\"email\" name=\"em\"></label><label for=\"cap\">Captcha</label><input id=\"cap\" name=\"cap\"><button type=\"submit\">Submit</button></form></body></html>"
        let session = WebViewSession.make()
        defer { session.close() }
        try await session.loadHTML(html)
        _ = await session.discoverForms(waitForFrames: false)
        let empty = await session.codeBoxInUse()
        XCTAssertFalse(empty, "an empty box is not in use (it is the empty-box check's)")
        // The person types "zej" (marked as theirs, like a real keystroke) and still has the cursor in the box.
        _ = await session.evalLive("(function(){var e=document.getElementById('cap'); e.focus(); e.value='zej'; e.setAttribute('data-ook-user','1'); window.__ookUserAt=Date.now();})()")
        let typing = await session.codeBoxInUse()
        XCTAssertTrue(typing, "the first letters are not a finished check")
        // They stop for a while and leave the box: the send may go.
        _ = await session.evalLive("(function(){document.getElementById('cap').blur(); window.__ookUserAt=Date.now()-60000;})()")
        let done = await session.codeBoxInUse()
        XCTAssertFalse(done)
        // A box we filled ourselves (no user mark) is never waited on.
        _ = await session.evalLive("(function(){var e=document.getElementById('cap'); e.removeAttribute('data-ook-user'); e.focus(); window.__ookUserAt=Date.now();})()")
        let ours = await session.codeBoxInUse()
        XCTAssertFalse(ours)
    }

    /// R+D and Definitive Healthcare: a person taps into the first box and the keyboard is up. A fill must still find what appeared after the first look (a box the
    /// page's script added) and fill it, while the box they are in and anything they typed stay theirs.
    func testFillAgainRescansThePageAndFillsNewBoxesEvenWhileThePersonIsInABox() async throws {
        let html = "<html><body><form id=\"f\" onsubmit=\"event.preventDefault()\"><h2>Do Not Sell My Personal Information</h2><label>First name *<input name=\"fn\" id=\"fn\"></label><label>Email *<input type=\"email\" name=\"em\" id=\"em\"></label><div id=\"slot\"></div><button type=\"submit\">Submit</button></form></body></html>"
        let session = WebViewSession.make(); defer { session.close() }
        try await session.loadHTML(html)
        let pageURL = URL(string: "https://example.com/opt-out")!
        let found = await session.discoverForms(waitForFrames: false)
        let context = await session.pageContext()
        let live = try XCTUnwrap(LiveFormPicker.pick(found, pageContext: context))
        let plan = FormFiller.plan(for: live.asOptOutForm(page: pageURL), signals: nil, person: pat)
        let page = WebAssistedPage(session: session, plan: plan)
        page.useLive(form: live.token, plan: plan, ownerMayConfirm: true)
        page.remember(person: pat, advertisingID: nil, page: pageURL, signature: WebAssistedDriver.signature(live))
        await page.refill()
        // The page's script adds a last-name box later; the person taps into the first box (focus and a touch just now).
        _ = await session.evalLive("(function(){var l=document.createElement('label'); l.innerHTML='Last name *<input name=\"ln\" id=\"ln\">'; document.getElementById('slot').appendChild(l); document.getElementById('fn').value=''; document.getElementById('fn').focus(); window.__ookUserAt=Date.now();})()")
        let typing = await session.userIsTyping()
        XCTAssertTrue(typing, "the setup has the person in a box")
        await page.refill()
        let ln = await read(session, "document.getElementById('ln').value")
        let fn = await read(session, "document.getElementById('fn').value")
        XCTAssertEqual(ln, "Example", "the box that appeared after the first look is filled")
        XCTAssertEqual(fn, "Pat", "an empty box the person is in is filled when they ask for a fill")
        // What they typed stays.
        _ = await session.evalLive("(function(){var e=document.getElementById('ln'); e.value='Typed'; e.setAttribute('data-ook-user','1');})()")
        await page.refill()
        let kept = await read(session, "document.getElementById('ln').value")
        XCTAssertEqual(kept, "Typed")
    }

    func testAPreviewFillsAndChoosesButSendsNothing() async {
        let report = await FormRun.runLive(url: nil, html: page(), person: pat, dryRun: true, maxWait: 6, capture: false)
        XCTAssertEqual(report.outcome, .filledNotSubmitted)
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

    // MARK: what counts as a check that stops the run

    private func challenge(_ html: String) async throws -> String? {
        let session = WebViewSession.make(); defer { session.close() }
        try await session.loadHTML(html)
        return await session.visibleChallenge()
    }

    func testTheLeftOverAntiSpamLineOfASolvedCheckIsNotACheck() async throws {
        let solved = "<html><body><form><input name='email'><input type='hidden' name='cf-turnstile-response' value='TOKEN'><p>Please wait for the anti-spam check above the button to finish, then try again.</p></form></body></html>"
        let none = try await challenge(solved)
        XCTAssertNil(none, "the check already passed: its token is there")
        let unsolved = try await challenge(solved.replacingOccurrences(of: "value='TOKEN'", with: "value=''"))
        XCTAssertEqual(unsolved, "a human check", "without a token the same line is a real check")
    }

    func testAPlainPageIsNotACheck() async throws {
        let none = try await challenge("<html><body><form><input name='email'><button>Opt me out</button></form></body></html>")
        XCTAssertNil(none)
    }

    /// OneTrust's privacy portal: the first question is a type-ahead "State of Residence" (only a picked option counts) and the person's own questions appear after it.
    func testTheEmailLinksFillAnswersAStateTypeAheadAndThenFillsWhatItRevealed() async throws {
        let html = """
            <html><body><p>You may have rights with respect to your personal information. Complete this form to exercise these rights.</p>
            <form id="f" onsubmit="event.preventDefault()">
              <label for="stateDSARElement">State of Residence</label>
              <input id="stateDSARElement" role="combobox" aria-autocomplete="list" aria-expanded="false" aria-label="State of Residence" autocomplete="off" required>
              <ul id="list" role="listbox" style="display:none"></ul>
              <div id="more" style="display:none">
                <label for="fn">First Name</label><input id="fn" required><label for="ln">Last Name</label><input id="ln" required><label for="em">Email</label><input id="em" type="email" required>
              </div>
              <label for="captchaCode">Captcha</label><input id="captchaCode" name="captchaCode" aria-label="Captcha">
              <button type="submit">Submit</button>
            </form>
            <script>
              var states=['Alabama','Illinois','Indiana','Texas'], inp=document.getElementById('stateDSARElement'), list=document.getElementById('list');
              function show(){var v=inp.value.toLowerCase(); list.innerHTML=''; states.filter(function(s){return s.toLowerCase().indexOf(v)===0;}).forEach(function(s){
                var li=document.createElement('li'); li.setAttribute('role','option'); li.textContent=s; li.style.padding='6px';
                li.addEventListener('click',function(){inp.value=s; list.style.display='none'; document.getElementById('more').style.display='block';}); list.appendChild(li);}); list.style.display='block';}
              inp.addEventListener('input',show); inp.addEventListener('focus',show);
            </script></body></html>
            """
        let session = WebViewSession.make(); defer { session.close() }
        try await session.loadHTML(html)
        let filler = LinkFiller(); filler.attach(session)
        var me = pat; me.phones = ["773 633 1564"]
        let ok = await filler.fill(person: me)
        func value(_ id: String) async -> String { "\(await session.evalLive("document.getElementById('\(id)').value") ?? "")" }
        let state = await value("stateDSARElement"), first = await value("fn"), last = await value("ln"), email = await value("em"), captcha = await value("captchaCode")
        XCTAssertEqual(state, "Illinois", "the state was picked from the list, not just typed")
        XCTAssertEqual([first, last, email], ["Pat", "Example", "pat@example.com"], "and the questions it revealed were filled in")
        XCTAssertEqual(captcha, "", "a typed captcha is left for the person")
        XCTAssertTrue(ok, filler.status)
    }
}
