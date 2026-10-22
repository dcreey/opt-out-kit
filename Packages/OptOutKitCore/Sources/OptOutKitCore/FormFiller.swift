import Foundation

/// One value to put into one field of a site's opt-out form.
public struct FieldValue: Equatable, Sendable {
    public var name: String
    public var type: String
    /// For text fields, one value. For a dropdown, candidates to match against its options, best first ("IL", "Illinois").
    public var candidates: [String]
    public var label: String

    public init(name: String, type: String, candidates: [String], label: String) {
        self.name = name; self.type = type; self.candidates = candidates; self.label = label
    }
}

/// What the app can do with a form for one person: the values to enter, and why it cannot go further when it cannot.
public struct FillPlan: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        case ready
        case needsData([String])      // details the person has not added yet (email, city, ...)
        case needsYou(String)         // something only a person can do: a login, ID, a phone call, a legal attestation
    }
    public var values: [FieldValue]
    public var verdict: Verdict

    public init(values: [FieldValue], verdict: Verdict) { self.values = values; self.verdict = verdict }
}

public enum FormFiller {
    /// Tags from the profiler that mean a person must act. A bot check is NOT here: it is detected when the page is
    /// actually loaded, because many are invisible and pass for a real browser, and a visible one stops the run then.
    static let humanOnlySignals: [String: String] = [
        "login_required": "needs an account login",
        "id_required": "may ask for ID",
        "phone_verify": "may verify by phone",
        "file_upload": "asks for a file upload",
        "account_hint": "needs an account",
    ]
    static let attestation = try! NSRegularExpression(pattern: "acknowledg|certif|attest|i agree|i accept|consent|under penalty|terms|authori[sz]e|i am the|on behalf", options: .caseInsensitive)

    /// A plain statement that the person filling the form is the subject of it ("I confirm that I am the person associated with this
    /// email"). Not a legal certification, an agent statement or an acceptance of terms.
    static let selfIdentity = try! NSRegularExpression(pattern: "\\bi (confirm|verify|am)\\b.{0,60}\\b(person|owner|me)\\b.{0,40}(email|e-mail|address|account|request|record)", options: .caseInsensitive)
    static let notSelfIdentity = try! NSRegularExpression(pattern: "penalty|perjury|agent|behalf|representative|authori[sz]ed to|attest|acknowledg|certif|terms|privacy policy|legal", options: .caseInsensitive)

    public static func isSelfIdentityBox(_ text: String) -> Bool {
        let r = NSRange(text.startIndex..., in: text)
        return selfIdentity.firstMatch(in: text, range: r) != nil && notSelfIdentity.firstMatch(in: text, range: r) == nil
    }

    /// A field that wants the address of the person's own listing on the site ("Enter URL here", "Link to your listing").
    static func isListingField(_ field: FormField) -> Bool {
        let key = (field.name + " " + field.label).lowercased()
        return field.type != "email" && key.range(of: "\\burl\\b|listing|profile.?link|\\blink\\b", options: .regularExpression) != nil
    }

    /// Whether the form can only be completed with the address of the person's own listing on the site.
    public static func needsListing(_ form: OptOutForm) -> Bool { form.fields.contains(where: isListingField) }

    /// `listingURL` is the person's own listing, picked by them on the site; without it a form that needs one is left to the person.
    public static func plan(for form: OptOutForm, signals: [String]?, person: Person, listingURL: URL? = nil) -> FillPlan {
        if let hit = (signals ?? []).compactMap({ humanOnlySignals[$0] }).first {
            return FillPlan(values: [], verdict: .needsYou("This site \(hit)."))
        }
        let legal = person.legalName
        let parts = legal.split(separator: " ").map(String.init)
        let first = parts.first, last = parts.count > 1 ? parts.last : nil
        let address = person.addresses.first
        var values: [FieldValue] = []
        var missing: [String] = []
        var needsYou: String?

        for field in form.fields {
            let key = (field.name + " " + field.label).lowercased()
            let required = field.label.contains("*")
            func put(_ candidates: [String?], _ what: String) {
                let c = candidates.compactMap { $0 }.filter { !$0.isEmpty }
                if c.isEmpty { if required || field.type == "email" { missing.append(what) } }
                else { values.append(FieldValue(name: field.name, type: field.type, candidates: c, label: field.label)) }
            }
            switch field.type {
            case "hidden", "submit", "button", "image", "reset", "password": continue
            case "checkbox", "radio":
                if attestation.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil, required || key.contains("acknowledg") || key.contains("certif") || isSelfIdentityBox(key) {
                    if isSelfIdentityBox(key), person.mayConfirmOwnIdentity() {
                        // The owner allowed this one plain statement about themselves; the sentinel below ticks it on the live page.
                    } else if isSelfIdentityBox(key) {
                        needsYou = needsYou ?? "This form asks the person to confirm \"I am this person\" (\"\(field.display)\"). The app only does that for the account owner, and only if they allowed it."
                    } else {
                        needsYou = needsYou ?? "This form asks you to confirm or certify something yourself (\"\(field.display)\")."
                    }
                }
                continue
            default: break
            }
            if key.contains("agent") || key.contains("on behalf") || key.contains("customer id") || key.contains("account number") {
                if required { needsYou = needsYou ?? "This form asks for something only you can supply (\"\(field.display)\")." }
                continue
            }
            // Middle names and suffixes are optional and the profile does not hold them: leave them empty, never reuse another name.
            if key.range(of: "\\b(middle|mn|mi|suffix)\\b|middle.?name|middle.?initial", options: .regularExpression) != nil { continue }
            // A link to the person's own listing has to come from them: the form cannot succeed without it.
            if isListingField(field) {
                if let listingURL { values.append(FieldValue(name: field.name, type: field.type, candidates: [listingURL.absoluteString], label: field.label)) }
                else { needsYou = needsYou ?? "This form needs the link to your listing on the site, which you find there first." }
                continue
            }
            if field.type == "email" || key.contains("e-mail") || key.contains("email") { put([person.emails.first], "email address") }
            else if key.contains("first") || key.contains("fname") || key.contains("given") { put([first], "first name") }
            else if key.contains("last") || key.contains("lname") || key.contains("surname") || key.contains("family") { put([last], "last name") }
            else if key.contains("full") || key.range(of: "\\bname\\b", options: .regularExpression) != nil { put([legal], "full name") }
            else if key.contains("city") { put([address?.city], "city") }
            else if key.contains("state") || key.contains("province") {
                put([address?.state, address.flatMap { USStates.name(for: $0.state) }], "state")
            }
            else if key.contains("zip") || key.contains("postal") { put([], "zip code") }
            else if key.contains("phone") || field.type == "tel" { put([person.phones.first], "phone number") }
            else if key.contains("birth") || key.contains("dob") { put([person.birthdate], "birthdate") }
            else if key.contains("address") || key.contains("street") { put([address?.street], "street address") }
            else if required { needsYou = needsYou ?? "This form asks for something we do not have (\"\(field.display)\")." }
        }
        if let needsYou { return FillPlan(values: values, verdict: .needsYou(needsYou)) }
        if !missing.isEmpty { return FillPlan(values: values, verdict: .needsData(Array(Set(missing)).sorted())) }
        if values.isEmpty { return FillPlan(values: [], verdict: .needsYou("We could not match any of this form's fields to your profile.")) }
        // The account owner allowed "I am this person" boxes to be ticked for them. The page is checked live for such a box;
        // anything else that certifies, attests or accepts terms is left alone. Never added for anyone else's profile.
        if person.mayConfirmOwnIdentity() { values.append(FieldValue(name: "", type: confirmIdentityType, candidates: ["on"], label: "")) }
        return FillPlan(values: values, verdict: .ready)
    }

    /// A marker value (not a real field) that tells the web view to tick plain "I am this person" boxes.
    public static let confirmIdentityType = "confirm-identity"
}
