import Foundation

public struct Address: Codable, Equatable, Sendable {
    public var street: String?
    public var city: String
    public var state: String
    public var fromYear: Int?
    public var toYear: Int?

    public init(street: String? = nil, city: String, state: String, fromYear: Int? = nil, toYear: Int? = nil) {
        self.street = street; self.city = city; self.state = state
        self.fromYear = fromYear; self.toYear = toYear
    }
}

/// How a person relates to the owner of the phone. Family only, for now. Shown as a dropdown in the profile editor.
public enum Relationship: String, Codable, CaseIterable, Sendable {
    case me, parent, child, sibling, spouse, partner, grandparent, grandchild
    case auntUncle, nieceNephew, cousin, otherFamily

    public var label: String {
        switch self {
        case .me: return "Me"
        case .auntUncle: return "Aunt or uncle"
        case .nieceNephew: return "Niece or nephew"
        case .otherFamily: return "Other family"
        default: return rawValue.capitalized
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
        case .legal: return "Legal name"
        case .previousLegal: return "Previous legal name"
        case .maiden: return "Maiden name"
        case .nickname: return "Nickname"
        case .alias: return "Other / spelling variant"
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

    public init(id: UUID = UUID(), displayName: String, relationship: Relationship = .otherFamily,
                names: [NameEntry] = [NameEntry(kind: .legal)], addresses: [Address] = [],
                emails: [String] = [], phones: [String] = [], birthdate: String? = nil,
                isMinor: Bool = false, isPublicFigure: Bool = false) {
        self.id = id; self.displayName = displayName; self.relationship = relationship
        self.names = names; self.addresses = addresses; self.emails = emails
        self.phones = phones; self.birthdate = birthdate
        self.isMinor = isMinor; self.isPublicFigure = isPublicFigure
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, relationship, names, addresses, emails, phones, birthdate, isMinor, isPublicFigure
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

    /// The first legal name, which most broker forms ask for.
    public var legalName: String { names.first { $0.kind == .legal && !$0.name.isEmpty }?.name ?? "" }

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
    public init() {}

    enum CodingKeys: String, CodingKey { case termsApproval, consentLog, auto, healedLinks }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        termsApproval = try c.decodeIfPresent(TermsApproval.self, forKey: .termsApproval)
        consentLog = try c.decodeIfPresent([ConsentLogEntry].self, forKey: .consentLog) ?? []
        auto = try c.decodeIfPresent(AutoSettings.self, forKey: .auto) ?? AutoSettings()
        healedLinks = try c.decodeIfPresent([String: HealedLink].self, forKey: .healedLinks) ?? [:]
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
