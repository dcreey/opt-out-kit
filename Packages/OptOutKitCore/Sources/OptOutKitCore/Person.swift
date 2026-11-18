import Foundation

public struct Address: Codable, Equatable, Sendable {
    public var street: String?
    public var city: String
    public var state: String
    /// ZIP or postal code. Required for the current address, since forms and listings match on it.
    public var zip: String?
    public var fromYear: Int?
    public var toYear: Int?
    /// Two-letter country code. Empty means the United States, which is what every address before this field was.
    public var country: String?

    public init(street: String? = nil, city: String, state: String, zip: String? = nil, fromYear: Int? = nil, toYear: Int? = nil, country: String? = nil) {
        self.street = street; self.city = city; self.state = state; self.zip = zip; self.country = country
        self.fromYear = fromYear; self.toYear = toYear
    }
}

/// How a person relates to the owner of the phone. Family only, for now. Shown as a dropdown in the profile editor.
public enum Relationship: String, Codable, CaseIterable, Sendable {
    case me, parent, child, sibling, spouse, partner, grandparent, grandchild
    case auntUncle, nieceNephew, cousin, otherFamily

    public var label: String {
        switch self {
        case .me: return L10n.t("Me")
        case .auntUncle: return L10n.t("Aunt or uncle")
        case .nieceNephew: return L10n.t("Niece or nephew")
        case .otherFamily: return L10n.t("Other family")
        case .parent: return L10n.t("Parent")
        case .child: return L10n.t("Child")
        case .sibling: return L10n.t("Sibling")
        case .spouse: return L10n.t("Spouse")
        case .partner: return L10n.t("Partner")
        case .grandparent: return L10n.t("Grandparent")
        case .grandchild: return L10n.t("Grandchild")
        case .cousin: return L10n.t("Cousin")
        }
    }

    /// Anything saved before the list was narrowed to family (friend, other, ...) reads back as "Other family".
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Relationship(rawValue: raw) ?? .otherFamily
    }
}

public enum NameKind: String, Codable, CaseIterable, Sendable {
    case legal, previousLegal, maiden, nickname, alias

    public var label: String {
        switch self {
        case .legal: return L10n.t("Legal name")
        case .previousLegal: return L10n.t("Previous legal name")
        case .maiden: return L10n.t("Maiden name")
        case .nickname: return L10n.t("Nickname")
        case .alias: return L10n.t("Other / spelling variant")
        }
    }
}

/// One name a person is listed under. Brokers list the same person under several, so there is no limit.
public struct NameEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: NameKind
    public var name: String

    public init(id: UUID = UUID(), kind: NameKind = .alias, name: String = "") {
        self.id = id; self.kind = kind; self.name = name
    }
}

/// Someone the app runs opt-outs for: the user, or a family member who asked them to.
/// Relatives are simply other people in the household, linked by `relationship`.
public struct Person: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var relationship: Relationship
    public var names: [NameEntry]
    public var addresses: [Address]      // current first, then previous
    public var emails: [String]
    public var phones: [String]
    public var birthdate: String?
    /// Under 18. Several sites' terms forbid searching for minors, so these profiles are never searched (see `canBeSearched`).
    public var isMinor: Bool
    /// A public official or celebrity. The same terms forbid searching for them. Defaults to no.
    public var isPublicFigure: Bool
    /// Kept so older saved profiles still load. The owner's plain "I am this person" box is now always ticked for them (see
    /// `mayConfirmOwnIdentity`), so this value no longer changes anything.
    public var confirmsOwnIdentity: Bool
    /// Optional. The address of the person's own LinkedIn profile, typed by them. Filled only into a box that says LinkedIn (recruiting and workforce
    /// sites that need it to find a record); never sent anywhere else.
    public var linkedIn: String?

    public init(id: UUID = UUID(), displayName: String, relationship: Relationship = .otherFamily,
                names: [NameEntry] = [NameEntry(kind: .legal)], addresses: [Address] = [],
                emails: [String] = [], phones: [String] = [], birthdate: String? = nil,
                isMinor: Bool = false, isPublicFigure: Bool = false, confirmsOwnIdentity: Bool = false, linkedIn: String? = nil) {
        self.id = id; self.displayName = displayName; self.relationship = relationship
        self.names = names; self.addresses = addresses; self.emails = emails
        self.phones = phones; self.birthdate = birthdate
        self.isMinor = isMinor; self.isPublicFigure = isPublicFigure; self.confirmsOwnIdentity = confirmsOwnIdentity
        self.linkedIn = linkedIn
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, relationship, names, addresses, emails, phones, birthdate, isMinor, isPublicFigure, confirmsOwnIdentity, linkedIn
    }

    /// Profiles saved before the safety flags existed load with both off.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        relationship = try c.decode(Relationship.self, forKey: .relationship)
        names = try c.decodeIfPresent([NameEntry].self, forKey: .names) ?? [NameEntry(kind: .legal)]
        addresses = try c.decodeIfPresent([Address].self, forKey: .addresses) ?? []
        emails = try c.decodeIfPresent([String].self, forKey: .emails) ?? []
        phones = try c.decodeIfPresent([String].self, forKey: .phones) ?? []
        birthdate = try c.decodeIfPresent(String.self, forKey: .birthdate)
        isMinor = try c.decodeIfPresent(Bool.self, forKey: .isMinor) ?? false
        isPublicFigure = try c.decodeIfPresent(Bool.self, forKey: .isPublicFigure) ?? false
        confirmsOwnIdentity = try c.decodeIfPresent(Bool.self, forKey: .confirmsOwnIdentity) ?? false
        linkedIn = try c.decodeIfPresent(String.self, forKey: .linkedIn)
    }

    /// The LinkedIn address as a full link, or nil when none was entered. "linkedin.com/in/pat" gets https://; anything that is not a LinkedIn address is not used.
    public var linkedInURL: String? {
        var s = (linkedIn ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard let host = URL(string: s)?.host?.lowercased(), host == "linkedin.com" || host.hasSuffix(".linkedin.com") else { return nil }
        return s
    }

    /// Whether the app may tick "I am this person" for this profile: only the account owner, only after they allowed it, never a minor.
    public func mayConfirmOwnIdentity(on date: Date = Date()) -> Bool {
        relationship == .me && !isMinorNow(on: date)
    }

    /// Age in whole years from a "YYYY-MM-DD" birthdate, or nil when there is none or it cannot be read.
    public func age(on date: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let birthdate else { return nil }
        let parts = birthdate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let born = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return calendar.dateComponents([.year], from: born, to: date).year
    }

    /// The flag, or a birthdate that says under 18. Either one counts.
    public func isMinorNow(on date: Date = Date(), calendar: Calendar = .current) -> Bool {
        isMinor || (age(on: date, calendar: calendar).map { $0 < 18 } ?? false)
    }

    /// Whether the app may search sites for this person (scans, automatic re-checks, quick checks) or accept terms for them.
    /// The terms of the sites we meet most often forbid searching for minors, public officials and celebrities.
    /// Opt-out forms are not searches, so those still work for everyone.
    public func canBeSearched(on date: Date = Date(), calendar: Calendar = .current) -> Bool {
        !isMinorNow(on: date, calendar: calendar) && !isPublicFigure
    }

    /// The current address: the first one. Previous addresses follow it.
    public var currentAddress: Address? { addresses.first }
    /// The country the person lives in: the current address's, else the United States when its state is one, else unknown.
    public var countryCode: String? {
        guard let a = currentAddress else { return nil }
        if let c = a.country, !c.isEmpty { return c.uppercased() }
        return USStates.code(for: a.state) != nil || a.state.isEmpty ? "US" : nil
    }

    /// What is still missing from the details every profile needs: a legal first and last name, and a current street, city and state.
    /// Empty when the profile is complete.
    public var missingRequiredDetails: [String] {
        var out: [String] = []
        if legalFirst.isEmpty { out.append(L10n.noun("Legal first name")) }
        if legalLast.isEmpty { out.append(L10n.noun("Legal last name")) }
        if age() == nil { out.append(L10n.noun("Birthdate")) }
        let a = currentAddress
        if (a?.street ?? "").trimmingCharacters(in: .whitespaces).isEmpty { out.append(L10n.noun("Current street address")) }
        if (a?.city ?? "").trimmingCharacters(in: .whitespaces).isEmpty { out.append(L10n.noun("Current city")) }
        if (a?.state ?? "").trimmingCharacters(in: .whitespaces).isEmpty, (countryCode ?? "US") == "US" { out.append(L10n.noun("Current state")) }
        if (a?.zip ?? "").trimmingCharacters(in: .whitespaces).isEmpty { out.append(L10n.noun("Current ZIP code")) }
        // A previous address that has been started needs its ZIP code too.
        for (i, p) in addresses.enumerated() where i > 0 {
            let started = [p.street ?? "", p.city, p.state].contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if started, (p.zip ?? "").trimmingCharacters(in: .whitespaces).isEmpty { out.append(L10n.noun("ZIP code for a previous address")); break }
        }
        return out
    }

    public var isComplete: Bool { missingRequiredDetails.isEmpty }

    /// The first legal name, which most broker forms ask for.
    public var legalName: String { names.first { $0.kind == .legal && !$0.name.isEmpty }?.name ?? "" }

    /// The legal name as separate parts: the first word, the last word, and anything between them as the middle name.
    public var legalFirst: String { legalName.split(separator: " ").first.map(String.init) ?? "" }
    public var legalLast: String { legalName.split(separator: " ").count > 1 ? legalName.split(separator: " ").last.map(String.init) ?? "" : "" }
    public var legalMiddle: String {
        let w = legalName.split(separator: " ").map(String.init)
        return w.count > 2 ? w[1..<(w.count - 1)].joined(separator: " ") : ""
    }

    /// Joins the parts back into the stored legal name; the middle name is optional.
    public static func composeLegalName(first: String, middle: String, last: String) -> String {
        [first, middle, last].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Every non-empty name, for matching listings under any of them.
    public var allNames: [String] { names.map(\.name).filter { !$0.isEmpty } }

    /// Value for a broker-definition field name (`fields:` in the YAML). Nil when the person has none,
    /// so a broker is never handed a field the person did not provide.
    public func value(for field: String) -> String? {
        switch field {
        case "full_name": return legalName.isEmpty ? nil : legalName
        case "email": return emails.first
        case "phone": return phones.first
        case "birthdate": return birthdate
        case "address":
            guard let a = addresses.first else { return nil }
            return [a.street, a.city, a.state].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        default: return nil
        }
    }
}

/// Everyone on this device and each person's own progress. Persisted as one JSON blob by the platform store.
public struct HouseholdSettings: Codable, Equatable, Sendable {
    public var termsApproval: TermsApproval?
    public var consentLog: [ConsentLogEntry] = []
    public var auto = AutoSettings()
    /// Opt-out links the app found for itself after a recorded one broke. Per site, kept on this device only.
    public var healedLinks: [String: HealedLink] = [:]
    /// The one email address put on every opt-out form and deletion request, for everyone in the household (see `ContactEmail`).
    public var contactEmail: String?
    /// The state the account owner chose in the walkthrough ("CA"). Only used until their profile has a current address, which then decides.
    public var ownerState: String?
    /// The country the account owner chose ("US", "FR", or "OTHER" for one the app has no rules for yet).
    public var ownerCountry: String?
    public init() {}

    enum CodingKeys: String, CodingKey { case termsApproval, consentLog, auto, healedLinks, contactEmail, ownerState, ownerCountry }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        termsApproval = try c.decodeIfPresent(TermsApproval.self, forKey: .termsApproval)
        consentLog = try c.decodeIfPresent([ConsentLogEntry].self, forKey: .consentLog) ?? []
        auto = try c.decodeIfPresent(AutoSettings.self, forKey: .auto) ?? AutoSettings()
        healedLinks = try c.decodeIfPresent([String: HealedLink].self, forKey: .healedLinks) ?? [:]
        contactEmail = try c.decodeIfPresent(String.self, forKey: .contactEmail)
        ownerState = try c.decodeIfPresent(String.self, forKey: .ownerState)
        ownerCountry = try c.decodeIfPresent(String.self, forKey: .ownerCountry)
    }
}

/// The single address used on every form, exactly as the person typed it. (An earlier version tagged Gmail addresses with `+optoutkit`,
/// but many opt-out forms look the person up by that exact address, so a changed one finds nothing.)
public enum ContactEmail {
    public static let tag = "+optoutkit"

    /// A plain check that this looks like an address: something, an `@`, a domain with a dot. Not a promise it exists.
    public static func isValid(_ email: String) -> Bool {
        let t = email.trimmingCharacters(in: .whitespaces)
        let parts = t.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !t.contains(" ") else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    /// An address found on a web page: spaces and the punctuation of the sentence it sat in ("legal@site.com.", "<a@b.com>,") are cut off the end,
    /// and nil comes back when what is left is not an address. Applied to every address the directory carries.
    public static func cleaned(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let edge = CharacterSet(charactersIn: ".,;:!?-_<>()[]\"'").union(.whitespacesAndNewlines)
        let t = raw.trimmingCharacters(in: edge)
        // An image or script name that has an @ in it ("privacy-how-1@2x.png") is not an address.
        let tld = t.split(separator: ".").last.map { $0.lowercased() } ?? ""
        if ["png", "jpg", "jpeg", "gif", "svg", "webp", "css", "js"].contains(tld) { return nil }
        return isValid(t) ? t : nil
    }

    public static func isGmail(_ email: String) -> Bool {
        let domain = email.split(separator: "@").last.map { $0.lowercased() } ?? ""
        return domain == "gmail.com" || domain == "googlemail.com"
    }

    /// What goes into forms: the address as typed, unaltered.
    public static func forForms(_ email: String) -> String { email.trimmingCharacters(in: .whitespaces) }
}

public extension Household {
    var contactEmail: String? { settings.contactEmail }
    /// The address used on forms, exactly as typed, or nil until one has been given.
    var formEmail: String? { settings.contactEmail.flatMap { ContactEmail.isValid($0) ? ContactEmail.forForms($0) : nil } }
    var ownerState: String? { settings.ownerState }
    mutating func setOwnerState(_ code: String?) { settings.ownerState = code }
    var ownerCountry: String? { settings.ownerCountry }
    /// Choosing a country other than the US clears the state, which only the US has.
    mutating func setOwnerCountry(_ code: String?) { settings.ownerCountry = code; if code != nil, code != "US" { settings.ownerState = nil } }
    mutating func setContactEmail(_ email: String?) {
        let t = email?.trimmingCharacters(in: .whitespaces)
        settings.contactEmail = (t?.isEmpty ?? true) ? nil : t
    }
}

public struct Household: Codable, Equatable, Sendable {
    public private(set) var people: [Person] = []
    public private(set) var progress: [UUID: Progress] = [:]
    var settings = HouseholdSettings()

    public init() {}

    enum CodingKeys: String, CodingKey { case people, progress, settings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        people = try c.decodeIfPresent([Person].self, forKey: .people) ?? []
        progress = try c.decodeIfPresent([UUID: Progress].self, forKey: .progress) ?? [:]
        settings = try c.decodeIfPresent(HouseholdSettings.self, forKey: .settings) ?? HouseholdSettings()
    }

    public mutating func add(_ person: Person) {
        guard !people.contains(where: { $0.id == person.id }) else { return }
        people.append(person)
        progress[person.id] = Progress()
    }

    public mutating func update(_ person: Person) {
        if let i = people.firstIndex(where: { $0.id == person.id }) { people[i] = person }
    }

    /// Removing a person deletes their data and progress together.
    public mutating func remove(_ id: UUID) {
        people.removeAll { $0.id == id }
        progress[id] = nil
    }

    /// Emails used by more than one person. Brokers that allow one opt-out per address need distinct ones.
    public var sharedEmails: Set<String> {
        var seen = [String: Int]()
        for p in people { for e in Set(p.emails.map { $0.lowercased() }) { seen[e, default: 0] += 1 } }
        return Set(seen.filter { $0.value > 1 }.keys)
    }

    public func progress(for id: UUID) -> Progress { progress[id] ?? Progress() }

    public mutating func mutateProgress(for id: UUID, _ change: (inout Progress) -> Void) {
        guard people.contains(where: { $0.id == id }) else { return }
        change(&progress[id, default: Progress()])
    }
}
