import Foundation
import OptOutKitCore

/// What is really on the page the person would see: the forms, their fields and their buttons, read from the live page after scripts have run
/// (not from a copy of the HTML fetched earlier). The crawler's stored form is only a hint; this is what the run fills in and sends.
struct LiveField: Decodable, Equatable {
    var token: String           // data-ook attribute the page JS put on the element, so it can be found again whatever its name is
    var name: String
    var type: String
    var label: String
    var required: Bool
    var visible: Bool
    /// The page switched the box off. An email box that is disabled cannot take the person's address: that form is a later step (Peoplefinders' record form, after the emailed link).
    var disabled: Bool?
}

struct LiveForm: Decodable, Equatable {
    var token: String
    var action: String
    var method: String
    var visible: Bool
    var fields: [LiveField]
    var buttons: [String]
    var text: String
    /// The words around the form's inputs (the nearest block of text that holds them): a newsletter box says so there, whatever its button says.
    var ctx: String?
    /// The heading just above the form, outside it ("Contact Us", "What to report"): not part of the form's own text.
    var head: String?

    /// The form as the filler understands it. Each field is named by its token, and its label carries the page's own name for it, so the
    /// same synonyms that read a stored form read this one.
    func asOptOutForm(page: URL) -> OptOutForm {
        OptOutForm(page: page, method: method.lowercased(), action: URL(string: action),
                   fields: fields.filter { $0.visible }.map { FormField(type: $0.type, name: $0.token, label: ($0.label + ($0.required && !$0.label.contains("*") ? " *" : "") + ($0.name.isEmpty ? "" : " | " + $0.name)).trimmingCharacters(in: .whitespaces)) }, hops: 1)
    }
}

enum LiveFormPicker {
    /// The form's way forward is a Next or Continue button, with nothing that sends ("Submit", "Send request"): pressing it opens the next step of a wizard,
    /// it never sends the request, whatever happens to the page.
    nonisolated static func movesToNextStep(_ f: LiveForm) -> Bool {
        let forward = f.buttons.filter { $0.range(of: "^\\s*(back|previous|cancel|close)\\s*$", options: [.regularExpression, .caseInsensitive]) == nil }
        return !forward.isEmpty && forward.allSatisfy { $0.range(of: "^\\s*(next|continue|next step|proceed|continue to next step)\\s*[›>→]?\\s*$", options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// A wizard step with only choices to make ("What would you like to do?", "Who is submitting this request? Myself"), and Next: nothing of the person's is typed
    /// here, so it is not a form we "could not match"; its choices are made and Next is pressed (privacy.datarate.ai).
    nonisolated static func isChoiceStep(_ f: LiveForm) -> Bool {
        // Its radios may be hidden behind styled cards (privacy.datarate.ai's are screen-reader-only), so a choice counts shown or not; no box to type may show.
        let isChoice: (LiveField) -> Bool = { $0.type == "radio" || $0.type == "checkbox" }
        return movesToNextStep(f) && f.fields.contains(where: isChoice) && !f.fields.contains { $0.visible && !isChoice($0) && $0.type != "hidden" }
    }

    private static let marketing = try! NSRegularExpression(pattern: "subscribe|free trial|get started|sign.?up|log.?in|sign.?in|search|book a|demo|contact us|get in touch|newsletter|join|download|add another", options: .caseInsensitive)
    private static let optOut = try! NSRegularExpression(pattern: "opt.?(me.?)?out|do not sell|don.?t sell|do-not-sell|privacy|delete|deletion|remove|erase|request|rights|unsubscribe|suppress|removal", options: .caseInsensitive)
    /// A form that signs someone up for something, or only sends a message to sales: never filled in, whatever the page around it says.
    private static let signup = try! NSRegularExpression(pattern: "subscribe|newsletter|sign.?up|register(?!ed)|create (an? )?account|\\bjoin\\b|waitlist|\\bdemo\\b|free trial|get started|contact sales|talk to|activation|log.?in|sign.?in|shortlist|get in touch|send message|contact us|request a (quote|call)|book a|get my [a-z ]*(guide|report)|show my report|free (guide|report)", options: .caseInsensitive)
    /// Newsletter and marketing language in the words around a form's inputs.
    private static let signupContext = try! NSRegularExpression(pattern: "newsletter|(?<!un)subscrib(e|ing|ed)|receive (updates|news|emails?)|and receive|in your inbox|to your inbox|stay (updated|in the loop)|get (the )?(latest|updates)|join our|sign.?up for|free trial|updates (and|&) insights|delivered to|receive (communications|marketing)|agree to receive", options: .caseInsensitive)
    private static let strongOptOut = try! NSRegularExpression(pattern: "opt.?(me.?)?out|do not sell|don.?t sell|privacy (request|choices|rights)|delete my|deletion request|erasure|data subject|remove (me|my)", options: .caseInsensitive)
    private static let businessField = try! NSRegularExpression(pattern: "(business|work|corporate|company) e-?mail|\\bindustry\\b|job (title|function|role)|company size|number of employees", options: .caseInsensitive)
    /// Words of a form that is about something else (a sales quote, a consultation, a report to the site, a robot check). A generic "Submit Request" button does not rescue it; only an opt-out or deletion wording of its own does.
    private static let notOptOut = try! NSRegularExpression(pattern: "get a quote|request a (consultation|quote)|consultation|speak with|schedule a|what to report|contact(ing)? us|thank you for contacting|send (us )?a? ?message|put some numbers|confirm you are human|verify you are human", options: .caseInsensitive)
    /// A box of type password that really asks for a password (an account), not one that only hides what is typed (the last four digits of a social security number, a phone number).
    private static let passwordWord = try! NSRegularExpression(pattern: "pass\\s*word|passwort|contrase", options: .caseInsensitive)
    private static let maskedData = try! NSRegularExpression(pattern: "ssn|social|last (4|four)|phone|digit|\\bpin\\b|\\btel\\b|mobile", options: .caseInsensitive)
    private static let navigationToggle = try! NSRegularExpression(pattern: "navigation|\\bmenu\\b|submenu|hamburger", options: .caseInsensitive)
    private static let deceasedForm = try! NSRegularExpression(pattern: "deceased|decedent|late (husband|wife|mother|father)|passed away", options: .caseInsensitive)
    private static let identity = try! NSRegularExpression(pattern: "first|last|name|email|e-mail|address|zip|postal|phone|city", options: .caseInsensitive)

    private static func has(_ re: NSRegularExpression, _ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    /// A form whose own words say it is an opt-out or deletion request: not a search, a sign-up, a contact form or a feedback box, even on an opt-out page.
    /// Only these are sent after the first form of a page.
    static func isDedicatedOptOut(_ f: LiveForm, pageContext: String = "") -> Bool {
        guard score(f, pageContext: pageContext) >= 3 else { return false }
        let own = f.buttons.joined(separator: " ") + " " + f.text + " " + (f.ctx ?? "")
        return has(strongOptOut, own) || has(ownWords, f.buttons.joined(separator: " "))
    }
    private static let removalHeading = try! NSRegularExpression(pattern: "remove[ -](your|my)[ -](personal[ -])?(info|information|data|record|listing)|opt.?out|do not sell|delete (your|my)", options: .caseInsensitive)
    private static let searchButton = try! NSRegularExpression(pattern: "^\\s*search( now)?\\s*$", options: .caseInsensitive)
    private static let ownWords = try! NSRegularExpression(pattern: "opt.?(me.?)?out|do not sell|unsubscribe|delete|remove|erase", options: .caseInsensitive)

    /// Sites whose way to opt out is their contact form (they have no request form and no email), so it is the form to fill: the request goes in its message box.
    /// Matched against the page's address and title (`pageContext`). Never a general rule: a contact form is refused everywhere else.
    static let contactFormRoutes: [String] = ["affordable background checks"]

    /// How likely a form is the opt-out form: opt-out wording and several identity fields count for it, marketing wording against it.
    static func score(_ f: LiveForm, pageContext: String = "") -> Int {
        let fields = f.fields.filter { $0.visible && !["hidden", "submit", "button", "image", "password"].contains($0.type) }
        guard !fields.isEmpty else { return -100 }       // a form wrapper can have no size while its fields show; only the fields count
        let buttons = f.buttons.joined(separator: " ")
        let heading = f.text
        // A form whose email box is switched off is not the one that asks for the person's address (it comes after the emailed link): never filled.
        if fields.contains(where: { $0.type == "email" && $0.disabled == true }) { return -100 }
        // A site that takes opt-outs only through its contact form: that form (name, email, a message box) is the one, and its own button does not matter.
        if contactFormRoutes.contains(where: { pageContext.lowercased().contains($0) }), fields.contains(where: { $0.type == "textarea" }),
           fields.contains(where: { $0.type == "email" || has(identity, $0.label + " " + $0.name) }) { return 6 }
        if has(notOptOut, buttons + " " + String(heading.prefix(200)) + " " + (f.head ?? "")) && !has(strongOptOut, heading + " " + buttons + " " + (f.head ?? "")) { return -100 }
        // A form that asks for a password is an account sign-in or sign-up (no opt-out form does); a "form" of nothing but menu toggles is the page's navigation.
        if f.fields.contains(where: { $0.visible && has(passwordWord, $0.label + " " + $0.name) && !has(maskedData, $0.label + " " + $0.name) }) { return -100 }
        if fields.allSatisfy({ ["checkbox", "radio"].contains($0.type) && has(navigationToggle, $0.label + " " + $0.name) }) { return -100 }
        // Menus only, no button, and nothing about privacy in them or around them: a page's jump-to menu, not a request.
        if f.buttons.isEmpty, fields.allSatisfy({ $0.type == "select" }), !has(optOut, fields.map { $0.label + " " + $0.name }.joined(separator: " ") + " " + heading + " " + (f.head ?? "")) { return -100 }
        // A sign-up, demo or contact form is refused outright unless its own button says opt-out ("Unsubscribe" is one); the page's privacy wording does not rescue it.
        if has(signup, buttons + " " + String(heading.prefix(200))) && !has(optOut, buttons) && !has(strongOptOut, heading) { return -100 }
        // The words around the inputs say "newsletter" or "delivered to your inbox": a subscription box, whatever its button says.
        let ctx = f.ctx ?? ""
        // (A subscription box is small; a form with four or more inputs is not one, whatever sits near it.)
        // (Only the form's own button or words can rescue it: a footer's "Do Not Sell" link in the same block does not make a newsletter box an opt-out.)
        if fields.count <= 3 && has(signupContext, ctx) && !has(strongOptOut, heading + " " + buttons) { return -100 }
        // A form for businesses (a business or work email, an industry, a job title: a footer's "Stay Updated" or a sales enquiry) is never a person's opt-out,
        // unless its own button or words say opt out. The page's privacy wording does not rescue it.
        if fields.contains(where: { has(businessField, $0.label + " " + $0.name) }) && !has(strongOptOut, heading + " " + buttons) && !has(optOut, buttons) { return -100 }
        // A form of one input (just an email) needs something that says it is a privacy request, not only a page that mentions privacy.
        // (A privacy-policy link beside a footer box does not count: only the button, the heading or a real opt-out phrase around it does.)
        if fields.count <= 1 && !has(optOut, buttons + " " + heading) && !has(strongOptOut, ctx) { return -100 }
        var s = 0
        if has(optOut, buttons) { s += 4 }
        if has(optOut, heading) { s += 2 }
        // A form for a deceased person (a suppression list for the dead) is never the opt-out of a living one.
        if has(deceasedForm, heading + " " + buttons + " " + pageContext.prefix(300)) { s -= 8 }
        // A people-search site's removal starts with a search of its own records: a "Search" button under a heading that says to remove your information is that first step, not marketing.
        let removalHead = has(removalHeading, (f.head ?? "") + " " + heading + " " + pageContext)
        if removalHead { s += 2 }
        if has(marketing, buttons) && !(removalHead && has(searchButton, buttons)) { s -= 6 }
        if has(marketing, heading) && !has(optOut, buttons) { s -= 3 }
        if has(optOut, pageContext) { s += 3 }
        s += min(4, fields.filter { has(identity, $0.label + " " + $0.name) }.count)
        if fields.contains(where: { $0.type == "email" || has(try! NSRegularExpression(pattern: "e-?mail", options: .caseInsensitive), $0.label + $0.name) }) { s += 2 }
        if fields.contains(where: { $0.type == "password" }) { s -= 8 }
        return s
    }

    /// The best candidate, or nil when nothing on the page looks like an opt-out form.
    static func pick(_ forms: [LiveForm], pageContext: String = "") -> LiveForm? {
        let ranked = forms.map { ($0, score($0, pageContext: pageContext)) }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 >= 3 else { return nil }
        return best.0
    }
}
