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

    /// A birthdate or today's date goes in the shape the box shows; a box that rejects it gets the other shapes until it accepts one (day first, like babelstreet).
    func testADateBoxThatRejectsTheFirstShapeIsRetriedInOtherShapes() async throws {
        let html = """
        <html><body><form id="f" onsubmit="event.preventDefault()">
          <label>First name *<input name="fn"></label><label>Email *<input type="email" name="em"></label>
          <label>Date of Birth<input name="dob" oninput="this.setAttribute('aria-invalid', /^(0[1-9]|[12]\\d|3[01])\\/(0[1-9]|1[0-2])\\/\\d{4}$/.test(this.value) && +this.value.slice(0,2)>12 ? 'false' : 'true')"></label>
          <label>Date<input name="today" placeholder="yyyy-mm-dd"></label>
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
        let today = await read("today")
        XCTAssertTrue(today.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil, "placeholder shape: \(today)")
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

    /// A form with one email box and one phone box and an "Add another" button for each: the buttons are pressed, and every email and phone has a box.
    func testAddAnotherEmailAndPhoneButtonsArePressedAndTheNewBoxesFilled() async throws {
        let html = """
        <html><body><h1>Opt out of the sale of my personal information</h1>
        <form id="f" onsubmit="event.preventDefault(); window.sent=true;">
          <label>First name *<input name="fn"></label><label>Last name *<input name="ln"></label>
          <div id="emails"><label>Email *<input type="email" name="em"></label></div>
          <button type="button" onclick="var d=document.createElement('div'); d.innerHTML='<label>Email<input type=email name=em2></label>'; document.getElementById('emails').appendChild(d);">Add another email</button>
          <div id="phones"><label>Phone<input type="tel" name="ph"></label></div>
          <a href="#" onclick="var d=document.createElement('div'); d.innerHTML='<label>Phone<input type=tel name=ph2></label>'; document.getElementById('phones').appendChild(d); return false;">+ Add phone</a>
          <button type="button" onclick="this.parentNode.removeChild(this)">Remove</button>
          <button type="submit">Opt out</button></form></body></html>
        """
        var me = pat; me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.emails = ["pat@example.com", "pat.old@example.org"]; me.phones = ["312-555-0142", "773-555-0199"]
        let session = WebViewSession.make()
        defer { session.close() }
        try await session.loadHTML(html)
        let filled = await session.scanAndFill(person: me)
        XCTAssertGreaterThan(filled, 0)
        func val(_ n: String) async -> String { (await session.evalLive("(document.querySelector('[name=\"\(n)\"]')||{}).value") as? String) ?? "(missing)" }
        let em = await val("em"), em2 = await val("em2"), ph = await val("ph"), ph2 = await val("ph2")
        XCTAssertEqual(em, "pat@example.com")
        XCTAssertEqual(em2, "pat.old@example.org", "the second email has a box now")
        XCTAssertEqual(ph, "3125550142")
        XCTAssertEqual(ph2, "7735550199", "the second phone has a box now")
        let sent = (await session.evalLive("window.sent===true") as? Bool) ?? false
        XCTAssertFalse(sent, "pressing the add buttons sends nothing")
        let removed = (await session.evalLive("[].slice.call(document.querySelectorAll('button')).some(function(b){return b.innerText==='Remove';})") as? Bool) ?? false
        XCTAssertTrue(removed, "a Remove button is never pressed")
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

    // MARK: what counts as a check that stops the run

    private func challenge(_ html: String) async throws -> String? {
        let session = WebViewSession.make(); defer { session.close() }
        try await session.loadHTML(html)
        return await session.visibleChallenge()
    }

    func testAReCAPTCHAErrorMeansOnlyThePersonsOwnPressCanGetPast() async throws {
        let got = try await challenge("<html><body><div class='err'>There was a problem with your submission. The reCAPTCHA response was missing or invalid.</div><form><input></form></body></html>")
        XCTAssertEqual(got, "a reCAPTCHA that rejected the automatic send")
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
