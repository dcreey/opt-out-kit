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
    static let selfIdentity = try! NSRegularExpression(pattern: "\\bi (confirm|verify|am|declare)\\b.{0,100}\\b(person|owner|me)\\b.{0,60}(email|e-mail|address|account|request|record|name|information)", options: .caseInsensitive)
    static let notSelfIdentity = try! NSRegularExpression(pattern: "penalty|perjury|agent|behalf|representative|authori[sz]ed to|attest|acknowledg|certif|terms|privacy policy|legal", options: .caseInsensitive)

    /// "I understand I may be required to verify my identity, and I authorize <the broker> to contact me": a note about the person's own
    /// request, not a term, a consent to marketing or a sale. Data Axle's family of sites uses it. Same owner-only rule.
    static let requestAcknowledgement = try! NSRegularExpression(pattern: "may be required to verify my identity.{0,200}authori[sz]e .{0,60} to contact me", options: .caseInsensitive)
    static let notAcknowledgement = try! NSRegularExpression(pattern: "terms|privacy policy|\\bsell|market|newsletter|advertis|share my|third part", options: .caseInsensitive)

    public static func isSelfIdentityBox(_ text: String) -> Bool {
        let r = NSRange(text.startIndex..., in: text)
        if requestAcknowledgement.firstMatch(in: text, range: r) != nil && notAcknowledgement.firstMatch(in: text, range: r) == nil { return true }
        return selfIdentity.firstMatch(in: text, range: r) != nil && notSelfIdentity.firstMatch(in: text, range: r) == nil
    }

    /// A text box that asks the person to type a code shown in a picture or sent to them ("Captcha", "Security code"). Only they can fill it.
    static func isTypedCode(_ field: FormField) -> Bool {
        guard field.type == "text" || field.type == "tel" || field.type == "number" else { return false }
        return (field.name + " " + field.label).range(of: "captcha|security.?code|verification.?code|enter the (code|text|characters)|type the (code|characters)", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Whether the form has one: the person types it, so the site is semi-automated and goes last in the queue.
    public static func hasTypedCode(_ form: OptOutForm) -> Bool { form.fields.contains(where: isTypedCode) }

    /// A field that wants the address of the person's own listing on the site ("Enter URL here", "Link to your listing").
    static func isListingField(_ field: FormField) -> Bool {
        let key = (field.name + " " + field.label).lowercased()
        return field.type != "email" && key.range(of: "\\burl\\b|listing|profile.?link|\\blink\\b", options: .regularExpression) != nil
    }

    /// Whether the form can only be completed with the address of the person's own listing on the site.
    public static func needsListing(_ form: OptOutForm) -> Bool { form.fields.contains(where: isListingField) }

    /// `listingURL` is the person's own listing, picked by them on the site; without it a form that needs one is left to the person.
    public static func plan(for form: OptOutForm, signals: [String]?, person: Person, listingURL: URL? = nil, advertisingID: String? = nil) -> FillPlan {
        if let hit = (signals ?? []).compactMap({ humanOnlySignals[$0] }).first {
            return FillPlan(values: [], verdict: .needsYou(L10n.f("This site %@.", hit)))
        }
        let legal = person.legalName
        let parts = legal.split(separator: " ").map(String.init)
        let first = parts.first, last = parts.count > 1 ? parts.last : nil
        let address = person.addresses.first
        var values: [FieldValue] = []
        var missing: [String] = []
        var needsYou: String?

        // A plain "nom" or "nombre" is the family name or the first name depending on which other fields the form has.
        let allKeys = form.fields.map { ($0.name + " " + $0.label).lowercased() }
        let hasPrenom = allKeys.contains { $0.range(of: "pr[ée]nom|first|vorname", options: .regularExpression) != nil }
        let hasApellido = allKeys.contains { $0.range(of: "apellido", options: .regularExpression) != nil }
        for field in form.fields {
            let key = (field.name + " " + field.label).lowercased()
            if isTypedCode(field) { continue }          // left empty: the person types it, and the runner waits for it
            let required = field.label.contains("*") || field.label.lowercased().contains("(required)")
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
                        needsYou = needsYou ?? L10n.f("This form asks the person to confirm \"I am this person\" (\"%@\"). The app only does that for the account owner, and only if they allowed it.", field.display)
                    } else {
                        needsYou = needsYou ?? L10n.f("This form asks you to confirm or certify something yourself (\"%@\").", field.display)
                    }
                }
                continue
            default: break
            }
            if key.contains("agent") || key.contains("on behalf") || key.contains("customer id") || key.contains("account number") {
                if required { needsYou = needsYou ?? L10n.f("This form asks for something only you can supply (\"%@\").", field.display) }
                continue
            }
            // Middle names and suffixes are optional and the profile does not hold them: leave them empty, never reuse another name.
            // (A field that asks for "First / Middle Name(s)" is the first name.)
            if key.range(of: "\\b(middle|mn|mi|suffix)\\b|middle.?name|middle.?initial", options: .regularExpression) != nil,
               key.range(of: "first|pr[ée]nom|vorname|given", options: .regularExpression) == nil { continue }
            // A link to the person's own listing has to come from them: the form cannot succeed without it.
            if isListingField(field) {
                if let listingURL { values.append(FieldValue(name: field.name, type: field.type, candidates: [listingURL.absoluteString], label: field.label)) }
                else { needsYou = needsYou ?? L10n.t("This form needs the link to your listing on the site, which you find there first.") }
                continue
            }
            // Field names and labels in English, French, Spanish and German.
            func has(_ pattern: String) -> Bool { key.range(of: pattern, options: .regularExpression) != nil }
            // The phone's advertising ID, for the sites that opt a device out by it. It is read on the phone only when a form asks.
            if has("\\bmaid\\b|\\bidfa\\b|\\baaid\\b|advertising.?(id|identifier)|mobile.?ad(vertising)?.?(id|identifier)|\\bad.?id\\b|device.?(id|identifier)") {
                if let advertisingID { put([advertisingID], L10n.noun("Advertising ID")) }
                else if required { needsYou = needsYou ?? L10n.t("This form asks for your phone's advertising ID, which needs your permission to read.") }
                continue
            }
            // A business contact form (company, job title, industry) is not a personal opt-out: only the person could answer it as a business.
            if has("company|organi[sz]ation|business (name|type)|job.?title|industry|department|company size|\\bemployees\\b|\\brole\\b") {
                if required { needsYou = needsYou ?? L10n.f("This form asks for business details (\"%@\"), so it is a business contact form and not a personal opt-out.", field.display) }
                continue
            }
            // Today's date, for forms that ask for it beside a signature or request.
            if has("today.?s date|current date|date of (request|submission)|\\bdate\\b") && !has("birth|dob|born") {
                let now = Date(); let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
                put(["yyyy-MM-dd", "MM/dd/yyyy", "MMMM d, yyyy"].map { f.dateFormat = $0; return f.string(from: now) }, L10n.noun("Date")); continue
            }
            // Age, or the parts of the birthdate, from the birthdate the person gave.
            if has("\\bage\\b") && !has("manage|message|usage|page|image|stage|average") {
                if let age = person.age() { put([String(age)], L10n.noun("Age")) } else if required { missing.append(L10n.noun("Birthdate")) }
                continue
            }
            if let b = person.birthdate, b.count == 10, has("birth|dob|born") || has("^(month|day|year)\\b|\\b(month|day|year)\\b") {
                let p = b.split(separator: "-").map(String.init)
                if p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) {
                    let months = ["January","February","March","April","May","June","July","August","September","October","November","December"]
                    if has("month") { put([String(m), String(format: "%02d", m), months[m - 1], String(months[m - 1].prefix(3))], L10n.noun("Birth month")); continue }
                    if has("\\bday\\b") { put([String(d), String(format: "%02d", d)], L10n.noun("Birth day")); continue }
                    if has("\\byear\\b") { put([String(y)], L10n.noun("Birth year")); continue }
                }
            }
            // A subject or message box: the same plain request every time, stating only what the person already sends.
            if field.label.lowercased().range(of: "^\\s*(subject|topic|regarding)\\b", options: .regularExpression) != nil { put(["Privacy opt-out and deletion request"], L10n.noun("Subject")); continue }
            if has("message|comments?|details|reason|description|how can we help|tell us|additional (info|information)|\\bnotes?\\b|your request|request type description") && (field.type == "textarea" || required) && !has("email|password|address") {
                put([FormFiller.standardRequest(for: person)], L10n.noun("Message")); continue
            }
            // A second address line (apartment, suite, unit) is left empty: the profile holds one street line, and repeating it is wrong.
            if has("address.?(line.?)?2|address2|line.?2|\\b(apt|apartment|suite|unit|floor)\\b|adresse.?2|c/o") { continue }
            if has("country|\\bpays\\b|pa[ií]s\\b") {
                if let a = address, USStates.code(for: a.state) != nil { put(["United States", "United States of America", "USA", "US"], L10n.noun("Country")) }
                continue
            }
            if field.type == "email" || has("e-?mail|courriel|correo") { put([person.emails.first], L10n.noun("Email address")) }
            else if has("first|fname|given|pr[ée]nom|vorname") || (has("\\bnombre\\b") && hasApellido) { put([first], L10n.noun("First name")) }
            else if has("last|lname|surname|family|nom de famille|apellido|nachname|familienname") || (has("\\bnom\\b") && hasPrenom) { put([last], L10n.noun("Last name")) }
            else if has("full|\\bname\\b|\\bnom\\b|\\bnombre\\b") { put([legal], L10n.noun("Full name")) }
            else if has("city|\\bville\\b|ciudad|\\bstadt\\b|\\bort\\b") { put([address?.city], L10n.noun("City")) }
            else if has("state|province|jurisdiction|resident|reside|residency|residence|\\bregion\\b|\\b[ée]tat\\b|\\bestado\\b|bundesland") {
                put([address?.state, address.flatMap { USStates.name(for: $0.state) }], L10n.noun("State"))
            }
            else if has("zip|postal|code postal|c[óo]digo postal|\\bplz\\b") { put([address?.zip], L10n.noun("Zip code")) }
            else if has("phone|t[ée]l[ée]phone|tel[ée]fono|telefon|handy") || field.type == "tel" { put([person.phones.first], L10n.noun("Phone number")) }
            else if has("birth|dob|naissance|nacimiento|geburt") { put([person.birthdate], L10n.noun("Birthdate")) }
            else if has("address|street|adresse|direcci[óo]n|stra[ßs]e|\\bcalle\\b|\\brue\\b") { put([address?.street], L10n.noun("Street address")) }
            // A required menu of request choices ("Privacy Choice", "Choose an option") is chosen on the live page, from its own options.
            else if required, field.type != "select" { needsYou = needsYou ?? L10n.f("This form asks for something we do not have (\"%@\").", field.display) }
        }
        if let needsYou { return FillPlan(values: values, verdict: .needsYou(needsYou)) }
        if !missing.isEmpty { return FillPlan(values: values, verdict: .needsData(Array(Set(missing)).sorted())) }
        if values.isEmpty { return FillPlan(values: [], verdict: .needsYou(L10n.t("We could not match any of this form's fields to your profile."))) }
        // The account owner allowed "I am this person" boxes to be ticked for them. The page is checked live for such a box;
        // anything else that certifies, attests or accepts terms is left alone. Never added for anyone else's profile.
        if person.mayConfirmOwnIdentity() { values.append(FieldValue(name: "", type: confirmIdentityType, candidates: ["on"], label: "")) }
        return FillPlan(values: values, verdict: .ready)
    }

    /// The request text for a free-text box: plain, the same for everyone, and only what the form already receives.
    public static func standardRequest(for person: Person) -> String {
        let state = person.addresses.first.flatMap { USStates.name(for: $0.state) } ?? ""
        let where_ = state.isEmpty ? "" : " and a resident of \(state)"
        return "I am an individual\(where_). Please stop selling or sharing my personal information, delete the personal information you hold about me, and keep me on your suppression list so it is not collected again. Please confirm by email."
    }

    /// A marker value (not a real field) that tells the web view to tick plain "I am this person" boxes.
    public static let confirmIdentityType = "confirm-identity"
}
