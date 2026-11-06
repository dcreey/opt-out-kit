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
        // The person's own listing: a text or address box that says so. A "link" mentioned in a help sentence, a LinkedIn address or a cookie ID is not it.
        guard field.type == "text" || field.type == "url" || field.type == "textarea" else { return false }
        if key.range(of: "linkedin|cookie|facebook|twitter|instagram|website|company|domain", options: .regularExpression) != nil { return false }
        return key.range(of: "(your|my|own|the)[^a-z]{0,3}(listing|profile)|(listing|profile)[^a-z]{0,3}(url|link|address)|link to (your|my|the)|url of (your|my)|\\bpaste (the |your )?(url|link)|\\benter url\\b", options: .regularExpression) != nil
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
            // A hint in brackets tells the person what to do, not what the box is: "State (select country first)" is the state, not the country or a first name.
            let hint = "\\s*\\(((select|choose|pick|enter|type|please)|[^)]*(country code|area code|including|include|e\\.g|example|format|dashes|digits))[^)]*\\)"
            let key = (field.name + " " + field.label).replacingOccurrences(of: hint, with: "", options: [.regularExpression, .caseInsensitive]).lowercased()
            if isTypedCode(field) { continue }          // left empty: the person types it, and the runner waits for it
            // A live form carries the page's own label first, then " | " and the field's code name; rules about what the box says use the label alone.
            let visibleLabel = (field.label.components(separatedBy: " | ").first ?? field.label).replacingOccurrences(of: hint, with: "", options: [.regularExpression, .caseInsensitive])
            // A label can say "(Not required but strongly recommended)" next to a required attribute: the page's own words win.
            let optionalWords = field.label.range(of: "not required|\\(optional\\)|optional\\)", options: [.regularExpression, .caseInsensitive]) != nil
            let required = !optionalWords && (field.label.contains("*") || field.label.lowercased().contains("(required)"))
            func has(_ pattern: String) -> Bool { key.range(of: pattern, options: .regularExpression) != nil }
            // The visible label beats the code name: a box labelled "Phone" whose name is `form_fields[email]` is the phone number, not the email.
            let labelOnly = visibleLabel.lowercased()
            let phoneWords = "phone|mobile|\\bcell(ular)?\\b|whatsapp|t[ée]l[ée]phone|tel[ée]fono|telefon|handy"
            let labelPhone = labelOnly.range(of: phoneWords, options: .regularExpression) != nil && labelOnly.range(of: "e-?mail|courriel|correo", options: .regularExpression) == nil
            let labelEmail = labelOnly.range(of: "e-?mail|courriel|correo", options: .regularExpression) != nil && labelOnly.range(of: phoneWords, options: .regularExpression) == nil
            // A previous or former address is the second one in the profile (the first is the current one), never the current one again.
            let previous = has("\\b(previous|prior|former|old|past)\\b.{0,15}(address|street|city|state|zip|postal)|(address|street|city).{0,12}\\b(previous|prior|former)\\b")
            let address = previous ? person.addresses.dropFirst().first : person.addresses.first
            func put(_ candidates: [String?], _ what: String) {
                let c = candidates.compactMap { $0 }.filter { !$0.isEmpty }
                if c.isEmpty { if required || field.type == "email" { missing.append(what) } }
                else { values.append(FieldValue(name: field.name, type: field.type, candidates: c, label: field.label)) }
            }
            switch field.type {
            case "hidden", "submit", "button", "image", "reset", "password", "range", "color", "time", "week": continue
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
            // Numbers and identifiers only the person holds (SSN, last four digits, licence, passport, order or account numbers): never guessed, never another field's value.
            if has("\\bssn\\b|social.?security|last.?(4|four)\\b|licen[sc]e|passport|\\bstate.?id\\b|national.?id|\\btax.?id\\b|\\bitin\\b|\\bid.?(number|no\\b|#)|identification.?number|member.?(id|number)|order.?(number|id|no\\b)|reference.?(number|id)|case.?(number|id)|account.?(id|number|no\\b)|claim.?number|policy.?number") {
                if required { needsYou = needsYou ?? L10n.f("This form asks for something only you can supply (\"%@\").", field.display) }
                continue
            }
            // Someone else's name or a detail the profile does not hold (maiden or parent's name, a nickname, a social profile, gender, birthplace): left empty, never the person's own name.
            if has("maiden|mother|father|\\bparent|guardian|spouse|emergency|\\balias|nickname|also known|other names?|previous names?|former names?|prior names?|\\bwitness|referr|facebook|twitter|instagram|linkedin|tiktok|snapchat|(twitter|instagram|social|user|account).{0,8}\\bhandle\\b|username|user name|screen.?name|social media|gender|\\bsex\\b|\\brace\\b|ethnic|marital|employer|occupation|salary|income|birth.?(place|city|state|country|town)|place of birth|country of birth|born in") {
                if required { needsYou = needsYou ?? L10n.f("This form asks for something we do not have (\"%@\").", field.display) }
                continue
            }
            // A second email, "if different": optional, so left empty (a required one is the person's own address).
            if !required, labelOnly.range(of: "alternat|secondary|backup|second e-?mail|other e-?mail|if different", options: .regularExpression) != nil,
               labelOnly.range(of: "confirm|re-?enter|repeat|verify|retype", options: .regularExpression) == nil { continue }
            if key.contains("agent") || key.contains("on behalf") || key.contains("customer id") || key.contains("account number") {
                if required { needsYou = needsYou ?? L10n.f("This form asks for something only you can supply (\"%@\").", field.display) }
                continue
            }
            // Middle names and suffixes are optional and the profile does not hold them: leave them empty, never reuse another name.
            // (A field that asks for "First / Middle Name(s)" is the first name.)
            if key.range(of: "\\b(middle|mn|mi|suffix)\\b|middle.?name|middle.?initial", options: .regularExpression) != nil,
               key.range(of: "first|pr[ée]nom|vorname|given", options: .regularExpression) == nil { continue }
            // A box about the device's IP address ("Opt-Out my current IP address, https://whatismyipaddress.com") is not a street address: it is left empty.
            if key.range(of: "(^|[^a-z])ip.?address|whatismyip|\\bip\\b", options: .regularExpression) != nil { continue }
            // A link to the person's own listing has to come from them: the form cannot succeed without it.
            if isListingField(field) {
                if let listingURL { values.append(FieldValue(name: field.name, type: field.type, candidates: [listingURL.absoluteString], label: field.label)) }
                else { needsYou = needsYou ?? L10n.t("This form needs the link to your listing on the site, which you find there first.") }
                continue
            }
            // Field names and labels in English, French, Spanish and German.
            // The phone's advertising ID, for the sites that opt a device out by it. It is read on the phone only when a form asks.
            if has("\\bmaid\\b|\\bidfa\\b|\\baaid\\b|advertising.?(id|identifier)|mobile.?ad(vertising)?.?(id|identifier)|\\bad.?id\\b|device.?(id|identifier)") {
                if let advertisingID { put([advertisingID], L10n.noun("Advertising ID")) }
                else if required { needsYou = needsYou ?? L10n.t("This form asks for your phone's advertising ID, which needs your permission to read.") }
                continue
            }
            // "Business relationship information (if applicable)": the business's own address, email and phone are not the person's. Left empty, never required.
            if has("\\bbusiness\\b.{0,20}(street|address|e-?mail|phone|telephone|city|state|zip|postal|contact|fax)") { continue }
            // A business contact form (company, job title, industry) is not a personal opt-out: only the person could answer it as a business.
            if has("company|organi[sz]ation|business (name|type)|job.?title|industry|department|company size|\\bemployees\\b|\\brole\\b") {
                // "Last Name or Business Name": a business name is never filled, and a person's last name is left for them to type rather than stopping the form.
                if required, !has("(first|last|sur|family|given).?name") { needsYou = needsYou ?? L10n.f("This form asks for business details (\"%@\"), so it is a business contact form and not a personal opt-out.", field.display) }
                continue
            }
            // Today's date, for forms that ask for it beside a signature or request. Any other date ("date you were contacted", "effective date") is the person's to give.
            if has("today.?s date|current date|date of (request|submission)|\\bdate\\b|\\btoday\\b") && !has("birth|dob|born") {
                let isToday = has("today|current date|date of (request|submission)|(request|submission|signature|signing|signed|submitted).{0,8}date|date.{0,16}(signed|submitted|request)")
                    || visibleLabel.lowercased().range(of: "^\\s*\\*?\\s*date\\s*(\\*|:|\\(required\\))?\\s*$", options: .regularExpression) != nil
                if !isToday {
                    if required { needsYou = needsYou ?? L10n.f("This form asks for something we do not have (\"%@\").", field.display) }
                    continue
                }
                let now = Date(); let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
                // A month or date-and-time picker takes only its own shape; a text box gets the shapes in turn.
                let shapes = field.type == "month" ? ["yyyy-MM"] : field.type == "datetime-local" ? ["yyyy-MM-dd'T'HH:mm"] : ["yyyy-MM-dd", "MM/dd/yyyy", "MMMM d, yyyy"]
                put(shapes.map { f.dateFormat = $0; return f.string(from: now) }, L10n.noun("Date")); continue
            }
            // A month picker (type=month) takes "yyyy-MM" only: the birth month, else left empty.
            if field.type == "month" {
                if has("birth|dob|born"), let b = person.birthdate, b.count == 10 { put([String(b.prefix(7))], L10n.noun("Birth month")) }
                continue
            }
            // One box for the whole address ("Street Address, City, State, Zip").
            if has("street.{0,12}city.{0,12}state") {
                if let a = address, let street = a.street { put(["\(street), \(a.city), \(a.state) \(a.zip ?? "")".trimmingCharacters(in: .whitespaces)], L10n.noun("Street address")) }
                else if required { missing.append(L10n.noun("Street address")) }
                continue
            }
            // "Data subject's relationship with <the company>": a person only asking to be removed has none.
            if has("relationship (with|to)|relation to|data subject.?s relationship") {
                put(["Consumer, no business relationship", "Consumer", "No relationship", "None", "Individual", "Other", "Not applicable", "N/A"], L10n.noun("Relationship")); continue
            }
            // A typed signature or e-signature: the person's legal name, typed. (A drawn signature or an uploaded file stays with the person.)
            if has("e-?sign|signature|sign here|typed name|type your (full )?name") && field.type != "file" && field.type != "canvas" {
                put([legal], L10n.noun("Signature")); continue
            }
            // Age, or the parts of the birthdate, from the birthdate the person gave.
            // An age range or group is a menu of brackets: the age goes in as a number and the page's own bracket that holds it is picked.
            if has("\\bage\\b.{0,10}(range|group|bracket)|age.?(range|group|bracket)") {
                if field.type == "select", let age = person.age() { put([String(age)], L10n.noun("Age")) }
                continue
            }
            if has("\\bage\\b") && !has("manage|message|usage|page|image|stage|average") {
                if let age = person.age() { put([String(age)], L10n.noun("Age")) } else if required { missing.append(L10n.noun("Birthdate")) }
                continue
            }
            if let b = person.birthdate, b.count == 10, (has("birth|dob|born") && !has("street|address")) || has("^(month|day|year)\\b|\\b(month|day|year)\\b") {
                let p = b.split(separator: "-").map(String.init)
                if p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) {
                    let months = ["January","February","March","April","May","June","July","August","September","October","November","December"]
                    if has("month") { put([String(m), String(format: "%02d", m), months[m - 1], String(months[m - 1].prefix(3))], L10n.noun("Birth month")); continue }
                    if has("\\bday\\b") { put([String(d), String(format: "%02d", d)], L10n.noun("Birth day")); continue }
                    if has("\\byear\\b") { put([String(y)], L10n.noun("Birth year")); continue }
                }
            }
            // A subject or message box: the same plain request every time, stating only what the person already sends.
            if visibleLabel.lowercased().range(of: "^\\s*(subject|topic|regarding)\\s*(\\*|:|\\(required\\))?\\s*$", options: .regularExpression) != nil { put(["Privacy opt-out and deletion request"], L10n.noun("Subject")); continue }
            // A menu asked for a subject or topic picks the option that names a privacy request; the long request sentence goes only in a text box.
            // (A menu named "subject_state" is the state, not the topic: the field's code name is not enough.)
            if field.type == "select", has("subject|topic|regarding|reason for|type of (request|inquiry)|inquiry type|how can we help"), !has("state|province|country|month|\\bday\\b|\\byear\\b|birth|dob|city|zip|postal") {
                put(["Privacy opt-out and deletion request", "Privacy request", "Opt out", "Opt-out", "Do not sell", "Delete", "Privacy", "Other"], L10n.noun("Subject")); continue
            }
            if field.type == "select", has("message|comments?|details|description|tell us|your request") { continue }
            // "Please cite the law that gives you this right": the plain statement of the privacy laws that do. (The box about a threat of physical harm is never filled.)
            if (field.type == "textarea" || field.type == "text"), has("legal.?info|legal basis|basis for (your |the )?request|applicable law|cite .{0,30}law|which law|law that (affords|gives|protects)"), !has("threat|harm|danger") {
                put([FormFiller.legalBasis(for: person)], L10n.noun("Legal basis")); continue
            }
            if has("message|comments?|details|reason|description|how can we help|tell us|additional (info|information)|\\bnotes?\\b|your request|request type description") && (field.type == "textarea" || required) && !has("email|password|address") {
                put([FormFiller.standardRequest(for: person), shortRequest], L10n.noun("Message")); continue
            }
            // A second address line (apartment, suite, unit) is left empty: the profile holds one street line, and repeating it is wrong.
            // (A form that insists on it gets "N/A": an empty required box stops the form from sending.)
            if has("address.?(line.?)?(2|two)|address2|line.?(2|two)|street.?(address.?)?(line.?)?2\\b|second.?(line|address)|\\b(apt|apartment|suite|unit|floor)\\b|adresse.?2|c/o") { if required { put(["N/A"], L10n.noun("Address line 2")) }; continue }
            if has("country|\\bpays\\b|pa[ií]s\\b"), !(labelPhone && field.type != "select") {
                if let code = person.countryCode {
                    if code == "US" { put(["United States", "United States of America", "USA", "US"], L10n.noun("Country")) }
                    else { put([Regions.englishName(code), code, code == "GB" ? "UK" : nil, code == "GB" ? "United Kingdom of Great Britain and Northern Ireland" : nil], L10n.noun("Country")) }
                }
                continue
            }
            // The visible label wins over a field's code name: a postal-code box named "Region-State-Province-2" is still the postal code.
            if labelOnly.range(of: "\\b(zip|postal)\\b|code postal|c[óo]digo postal|\\bplz\\b", options: .regularExpression) != nil, labelOnly.range(of: "state|province|region|country", options: .regularExpression) == nil {
                put([address?.zip], L10n.noun("Zip code")); continue
            }
            // A menu beside a phone box is its country-code list ("United States +1"), not the number.
            if field.type == "select", has("phone|mobile|tel\\b|ph.?ext|t[ée]l[ée]phone") {
                put(person.countryCode == "US" || person.countryCode == nil ? ["United States", "United States (+1)", "+1", "US", "USA"] : [Regions.englishName(person.countryCode ?? "")], L10n.noun("Country code")); continue
            }
            // One box for the whole address ("Full Address", "Complete address"): "full" there is not the full name.
            if has("(full|complete|entire|whole).{0,6}address|address.{0,6}(in full|complete)") && !labelEmail && field.type != "email" {
                if let a = address, let street = a.street { put(["\(street), \(a.city), \(a.state) \(a.zip ?? "")".trimmingCharacters(in: .whitespaces), street], L10n.noun("Street address")) }
                else if required { missing.append(L10n.noun("Street address")) }
                continue
            }
            // A street split in two boxes: the number ("House number") and the name ("Street name"). "Street name" is not the person's name.
            if has("(house|street|building).?(no\\b|number|num\\b|#)|street.?number|\\bhouse\\b|street.?name") {
                let parts = (address?.street ?? "").trimmingCharacters(in: .whitespaces)
                let m = parts.range(of: "^\\d+[A-Za-z]?(-\\d+)?\\s+", options: .regularExpression)
                let isName = has("street.?name") && !has("number|\\bno\\b")
                if isName { put([m.map { String(parts[$0.upperBound...]) } ?? parts], L10n.noun("Street name")) }
                else { put([m.map { String(parts[..<$0.upperBound]).trimmingCharacters(in: .whitespaces) }], L10n.noun("House number")) }
                continue
            }
            // A name box that asks for first and last together ("first and last name") is the full name, not just the first.
            if has("(first|given).{0,12}(and|&|/|\\+|,).{0,12}(last|sur|family)|(last|sur|family).{0,12}(and|&|/|\\+|,).{0,12}(first|given)"), !has("middle") { put([legal], L10n.noun("Full name")); continue }
            if labelPhone && field.type != "email" { put([person.phones.first], L10n.noun("Phone number")) }
            else if field.type == "email" || labelEmail || has("e-?mail|courriel|correo") { put([person.emails.first], L10n.noun("Email address")) }
            else if has("first|fname|given|pr[ée]nom|vorname") || (has("\\bnombre\\b") && hasApellido) { put([first], L10n.noun("First name")) }
            else if has("last|lname|surname|family|nom de famille|apellido|nachname|familienname") || (has("\\bnom\\b") && hasPrenom) { put([last], L10n.noun("Last name")) }
            else if has("full|\\bname\\b|\\bnom\\b|\\bnombre\\b") { put([legal], L10n.noun("Full name")) }
            else if has("city|\\bville\\b|ciudad|\\bstadt\\b|\\bort\\b") { put([address?.city], L10n.noun("City")) }
            else if has("state|province|jurisdiction|resident|reside|residency|residence|\\bregion\\b|\\b[ée]tat\\b|\\bestado\\b|bundesland") {
                put([address?.state, address.flatMap { USStates.name(for: $0.state) }], L10n.noun("State"))
            }
            else if has("zip|postal|code postal|c[óo]digo postal|\\bplz\\b") { put([address?.zip], L10n.noun("Zip code")) }
            else if has(phoneWords) || field.type == "tel" { put([person.phones.first], L10n.noun("Phone number")) }
            else if has("birth|dob|naissance|nacimiento|geburt") && !has("street|address") { put([person.birthdate], L10n.noun("Birthdate")) }
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
    /// What a box that asks "which law gives you this right" gets: the plain statement that privacy laws give the right to opt out and to delete. Always more than
    /// 50 characters (some forms insist on that), and it claims nothing about the person beyond living where the law applies.
    public static func legalBasis(for person: Person) -> String {
        let country = person.countryCode ?? "US"
        if country != "US" {
            return "I am afforded the right to opt out of the sale and sharing of my personal information, and to have it deleted, under \(Regions.law(forCountry: country)) and the GDPR where it applies to me."
        }
        return "I am afforded the right to opt out of the sale and sharing of my personal information, and to have it deleted, under the California Consumer Privacy Act (CCPA), the GDPR where it applies to me, and similar state privacy laws."
    }

    /// The request in one short sentence, for a box with a small character limit.
    public static let shortRequest = "Please delete my personal information and stop selling or sharing it."

    public static func standardRequest(for person: Person) -> String {
        let country = person.countryCode ?? "US"
        if country != "US" {
            let place = Regions.englishName(country).map { " resident of \($0)" } ?? ""
            return "I am an individual\(place). Under \(Regions.law(forCountry: country)), please stop using my personal information for marketing, profiling and sale, delete the personal information you hold about me, and keep me on your suppression list so it is not collected again. Please confirm by email."
        }
        let state = person.addresses.first.flatMap { USStates.name(for: $0.state) } ?? ""
        let where_ = state.isEmpty ? "" : " and a resident of \(state)"
        return "I am an individual\(where_). Please stop selling or sharing my personal information, delete the personal information you hold about me, and keep me on your suppression list so it is not collected again. Please confirm by email."
    }

    /// A marker value (not a real field) that tells the web view to tick plain "I am this person" boxes.
    public static let confirmIdentityType = "confirm-identity"
}
