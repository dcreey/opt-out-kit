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

    /// The form as the filler understands it. Each field is named by its token, and its label carries the page's own name for it, so the
    /// same synonyms that read a stored form read this one.
    func asOptOutForm(page: URL) -> OptOutForm {
        OptOutForm(page: page, method: method.lowercased(), action: URL(string: action),
                   fields: fields.filter { $0.visible }.map { FormField(type: $0.type, name: $0.token, label: ($0.label + ($0.required && !$0.label.contains("*") ? " *" : "") + ($0.name.isEmpty ? "" : " | " + $0.name)).trimmingCharacters(in: .whitespaces)) }, hops: 1)
    }
}

enum LiveFormPicker {
    private static let marketing = try! NSRegularExpression(pattern: "subscribe|free trial|get started|sign.?up|log.?in|sign.?in|search|book a|demo|contact us|get in touch|newsletter|join|download|add another", options: .caseInsensitive)
    private static let optOut = try! NSRegularExpression(pattern: "opt.?(me.?)?out|do not sell|don.?t sell|do-not-sell|privacy|delete|deletion|remove|erase|request|rights|unsubscribe|suppress|removal", options: .caseInsensitive)
    /// A form that signs someone up for something, or only sends a message to sales: never filled in, whatever the page around it says.
    private static let signup = try! NSRegularExpression(pattern: "subscribe|newsletter|sign.?up|register(?!ed)|create (an? )?account|\\bjoin\\b|waitlist|\\bdemo\\b|free trial|get started|contact sales|talk to|activation|log.?in|sign.?in|shortlist|get in touch|send message|contact us|request a (quote|call)|book a|get my [a-z ]*(guide|report)|show my report|free (guide|report)", options: .caseInsensitive)
    /// Newsletter and marketing language in the words around a form's inputs.
    private static let signupContext = try! NSRegularExpression(pattern: "newsletter|(?<!un)subscrib(e|ing|ed)|receive (updates|news|emails?)|and receive|in your inbox|to your inbox|stay (updated|in the loop)|get (the )?(latest|updates)|join our|sign.?up for|free trial|updates (and|&) insights|delivered to", options: .caseInsensitive)
    private static let strongOptOut = try! NSRegularExpression(pattern: "opt.?(me.?)?out|do not sell|don.?t sell|privacy (request|choices|rights)|delete my|deletion request|erasure|data subject|remove (me|my)", options: .caseInsensitive)
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
    private static let ownWords = try! NSRegularExpression(pattern: "opt.?(me.?)?out|do not sell|unsubscribe|delete|remove|erase", options: .caseInsensitive)

    /// How likely a form is the opt-out form: opt-out wording and several identity fields count for it, marketing wording against it.
    static func score(_ f: LiveForm, pageContext: String = "") -> Int {
        let fields = f.fields.filter { $0.visible && !["hidden", "submit", "button", "image", "password"].contains($0.type) }
        guard !fields.isEmpty else { return -100 }       // a form wrapper can have no size while its fields show; only the fields count
        let buttons = f.buttons.joined(separator: " ")
        let heading = f.text
        // A sign-up, demo or contact form is refused outright unless its own button says opt-out ("Unsubscribe" is one); the page's privacy wording does not rescue it.
        if has(signup, buttons + " " + String(heading.prefix(200))) && !has(optOut, buttons) && !has(strongOptOut, heading) { return -100 }
        // The words around the inputs say "newsletter" or "delivered to your inbox": a subscription box, whatever its button says.
        let ctx = f.ctx ?? ""
        // (A subscription box is small; a form with four or more inputs is not one, whatever sits near it.)
        // (Only the form's own button or words can rescue it: a footer's "Do Not Sell" link in the same block does not make a newsletter box an opt-out.)
        if fields.count <= 3 && has(signupContext, ctx) && !has(strongOptOut, heading + " " + buttons) { return -100 }
        // A form of one input (just an email) needs something that says it is a privacy request, not only a page that mentions privacy.
        // (A privacy-policy link beside a footer box does not count: only the button, the heading or a real opt-out phrase around it does.)
        if fields.count <= 1 && !has(optOut, buttons + " " + heading) && !has(strongOptOut, ctx) { return -100 }
        var s = 0
        if has(optOut, buttons) { s += 4 }
        if has(optOut, heading) { s += 2 }
        // A form for a deceased person (a suppression list for the dead) is never the opt-out of a living one.
        if has(deceasedForm, heading + " " + buttons + " " + pageContext.prefix(300)) { s -= 8 }
        if has(marketing, buttons) { s -= 6 }
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
