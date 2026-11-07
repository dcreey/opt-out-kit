import Foundation

/// One opt-out email: the addresses it goes to (all in Bcc, so no broker sees another) and every site it covers.
public struct EmailBatch: Identifiable, Equatable, Sendable {
    public var address: String           // the first address, or the only one
    public var addresses: [String]       // every distinct address, in order
    public var domains: [String]
    public var entryIDs: [String]
    public var id: String { addresses.joined(separator: ",") }

    /// Gmail accepts at most 500 recipients in one message, and long Bcc lists look like spam, so a very large list is split.
    public static let maxRecipients = 400

    /// One message for everything, or as few as the recipient limit allows.
    public static func single(entries: [DirectoryEntry], maxRecipients: Int = EmailBatch.maxRecipients) -> [EmailBatch] {
        let perAddress = build(entries: entries)
        var out: [EmailBatch] = [], cur: EmailBatch?
        for b in perAddress {
            if var c = cur, c.addresses.count < maxRecipients {
                c.addresses.append(b.address); c.domains += b.domains; c.entryIDs += b.entryIDs; cur = c
            } else {
                if let c = cur { out.append(c) }
                cur = EmailBatch(address: b.address, addresses: [b.address], domains: b.domains, entryIDs: b.entryIDs)
            }
        }
        if let c = cur { out.append(c) }
        return out
    }

    public static func build(entries: [DirectoryEntry]) -> [EmailBatch] {
        var order: [String] = [], map: [String: EmailBatch] = [:]
        for e in entries {
            guard let a = e.contactEmail?.lowercased() else { continue }
            if map[a] == nil { map[a] = EmailBatch(address: a, addresses: [a], domains: [], entryIDs: []); order.append(a) }
            map[a]!.domains.append(e.domain); map[a]!.entryIDs.append(e.id)
        }
        return order.map { map[$0]! }
    }

    public var subject: String { "Opt-out and deletion request" }

    /// The message, always in English and the same for every company: who is asking and what they ask for, with the details a company needs
    /// to find the record. It does not name the company or its sites, so it can go to any of them.
    public func body(name: String, email: String, address street: String, country: String? = nil) -> String { Self.genericBody(name: name, email: email, address: street, country: country) }

    /// The same message for a whole person: every name, email and past address goes in, so a company holding any of them can find the record.
    public func body(for who: EmailIdentity, details: EmailDetails? = nil, advertisingID: String? = nil) -> String {
        guard let details else { return Self.genericBody(name: who.name, email: who.email, address: who.address, country: who.country, identity: who) }
        return body(name: who.name, email: who.email, details: details, address: who.address, phone: who.phones.first, birthdate: who.birthdate, advertisingID: advertisingID, country: who.country, identity: who)
    }

    public static func genericBody(name: String, email: String, address street: String, country: String? = nil, identity: EmailIdentity? = nil) -> String {
        let law = (country ?? "US").uppercased() == "US" ? "the privacy laws that apply to me (including the CCPA/CPRA and other state privacy laws, and the GDPR where it applies)" : Regions.law(forCountry: country)
        var lines: [String] = ["To the privacy team,", "", "I am a consumer asking you to act on my personal information under \(law).", ""]
        lines.append("1. Opt me out of the sale and sharing of my personal information, and of targeted advertising and profiling.")
        lines.append("2. Delete the personal information you hold about me, and tell any service providers and third parties you have shared it with to do the same.")
        lines.append("3. Stop collecting, selling or sharing my personal information in future.")
        lines += ["", "Details to find my records:", "Name: \(name)", "Email: \(email)", "Address: \(street)"]
        lines += identity?.historyLines(details: nil) ?? []
        lines += ["", "If you need anything else to verify this request, reply to this email. Please confirm when it is done.", "", "Thank you.", name]
        return lines.joined(separator: "\n")
    }
}


/// Which of a person's details one company's opt-out email should carry: only what it needs to find the record.
public struct EmailDetails: Equatable, Sendable {
    public var address = false
    public var phone = false
    public var birthdate = false
    public var advertisingID = false
    public init(address: Bool = false, phone: Bool = false, birthdate: Bool = false, advertisingID: Bool = false) {
        self.address = address; self.phone = phone; self.birthdate = birthdate; self.advertisingID = advertisingID
    }

    /// Name and email always go. The rest comes from the company's own form when we read one; otherwise from what kind of company it is.
    public static func needs(for entry: DirectoryEntry) -> EmailDetails {
        if let fields = entry.optOutForm?.fields, !fields.isEmpty {
            func asks(_ pattern: String) -> Bool { fields.contains { ($0.name + " " + $0.label).range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil } }
            return EmailDetails(address: asks("street|address|city|zip|postal|\\bstate\\b"),
                                phone: asks("phone|mobile number|telephone"),
                                birthdate: asks("birth|\\bdob\\b"),
                                advertisingID: asks("\\bmaid\\b|\\bidfa\\b|\\baaid\\b|advertising.?(id|identifier)|mobile.?ad(vertising)?.?(id|identifier)|\\bad.?id\\b|device.?(id|identifier)"))
        }
        switch entry.about?.category ?? "" {
        case "adtech", "location_data": return EmailDetails(advertisingID: true)                  // matched by the phone's ad ID and email, not a postal address
        default: return EmailDetails(address: true)                                              // people search, marketing lists, records and the rest find a person by name and address
        }
    }
}

extension EmailBatch {
    /// The message for one company: the same request, with only the details that company needs. Anything not given is left out.
    public func body(name: String, email: String, details: EmailDetails, address street: String, phone: String? = nil, birthdate: String? = nil, advertisingID: String? = nil, country: String? = nil, identity: EmailIdentity? = nil) -> String {
        let generic = Self.genericBody(name: name, email: email, address: street, country: country).components(separatedBy: "\n")
        var lines = generic.filter { !$0.hasPrefix("Address: ") }
        guard let at = lines.firstIndex(of: "Email: \(email)") else { return generic.joined(separator: "\n") }
        var extra: [String] = []
        if details.address, !street.isEmpty { extra.append("Address: \(street)") }
        if details.phone, let phone, !phone.isEmpty { extra.append("Phone: \(phone)") }
        if details.birthdate, let birthdate, !birthdate.isEmpty { extra.append("Date of birth: \(birthdate)") }
        if details.advertisingID, let advertisingID, !advertisingID.isEmpty { extra.append("Mobile advertising ID (IDFA): \(advertisingID)") }
        extra += identity?.historyLines(details: details) ?? []
        lines.insert(contentsOf: extra, at: at + 1)
        return lines.joined(separator: "\n")
    }
}


/// Everything about one person that an opt-out email may carry: the current details first, then the history (other names, emails, phones and
/// previous addresses), because a company may hold the record under any of them. Built from the profile; nothing here is stored separately.
public struct EmailIdentity: Equatable, Sendable {
    public var name: String
    public var otherNames: [String]
    public var email: String                 // the address the request is sent from
    public var otherEmails: [String]
    public var phones: [String]
    public var address: String               // the current address on one line
    public var previousAddresses: [String]
    public var birthdate: String?
    public var country: String?

    public init(person: Person, formEmail: String?) {
        name = person.legalName
        var seenNames: Set<String> = [person.legalName.lowercased()]
        otherNames = person.names.map(\.name).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seenNames.insert($0.lowercased()).inserted }
        email = formEmail ?? ""
        var seen: Set<String> = [(formEmail ?? "").lowercased()]
        otherEmails = person.emails.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        phones = person.phones.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        address = person.currentAddress.map { FormFiller.oneLine($0, years: false) } ?? ""
        var seenAddr: Set<String> = [address.lowercased()]
        previousAddresses = person.addresses.dropFirst().map { FormFiller.oneLine($0) }.filter { !$0.isEmpty && seenAddr.insert($0.lowercased()).inserted }
        birthdate = person.birthdate
        country = person.countryCode
    }

    /// The history lines for the "Details to find my records" block. Other names and emails always go; phones and past addresses only when the
    /// company asks for them (`details` nil means a message to several companies, which carries addresses but not phones).
    func historyLines(details: EmailDetails?) -> [String] {
        var out: [String] = []
        if !otherNames.isEmpty { out.append("Other names I have used: " + otherNames.joined(separator: "; ")) }
        if !otherEmails.isEmpty { out.append("Other email addresses I have used: " + otherEmails.joined(separator: ", ")) }
        if details?.phone == true, phones.count > 1 { out.append("Other phone numbers: " + phones.dropFirst().joined(separator: ", ")) }
        if details?.address ?? true, !previousAddresses.isEmpty { out.append("Previous addresses: " + previousAddresses.joined(separator: "; ")) }
        return out
    }
}
