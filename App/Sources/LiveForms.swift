import Foundation
import WebKit
import OptOutKitCore

extension WebViewSession {
    /// Denies cookie and consent prompts that sit over the page. They load late, so this is tried more than once. Never accepts.
    func denyCookies() async -> String? {
        let js = PageScript.source("deny-cookies")
        return (try? await evaluate(js)) as? String
    }

    /// The page's address and visible text (in the frame the form lives in, when it does), to tell when a click changed it.
    func pageMark() async -> String {
        let text = (await evalLive("document.body ? document.body.innerText : ''")) as? String ?? ""
        return (webView.url?.absoluteString ?? "") + "|" + text
    }

    /// Waits until the page differs from `mark` (a click opened something or moved to another page), at most `seconds`. Returns at once when it does,
    /// where a fixed pause always waited the whole time. Then the caller lets the page settle.
    @discardableResult
    func waitForChange(from mark: String, upTo seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !abandoned, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if webView.isLoading { return true }          // a load under way is the answer starting
            if await pageMark() != mark { return true }
        }
        return false
    }

    /// Looks for an opt-out form every quarter second for at most `seconds` (it can take a moment to appear after a click), returning as soon as one shows.
    /// The last look also reads the page's frames, as a single look always did.
    func formsAppearing(upTo seconds: TimeInterval) async -> [LiveForm] {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !abandoned, !Task.isCancelled {
            let now = await discoverForms(waitForFrames: false)
            if LiveFormPicker.pick(now, pageContext: await pageContext()) != nil { return now }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return await discoverForms()
    }

    /// Evaluates in the frame the chosen form lives in (a page inside the page), else in the page itself.
    func evalLive(_ js: String) async -> Any? {
        if let f = activeFrame { return try? await evaluate(js, in: f, contentWorld: .page) }
        return try? await evaluate(js)
    }

    /// The forms on the page, and when the page itself shows none that looks like an opt-out form, the forms inside its frames (privacy portals are
    /// often embedded from another site). When a frame's form is the one, every later step runs in that frame.
    func discoverForms(waitForFrames: Bool = true) async -> [LiveForm] {
        activeFrame = nil
        let main = await discoverFormsIn()
        let context = await pageContext()
        if LiveFormPicker.pick(main, pageContext: context) != nil { return main }
        // A frame reports itself only once it has loaded: when the page has frames none of which has reported yet, each one is read as it reports,
        // for up to 2.5 seconds (the fixed pause this replaced), and the first holding an opt-out form is the one.
        var waitsForFrames = false
        if waitForFrames, frames.isEmpty { waitsForFrames = ((try? await evaluate("document.querySelectorAll('iframe').length")) as? Int ?? 0) > 0 }
        let deadline = Date().addingTimeInterval(waitsForFrames ? 2.5 : 0)
        var read = Set<String>()
        repeat {
            for frame in frames where !read.contains(frame.href) {
                read.insert(frame.href)
                activeFrame = frame.info
                let inside = await discoverFormsIn()
                if LiveFormPicker.pick(inside, pageContext: context) != nil { await scrollFrameIntoView(frame.href); return inside }
            }
            activeFrame = nil
            if Date() >= deadline || abandoned || Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        } while true
        // Nothing found while waiting: every frame is read once more as it stands now (one that reported early may have built its form since), as the
        // single look after the pause did.
        if waitsForFrames {
            for frame in frames {
                activeFrame = frame.info
                let inside = await discoverFormsIn()
                if LiveFormPicker.pick(inside, pageContext: context) != nil { await scrollFrameIntoView(frame.href); return inside }
            }
        }
        activeFrame = nil
        return main
    }

    /// Brings the frame a form is in to the middle of the screen, so the person sees it.
    func scrollFrameIntoView(_ href: String) async {
        let js = PageScript.call("scroll-frame-into-view", href)
        _ = try? await evaluate(js)
    }

    /// A form folded inside a closed accordion (`<details>`) has no size, so it is not seen. Clicks the headings of the closed ones that hold inputs,
    /// one at a time (some sites keep only one open), and returns the forms from the first that shows an opt-out form.
    func openFoldedForms() async -> [LiveForm]? {
        let count = (try? await evaluate("document.querySelectorAll('details:not([open])').length")) as? Int ?? 0
        guard count > 0 else { return nil }
        for i in 0..<min(count, 6) {
            let js = "(function(i){var ds=[].slice.call(document.querySelectorAll('details')).filter(function(d){return d.querySelector('input,select,textarea');}); var d=ds[i]; if(!d) return false; var s=d.querySelector('summary'); if(!s) return false; if(!d.open){s.scrollIntoView({block:'center'}); s.click();} return true;})(\(i));"
            guard (try? await evaluate(js)) as? Bool == true else { break }
            try? await Task.sleep(nanoseconds: 900_000_000)
            let after = await discoverFormsIn()
            if LiveFormPicker.pick(after, pageContext: await pageContext()) != nil { return after }
        }
        return nil
    }

    /// Opens a privacy request that hides behind a link or button on the page ("Submit a privacy request", "Your Privacy Choices") when no form shows,
    /// then looks again. Only a link that opens something in the page (no address, `#` or a script) is clicked, never one that writes an email.
    func discoverFormsDeep() async -> [LiveForm] {
        var first = await discoverForms()
        if LiveFormPicker.pick(first, pageContext: await pageContext()) != nil { return first }
        // A form the page builds a few seconds after it loads (blackbaud.com's OneTrust web form): looked for again for a while before anything is clicked. Only on a
        // page that looks unfinished (a privacy portal's host, or "Loading..."): every other page would wait for nothing, and a run's sites have a time limit.
        if await pageLooksUnbuilt() {
            first = await formsAppearing(upTo: 6)
            if LiveFormPicker.pick(first, pageContext: await pageContext()) != nil { return first }
        }
        if let opened = await openFoldedForms() { return opened }
        // Each click is followed by looking for the form until it shows (at most the pause each used to wait in full).
        let js = PageScript.source("open-request-links")
        let startURL = webView.url, startMark = await pageMark()
        if let clicked = (try? await evaluate(js)) as? String, !clicked.isEmpty {
            // A link that opens a new tab is opened in place (open-request-links): that loads another page, so it is waited for like a followed link.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if webView.isLoading || webView.url != startURL {
                await waitForChange(from: startMark, upTo: 4)
                await settlePage(maxWait: 6)
                let after = await discoverForms()
                if LiveFormPicker.pick(after, pageContext: await pageContext()) != nil { return after }
            } else {
                let after = await formsAppearing(upTo: 2.5)
                if LiveFormPicker.pick(after, pageContext: await pageContext()) != nil { return after }
            }
        }
        // A choice of requests or a "who is asking" step in front of the form.
        if await advanceToRequestForm(loose: true) != nil {
            let after = await formsAppearing(upTo: 2.5)
            if LiveFormPicker.pick(after, pageContext: await pageContext()) != nil { return after }
        }
        // The opt-out is a link to its own page: follow the clearest one that stays on the site (never a mail link or another company's page).
        let follow = PageScript.source("open-request-links-follow")
        let before = await pageMark()
        guard let went = (try? await evaluate(follow)) as? String, !went.isEmpty else { return first }
        // Until the new page has replaced the old one (the old one would look settled), then until it settles.
        await waitForChange(from: before, upTo: 4)
        await settlePage(maxWait: 6)
        let after = await discoverForms()
        if LiveFormPicker.pick(after, pageContext: await pageContext()) != nil { return after }
        return await openFoldedForms() ?? first
    }

    /// A privacy portal's page (OneTrust, TrustArc, Securiti, saymine, ...), or a short page that says it is loading: it may still be building its form.
    func pageLooksUnbuilt() async -> Bool {
        let js = "(function(){var t=(document.body&&document.body.innerText||'').replace(/\\s+/g,' ').trim(); return /onetrust|trustarc|securiti|saymine|osano|ketch|transcend|datagrail|termly/i.test(location.hostname)||(t.length<300&&/loading|please wait|one moment/i.test(t));})()"
        return ((try? await evaluate(js)) as? Bool) ?? false
    }

    /// Every visible form with its fields. Each form and field gets a `data-ook` token so later steps find the same element.
    func discoverFormsIn() async -> [LiveForm] {
        let js = PageScript.source("discover-forms")
        guard let json = (await evalLive(js)) as? String, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([LiveForm].self, from: data)) ?? []
    }

    /// For a site with no known form: looks for the opt-out form on the live page (opening its links, accordions and request choices) and fills it
    /// in with the person's details. Never sends. Returns how many fields were filled, 0 when no opt-out form was found.
    func scanAndFill(person: Person, advertisingID: String? = nil) async -> Int {
        await settlePage(maxWait: 6)
        _ = await denyCookies()
        _ = await advanceToRequestForm()
        let forms = await discoverFormsDeep()
        let context = await pageContext()
        guard let picked = LiveFormPicker.pick(forms, pageContext: context) else { return 0 }
        chosenForm = picked.token
        let page = webView.url ?? URL(string: "https://invalid.example/")!
        let plan = FormFiller.plan(for: picked.asOptOutForm(page: page), signals: nil, person: person, advertisingID: advertisingID)
        // Fill what we can even when the form also asks for something we do not hold: the person completes the rest.
        var fill = await fillLive(plan.values, keepExisting: true)
        // More emails or phones than boxes: press the page's "Add another" button, read the form again and fill the new boxes too.
        if await addAnotherBoxes(form: picked.token, emails: person.emails.count, phones: person.phones.count) > 0,
           let again = LiveFormPicker.pick(await discoverForms(), pageContext: await pageContext()) {
            chosenForm = again.token
            let grown = FormFiller.plan(for: again.asOptOutForm(page: page), signals: nil, person: person, advertisingID: advertisingID)
            let more = await fillLive(grown.values, keepExisting: true)
            fill = (max(fill.filled, more.filled), more.unmatchedRequired)
        }
        if fill.filled > 0 {
            _ = await chooseRequestOptions(form: picked.token, ownerMayConfirm: person.mayConfirmOwnIdentity())
            _ = await chooseCustomMenus(state: USStates.name(for: person.currentAddress?.state ?? ""))
            _ = await chooseTileButtons()
            await scrollFormIntoView(picked.token)
        }
        return fill.filled
    }

    /// Privacy portals that open on a choice of requests ("Start Access Request", "Start Deletion Request", "Start Opt Out Request"): clicks the one a
    /// person asking to be removed wants, so the form behind it is on the page. Opt-out of sale or sharing first, then deletion; never access, transfer,
    /// correction or update. Repeats once for a second step. Returns what it clicked, or nil when the page has no such choice.
    func advanceToRequestForm(loose: Bool = false) async -> String? {
        var clicked: String?
        for _ in 0..<2 {
            let js = PageScript.call("advance-to-request-form", loose)
            let before = await pageMark()
            guard let t = (await evalLive(js)) as? String, !t.isEmpty else { break }
            clicked = t
            // Until the click has changed the page (at most the 2.5 seconds this always waited), then until it settles.
            await waitForChange(from: before, upTo: 2.5)
            await settlePage(maxWait: 5)
        }
        return clicked
    }

    /// A page whose request form is behind an intro step ("Click the button below to start this process": Next) and which already shows a later-step form
    /// beside it (one with its email box switched off): presses the one Next / Continue / Start button so the form that asks for the person's address opens.
    /// Only on a page about opting out, only when exactly one such button shows, and never one in a cookie or consent prompt. Returns true when it pressed it.
    func pressIntroNext() async -> Bool {
        let js = PageScript.source("press-intro-next")
        let before = await pageMark()
        guard (try? await evaluate(js)) as? Bool == true else { return false }
        await waitForChange(from: before, upTo: 2.5)
        await settlePage(maxWait: 5)
        return true
    }

    /// Fills the values the plan chose, finding each field by its token.
    /// Fills the form; menus that fill in after another choice (a state list that waits for the country) get a second pass.
    func fillLive(_ values: [FieldValue], keepExisting: Bool = false) async -> (filled: Int, unmatchedRequired: [String]) {
        MainThreadWatch.note("filling")
        keepExistingValues = keepExisting
        // Filling goes on for as long as it keeps getting somewhere: a choice can reveal more boxes, and each pass fills what the last one uncovered. There is
        // no fixed number of passes; it stops when a pass leaves nothing required unfilled, or fills no more than the one before (the last guard is only against a page that never settles).
        var result = await fillLiveOnce(values)
        var total = result.filled
        var pass = 1
        // A country was chosen: the page may clear or rebuild its State menu once its own change handler has run, after the pass that chose it. One more
        // pass a moment later fills what that left empty (it keeps everything already filled).
        if result.again {
            try? await Task.sleep(nanoseconds: 900_000_000)
            let next = await fillLiveOnce(values); pass += 1; total += next.filled; result = next
        }
        while !result.unmatchedRequired.isEmpty, pass < 25 {
            try? await Task.sleep(nanoseconds: 900_000_000)
            let next = await fillLiveOnce(values)
            pass += 1
            total += next.filled
            let progressed = next.unmatchedRequired.count < result.unmatchedRequired.count || next.filled > 0 && next.unmatchedRequired != result.unmatchedRequired
            result = next
            if !progressed { break }
        }
        await tryPhoneFormats()
        await tryDateFormats()
        return (max(total, result.filled), result.unmatchedRequired)
    }

    /// When set, a text box that already holds something (a link from an email pre-fills the name and email) is left as it is.
    private static var keep: Bool = false
    private var keepExistingValues: Bool { get { Self.keep } set { Self.keep = newValue } }

    private func fillLiveOnce(_ values: [FieldValue]) async -> (filled: Int, unmatchedRequired: [String], again: Bool) {
        let normal = values.filter { $0.type != FormFiller.confirmIdentityType }
        if values.contains(where: { $0.type == FormFiller.confirmIdentityType }) { _ = await tickIdentityBoxes() }
        let payload = normal.map { ["name": $0.name, "candidates": $0.candidates, "label": $0.label] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return (0, [], false) }
        let js = PageScript.call("fill-live", json: [json, keepExistingValues ? "true" : "false"])
        guard let out = (await evalLive(js)) as? String, let d = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return (0, [], false) }
        return (obj["filled"] as? Int ?? 0, obj["unmatched"] as? [String] ?? [], obj["again"] as? Bool ?? false)
    }

    /// A form with one email box or one phone box often has an "Add another email" / "+ Add phone" button. When the profile holds more emails or phones than the
    /// form has boxes, presses that button (one press per box needed, one box kind at a time) so the extra value has a place to go. Returns how many presses it made;
    /// the caller then reads the form again and fills the new boxes. Never presses a button that could send the form: a <button> with no type (it submits), a
    /// submit button, a link that goes somewhere, or anything worded as remove, delete, clear, send, submit, cancel or opt out.
    func addAnotherBoxes(form token: String, emails: Int, phones: Int) async -> Int {
        let wantE = min(emails, 5), wantP = min(phones, 5)
        guard wantE > 1 || wantP > 1 else { return 0 }
        let js = PageScript.call("add-another-boxes", token, wantE, wantP)
        var presses = 0
        for _ in 0..<8 {
            guard await evalLive(js) as? Bool == true else { break }
            presses += 1
            try? await Task.sleep(for: .milliseconds(600))
        }
        return presses
    }

    /// Looks at the phone boxes this fill typed into; one that shows an error (a failed pattern, an invalid flag, a visible error message) is tried
    /// again in other shapes, one at a time, until the error clears. A box the person changed is never touched, and when no shape works the plain digits go back.
    func tryPhoneFormats() async {
        guard await evalLive("document.querySelector('[data-ook-phone]')!==null") as? Bool == true else { return }
        try? await Task.sleep(for: .milliseconds(250))
        for step in 1...10 {
            guard await phoneFormatStep(step) else { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// One round of `tryPhoneFormats`: false when no box is in error or no other shape is left to try.
    private func phoneFormatStep(_ step: Int) async -> Bool {
        let js = PageScript.call("phone-format-step", step)
        guard let out = await evalLive(js) as? String, let d = out.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return (obj["bad"] as? Int ?? 0) > 0 && obj["more"] as? Bool == true
    }

    /// Birthdate and today's-date boxes typed into by this fill: one that shows an error (or a mask that mangled the date) is tried again in other date shapes, one at a time,
    /// until the error clears. A box the person changed is never touched; when no shape works the first shape goes back.
    func tryDateFormats() async {
        guard await evalLive("document.querySelector('[data-ook-dob]')!==null") as? Bool == true else { return }
        try? await Task.sleep(for: .milliseconds(250))
        for step in 1...14 {
            guard await dateFormatStep(step) else { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        await alignDateFormats()
    }

    /// A page's date boxes share one shape: when a box had to be retried (a birthdate that rejected month/day/year), the other date boxes this fill typed
    /// (today's date, which month/day/year would not flag because 11/05 is valid either way) are put in the shape that box settled on.
    private func alignDateFormats() async {
        let js = PageScript.source("align-date-formats")
        _ = await evalLive(js)
    }

    /// One round of `tryDateFormats`: false when no box is in error or no other shape is left to try.
    private func dateFormatStep(_ step: Int) async -> Bool {
        let js = PageScript.call("date-format-step", step)
        guard let out = await evalLive(js) as? String, let d = out.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return (obj["bad"] as? Int ?? 0) > 0 && obj["more"] as? Bool == true
    }

    /// Brings the form being filled to the top of the screen, so the person sees what was filled and does not have to hunt for it.
    func scrollFormIntoView(token: String) async {
        let js = PageScript.call("scroll-form-to-top", token)
        _ = await evalLive(js)
    }

    /// When the page now shows an opt-out button or link below the visible part ("Opt out" next to a listing that a search found), scrolls to it.
    /// Does nothing when one is already on screen, so it never moves a page the person is using. True when it scrolled.
    func scrollToOptOutControl() async -> Bool {
        let js = PageScript.source("scroll-to-opt-out-control")
        return ((try? await evaluate(js)) as? Bool) ?? false
    }

    /// A page that offers its one opt-out form as tabs ("Phone" and "Name"): opens the name tab, which is the one that takes a person's listing off.
    /// Returns true when it pressed one.
    func chooseNameTab() async -> Bool {
        let js = PageScript.source("choose-name-tab")
        return ((try? await evaluate(js)) as? Bool) ?? false
    }

    /// A page that keeps all its privacy forms hidden until a menu outside any form is set ("Select From Available Forms": Right to Opt-out, Right to Delete, Right to Know):
    /// picks the opt-out choice (else deletion) so that form shows. Never touches a menu the person set, never a menu inside a form, never access or correction.
    /// Returns true when it changed one.
    func chooseRightsPicker() async -> Bool {
        let js = PageScript.source("choose-rights-picker")
        return ((try? await evaluate(js)) as? Bool) ?? false
    }

    /// Every email address the page shows or links to (mailto links and addresses in the text), for the one a privacy request should go to.
    func pageEmails() async -> [String] {
        let js = PageScript.source("page-emails")
        guard let json = (await evalLive(js)) as? String, let data = json.data(using: .utf8), let list = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return list
    }

    /// Pages that ask "I am a(n)" or "Select request type" with a row of buttons instead of radio boxes: picks the plain consumer or "other" answer, and the
    /// opt-out or deletion request (never access, update, correction or transfer). Returns how many it pressed.
    func chooseTileButtons() async -> Int {
        let js = PageScript.source("choose-tile-buttons")
        return (await evalLive(js)) as? Int ?? 0
    }

    /// Chooses, inside one form, the options an opt-out needs: "this request is for myself", the opt-out and deletion choices, and a
    /// request-type menu. It never ticks access, correction or marketing choices, and never picks "authorized agent" or "deceased".
    /// Returns what it chose, and the names of required choices it could not make.
    func chooseRequestOptions(form token: String, ownerMayConfirm: Bool = false) async -> (chosen: Int, unresolved: [String]) {
        let js = PageScript.call("choose-request-options", token, ownerMayConfirm)
        guard let json = (await evalLive(js)) as? String, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (0, []) }
        return (obj["chosen"] as? Int ?? 0, obj["unresolved"] as? [String] ?? [])
    }

    /// The label of the first required menu, text box or choice in the form that is still empty, or nil when all are filled. A person is asked to
    /// fill it in: a state list without their state, a request type the app could not pick. Boxes that only certify something are left to their own rule.
    func emptyRequiredChoice(form token: String) async -> String? {
        let js = PageScript.call("empty-required-choice", token)
        let out = (await evalLive(js)) as? String
        return (out?.isEmpty ?? true) ? nil : out
    }

    /// The label of a confirmation button on the page ("Confirm request", "Verify my email"), scrolled into view, or nil. It is only found, never pressed:
    /// confirming is the person's own tap.
    func confirmButtonLabel() async -> String? {
        let js = PageScript.source("confirm-button-label")
        let out = (await evalLive(js)) as? String
        return (out?.isEmpty ?? true) ? nil : out
    }

    /// Custom drop-down menus that are not <select> elements (Material UI and similar): opens each empty one that asks about the person's relationship
    /// to the company or their state, and picks a consumer-style answer ("Consumer", "None", "Other", the person's state). Never picks employee,
    /// customer, vendor or business answers. Returns how many it set.
    /// `state` is the person's own state or region name: a menu that lists places picks that one, and never another.
    /// A state (or similar) box that is really a type-ahead list (OneTrust's "State of Residence": a text box that offers matching options as you type, and counts
    /// only an option you pick). Types the state's name, waits for the list, and picks the option that is exactly that name. Returns how many it chose.
    func chooseAutocomplete(state: String?) async -> Int {
        guard let state, !state.isEmpty else { return 0 }
        // A country box that is also a type-ahead comes first: a state box beside it ("State (select country first)") stays switched off until a country is picked.
        // The person's state is a US state here, so the country is the United States.
        let country = await pickFromTypeAhead(kind: "country", name: "United States")
        if country > 0 { try? await Task.sleep(nanoseconds: 600_000_000) }
        return country + (await pickFromTypeAhead(kind: "state", name: state))
    }

    /// One kind of type-ahead box ("state" or "country"): types the name, waits for the list, picks the option that is exactly that name. Returns how many it chose.
    private func pickFromTypeAhead(kind: String, name: String) async -> Int {
        let open = PageScript.call("type-ahead-open", kind, name)
        var chosen = 0
        for _ in 0..<4 {
            guard (await evalLive(open)) as? Bool == true else { break }
            // The match is taken as soon as it shows: TrustArc's "Resident of" (azira.com) listed "Illinois" for under half a second and closed its list, and the
            // app, looking once after 0.7 s, left the box holding the typed text (scrolled to "linois") with nothing chosen. A list that closed is opened again
            // (`type-ahead-choose` presses the down arrow in the box), for up to 5 s.
            let pick = PageScript.call("type-ahead-choose", name)
            for _ in 0..<33 {
                if (await evalLive(pick)) as? Bool == true { chosen += 1; break }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return chosen
    }

    func chooseCustomMenus(state: String? = nil) async -> Int {
        var set = 0
        // Every empty menu on the form is set, however many there are: the loop ends when none is left (the bound only guards against a page that keeps adding menus).
        for _ in 0..<60 {
            let open = PageScript.call("custom-menus-open", state ?? "")
            guard let label = (await evalLive(open)) as? String, !label.isEmpty else { break }
            try? await Task.sleep(nanoseconds: 700_000_000)
            let pick = PageScript.call("custom-menus-pick", state ?? "")
            if let t = (await evalLive(pick)) as? String, !t.isEmpty {
                if t.hasPrefix("not-offered:") { stateNotOffered = String(t.dropFirst("not-offered:".count)) } else { set += 1 }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return set
    }

    /// After a form's first button ("Review Request"), the page often shows a summary with its own final button ("Submit Request", "Confirm"): presses
    /// that one. Only when the page says it is a review or confirmation step, so a form is never sent twice. Returns whether it pressed something.
    func pressConfirmStep() async -> Bool {
        let js = PageScript.source("press-confirm-step")
        return ((await evalLive(js)) as? Bool) ?? false
    }

    /// Presses the chosen form's own send button, whatever it says ("Opt me out", "Submit request"); never one that says agree, accept or cancel.
    func pressLiveSubmit(form token: String) async -> Bool {
        let js = PageScript.call("press-live-submit", token)
        let answer = await evalLive(js)
        pressHeldForEmptyBox = (answer as? String) == "invalid"
        let pressed = (answer as? Bool) ?? false
        if pressed { SiteRun.markSent?() }          // a background run's watchdog now knows the form went to the site (`SiteRun`)
        return pressed
    }

    /// The page's address path and title: a form on a page about opting out is more likely the opt-out form.
    func pageContext() async -> String {
        // The address, the title and the first words of the page: a portal whose only form asks "State of Residence" says what it is for in its intro
        // ("you may have rights with respect to your personal information… exercise these rights"), not in the form.
        ((try? await evaluate("location.pathname + ' ' + document.title + ' ' + (document.body ? document.body.innerText.replace(/\\s+/g,' ').slice(0,300) : '')")) as? String) ?? ""
    }

    /// A visible, empty text box that asks for a code ("Captcha", "Security code"): the person types it, and the form is not sent until it is filled.
    func emptyCodeField() async -> Bool {
        let js = PageScript.source("empty-code-field")
        return ((await evalLive(js)) as? Bool) ?? false
    }

    /// Whether the person is partway through typing a bot-check or code box: it holds something, and the box has the cursor (up to 12 s without a key) or was
    /// typed in within the last 3 s. A box that is empty is `emptyCodeField`; this is the other half, so the first letter typed never counts as "done".
    func codeBoxInUse() async -> Bool {
        let js = PageScript.source("code-box-in-use")
        return ((await evalLive(js)) as? Bool) ?? false
    }

    /// Whether a visible, empty box asks for a code sent to the person ("Verification code", "Enter the code"): a verification step that is not finished yet.
    func emptyVerificationCodeBox() async -> Bool {
        let js = PageScript.source("empty-verification-code-box")
        return ((await evalLive(js)) as? Bool) ?? false
    }

    /// Whether the chosen form is still on the page and visible, and the page's address.
    func formState(_ token: String) async -> (visible: Bool, url: String) {
        let js = PageScript.call("form-state", token)
        guard let out = (await evalLive(js)) as? String, let d = out.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return (true, "") }
        return (o["v"] as? Bool ?? true, o["u"] as? String ?? "")
    }

    /// Hides what is left of a cookie or consent overlay that would not be dismissed, so it does not cover the form or the result.
    /// (It consents to nothing; it only stops covering the page.)
    func hideConsentOverlays() async {
        let js = PageScript.source("hide-consent-overlays")
        _ = await evalLive(js)
    }

    /// Scrolls the chosen form to the top of the view, so the picture shows the form and what the site said about it.
    func scrollFormIntoView(_ token: String) async {
        _ = await evalLive(PageScript.call("scroll-form-into-view", token))
    }

}

extension FormRun {
    /// Opens the page, denies cookie prompts, finds the opt-out form on the live page, fills it from the person's details, chooses the
    /// opt-out options, sends it and judges only what appeared afterwards. `person` is already the household's form view of them.
    @MainActor
    static func runLive(url: URL?, html: String?, person: Person, dryRun: Bool, maxWait: TimeInterval, capture: Bool, advertisingID: String? = nil) async -> SubmitEvidence {
        let session = WebViewSession.make()
        defer { session.close() }
        RunStep.note("loading the page")
        do {
            if let html { try await session.loadHTML(html) }
            else if let url, url.isSecureWebPage { try await session.load(URLRequest(url: url)) }
            else { return SubmitEvidence(outcome: .failed("not a secure page")) }
        } catch { return SubmitEvidence(outcome: .failed("the page would not load")) }
        let said = SaidBox()
        let outcome = await liveSteps(session, page: url ?? URL(string: "https://local.test/")!, person: person, dryRun: dryRun, maxWait: maxWait, advertisingID: advertisingID, said: said)
        #if DEBUG
        if dryRun, capture {
            // For offline analysis: the page as it stands after every click the run made, and a summary of the form it chose.
            var snapshot = (html: ((try? await session.evaluate("document.documentElement.outerHTML")) as? String) ?? "", picked: "")
            if let token = session.chosenForm {
                let js = PageScript.call("describe-form", token)
                snapshot.picked = ((try? await session.evaluate(js)) as? String) ?? ""
            }
            snapshot.picked += "\n" + (url.flatMap { debugForms[$0.absoluteString] } ?? "")
            if let url { debugSnapshots[url.absoluteString] = snapshot }
        }
        #endif
        // What the page said, only for a form that was sent: what appeared after sending, or (nothing new appeared) the text on screen. A site stopped
        // before sending keeps none; its reason says why.
        var pageText: String?
        if !dryRun, let text = said.text { pageText = text.isEmpty ? await session.viewportText() : text }
        RunStep.note("taking the screenshot")
        return SubmitEvidence(outcome: outcome, screenshot: capture ? await session.screenshotJPEG(aroundForm: session.chosenForm) : nil, pageText: pageText)
    }

    /// A portal whose state menu lists only some states (those with a privacy law) and not the person's: its form is not for them; the email is.
    static func stateNotOffered(_ state: String) -> String { "the site's form takes requests only from the states it lists, and \(state) is not one of them; email them instead" }

    /// What `visible-challenge` says of a Cloudflare (Turnstile) check that has not passed yet.
    static let cloudflareCheck = "a Cloudflare check"

    /// A form with more steps than the site's time allowed: the last step was not sent.
    static let moreStepsThanTime = "the form had more steps than the time allowed"

    /// Carries the text the page showed after sending out of `liveSteps`; nil when send was never pressed.
    @MainActor final class SaidBox { var text: String? }

    @MainActor
    private static func liveSteps(_ session: WebViewSession, page: URL, person: Person, dryRun: Bool, maxWait: TimeInterval, advertisingID: String?, said: SaidBox) async -> SubmitOutcome {
        RunStep.note("waiting for the page to settle")
        await session.settlePage(maxWait: 10)
        RunStep.note("answering the cookie prompt")
        // The page has been still for a moment, so a cookie prompt has had time to show. The page settles again only after a prompt was answered (it then
        // reloads or moves); a fixed pause and a second wait for every site cost about four seconds each.
        if await session.denyCookies() != nil { await session.settlePage(maxWait: 4) }
        if await session.denyCookies() != nil { await session.settlePage(maxWait: 4) }      // prompts that load late
        await session.hideConsentOverlays()
        if await session.pageLooksMissing() { return .failed(FormRun.pageGone) }
        if await session.hasTermsPrompt() { return .challenged("a terms prompt that you need to accept yourself") }

        // From here the page is handled by the same code Solve and send and Email links use (`WebAssistedDriver.prepareLoaded`, `WebAssistedPage`): finding the form,
        // the choices, the forms that appear as others are answered, several forms on one page, steps, the bot-check rules. This run only differs in having nobody to ask.
        let driver = WebAssistedDriver(person: person, advertisingID: advertisingID, termsPolicy: nil)
        let stand = OptOutForm(page: page, method: "post", action: nil, fields: [], hops: 1)
        #if DEBUG
        let found = await session.discoverFormsDeep()
        let context = await session.pageContext()
        debugForms[page.absoluteString] = found.map { "\($0.token) score=\(LiveFormPicker.score($0, pageContext: context)) text=\($0.text) | buttons=\($0.buttons) fields=\($0.fields.map { "\($0.type):\($0.name):\($0.label):v=\($0.visible)" })" }.joined(separator: "\n")
        #endif
        RunStep.note("finding and filling the form")
        guard let prepared = await driver.prepareLoaded(session: session, form: stand, plan: FillPlan(values: [], verdict: .ready), keepOpenWithoutForm: true) as? WebAssistedPage else {
            if let state = session.stateNotOffered { return .failed(Self.stateNotOffered(state)) }
            // A form held behind a human check (a reCAPTCHA with Submit off until it is ticked, as allwebleads.com's) is not "no form": it is the person's check.
            if let why = await session.visibleChallenge() { return .challenged(why) }
            return .failed("no opt-out form was found on the page")
        }
        prepared.maxWait = maxWait
        // A form the page shows only once a choice is made ("Who is this request for? Myself") appears when the choices are answered, which the fill does: the form on
        // screen has nothing to fill until then, so it is filled again (as Solve and send does, which adopts the form that appeared) before it is judged.
        if prepared.problem != nil { await prepared.refill() }
        if let problem = prepared.problem {
            // A form behind a visible human check (LiveRamp's device opt-out, which adprime.com uses: an ad-ID box and a reCAPTCHA) is the person's for the check,
            // whatever else held it: said as the check, so the site's line is "Blocked by a human check".
            if let why = await session.visibleChallenge(), why != Self.cloudflareCheck { return .challenged(why) }
            return .failed(problem)
        }
        // Some forms send themselves the moment a choice is made: then the page already shows the result.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if !dryRun, let early = await prepared.earlyConfirmation() { return early }
        if dryRun {
            if let token = prepared.currentFormToken { await session.scrollFormIntoView(token: token) }
            #if DEBUG
            var blocked: [String] = []
            if await session.hasTermsPrompt() { blocked.append("terms") }
            if let c = await session.pendingCertification() { blocked.append("certify:" + c.prefix(40)) }
            if let c = await session.visibleChallenge() { blocked.append("check:" + c) }
            debugLastBlockers = blocked
            debugLastFormPage = page.absoluteString
            #endif
            return .filledNotSubmitted
        }
        // A Cloudflare check that is still "Verifying..." usually passes by itself in a few seconds (nothing is clicked or solved): the run waits for it, within the
        // site's time and short of the quiet limit. A check that asks for a person stays, and the site goes to them as before (coloradoarrests.org).
        RunStep.note("checking for a human check")
        let checkLimit = SiteRun.wait(upTo: 12)
        var checkWaited: TimeInterval = 0
        while checkWaited < checkLimit, await session.visibleChallenge() == Self.cloudflareCheck {
            try? await Task.sleep(nanoseconds: 1_000_000_000); checkWaited += 1
        }
        // Nobody to ask: anything the page needs from a person ends the run for this site, saying what.
        for blocker in await prepared.blockers() {
            switch blocker {
            case .terms: return .challenged("a terms prompt that you need to accept yourself")
            case .certify: return .challenged("a certification box that you must tick yourself")
            case .check(let why): return .challenged(why)
            case .choose(let what): return .failed("the form needs a choice we cannot make for you (\(what))")
            }
        }
        // Send each opt-out form of the page; a form that moves on to a next step is filled and sent again.
        var result: SubmitOutcome = .failed("no submit button found")
        var sentAny = false, sentEmail = false, rounds = 0
        while rounds < 6 {
            // Another round only while the site has time left to read its page afterwards (`SiteRun.deadline`): a round that is cut off reads nothing.
            if rounds > 0, SiteRun.wait(upTo: 10) < 3 {
                result = sentAny ? .submitted(awaitingEmail: sentEmail) : .failed(FormRun.moreStepsThanTime)
                break
            }
            rounds += 1
            await prepared.refill()
            let step = await PageFlow.sendOnce(prepared)
            if let text = prepared.lastSaid, !text.isEmpty || said.text == nil { said.text = text }          // set once send was pressed (empty: nothing new)
            #if DEBUG
            debugLastPageText = await session.visibleText()
            #endif
            switch step {
            case .sent(let email, let more):
                sentAny = true; sentEmail = sentEmail || email
                if more { continue }
                return .submitted(awaitingEmail: sentEmail)
            case .nextStep: continue
            case .handToPerson: return sentAny ? .submitted(awaitingEmail: sentEmail) : .challenged("a reCAPTCHA that rejected the automatic send")
            case .checkAppeared(let why): return sentAny ? .submitted(awaitingEmail: sentEmail) : .challenged(why)
            case .dryRun: return .filledNotSubmitted
            case .notConfirmed(let answer):
                if sentAny { return .submitted(awaitingEmail: sentEmail) }
                result = answer
            }
            break
        }
        await session.scrollFormIntoView(session.chosenForm ?? "")
        return result
    }

    #if DEBUG
    /// What the page said at the end of the last live run, for tests that check what the form received.
    nonisolated(unsafe) static var debugLastPageText = ""
    nonisolated(unsafe) static var debugLastBlockers: [String] = []
    nonisolated(unsafe) static var debugForms: [String: String] = [:]
    nonisolated(unsafe) static var debugSnapshots: [String: (html: String, picked: String)] = [:]
    nonisolated(unsafe) static var debugLastFormPage = ""
    #endif
}
