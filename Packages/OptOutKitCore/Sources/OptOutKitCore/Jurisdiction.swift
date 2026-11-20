import Foundation
import Yams

/// What a place's law says about data brokers and about its residents' rights, with enough detail to tell a person what the app does
/// for them there. Facts live in `jurisdictions/*.yml`, each reviewed by a person on a date, and are refreshed periodically.
/// US states first; countries use the same shape (`kind`) when they are added.
public struct Jurisdiction: Codable, Identifiable, Equatable, Sendable {
    /// How firm a right is: `yes` (a defined right with the usual exceptions), `limited` (only in some circumstances), `unclear`
    /// (the sources do not say) or `no`. Older entries wrote `true` and `false`.
    public enum Right: String, Codable, Equatable, Sendable {
        case yes, limited, unclear, no
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = b ? .yes : .no; return }
            let t = try c.decode(String.self)
            guard let r = Right(rawValue: t) else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown right \(t)") }
            self = r
        }
    }

    public struct PrivacyLaw: Codable, Equatable, Sendable {
        public var name: String
        public var effective: String?        // nil when the sources are not clear about the date
        public var status: String            // in_effect | enacted
        public var deletionRight: Right
        public var optOutOfSale: Bool?       // US states
        public var objection: String?        // countries: general | marketing | limited | none
        public var nationalAct: String?      // EU/EEA members: the national law beside the GDPR
        public var universalOptOut: String?  // required | reported
        public var narrow: Bool?             // reaches few businesses (Florida's applies only to very large platforms)
        public var note: String?
        /// Whether the law applies today: by its effective date when there is one, otherwise by the recorded status.
        public func isInEffect(on now: Date = Date()) -> Bool {
            if let e = effective, let d = Jurisdiction.day(e) { return d <= now }
            return status == "in_effect"
        }
        enum CodingKeys: String, CodingKey { case name, effective, status, note, narrow, objection
            case deletionRight = "deletion_right", optOutOfSale = "opt_out_of_sale", universalOptOut = "universal_opt_out", nationalAct = "national_act" }
    }

    /// A law that is being considered, moving through a legislature, or passed but not in effect yet. `stage` is `proposed`
    /// (introduced or in committee), `advancing` (passed a chamber or in conference) or `passed` (signed, takes effect later).
    public struct PendingLaw: Codable, Equatable, Sendable {
        public var name: String
        public var stage: String
        public var kind: String?             // privacy | data_broker
        public var effective: String?
        public var asOf: String?
        public var url: String?
        public var note: String?
        enum CodingKeys: String, CodingKey { case name, stage, kind, effective, url, note, asOf = "as_of" }
    }

    public struct Regulator: Codable, Equatable, Sendable {
        public var name: String
        public var url: String?
    }

    public struct BrokerRegistry: Codable, Equatable, Sendable {
        public var status: String            // live | planned
        /// What the registry lists: `brokers` (the default), `databases`, `controllers` or `agents`. Only brokers' registries are pulled.
        public var kind: String?
        public var agency: String?
        public var law: String?
        public var url: String?
        public var fetcher: String?          // which tools/registries.py importer reads it
        public var note: String?
    }

    /// A list or mechanism a law or government runs that the app does not use yet. Kept as future work, with where it was found.
    public struct FutureWork: Codable, Equatable, Sendable, Identifiable {
        public var kind: String              // broker_registry | central_register | one_stop_deletion | opt_out_signal
        public var name: String
        public var url: String?
        public var note: String
        public var sourced: Bool?            // false when only the name is known and the details still need checking
        public var id: String { kind + name }
    }

    public var id: String
    public var code: String                  // "CA"
    public var name: String
    public var kind: String?                 // us_state, later country (set from the file)
    public var privacyLaw: PrivacyLaw?
    public var brokerRegistry: BrokerRegistry?
    public var deletionPlatform: String?     // id of a platform in platforms/
    public var deletionMechanismNote: String?
    public var bloc: String?                 // "eu" or "eea" for members, which the GDPR also covers
    public var regulator: Regulator?
    public var sources: [String]?
    public var pending: [PendingLaw]?
    public var futureWork: [FutureWork]?
    /// The state's law makes sites honor the Global Privacy Control signal (sources differ on the full list, so this is the ones most agree on).
    public var gpc: Bool?
    public var reviewed: String

    enum CodingKeys: String, CodingKey {
        case id, code, name, kind, reviewed, bloc, regulator, sources, pending
        case futureWork = "future_work", gpc
        case privacyLaw = "privacy_law", brokerRegistry = "broker_registry"
        case deletionPlatform = "deletion_platform", deletionMechanismNote = "deletion_mechanism_note"
    }

    static func day(_ text: String) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: text)
    }

    public var registryIsLive: Bool { brokerRegistry?.status == "live" && (brokerRegistry?.kind ?? "brokers") == "brokers" }
    public var isCountry: Bool { kind == "country" || kind == "bloc" }

    /// How much the law here does for a resident, judged only from the recorded facts.
    public enum Strength: Int, Comparable, Sendable {
        case none, limited, solid, strong
        public static func < (a: Strength, b: Strength) -> Bool { a.rawValue < b.rawValue }
    }

    /// strong: a privacy law in effect, a live broker registry, and either a one-request service or a required universal opt-out
    /// signal. solid: a privacy law in effect or a live registry. limited: a law that is not in effect yet, a narrow one, or a registry
    /// not open yet. none: nothing.
    public var strength: Strength {
        let lawInEffect = privacyLaw?.isInEffect() == true && privacyLaw?.narrow != true && [.yes, .limited].contains(privacyLaw?.deletionRight)
        if lawInEffect, registryIsLive, deletionPlatform != nil || privacyLaw?.universalOptOut == "required" { return .strong }
        if lawInEffect || registryIsLive { return .solid }
        if privacyLaw != nil || brokerRegistry != nil { return .limited }
        return .none
    }
}

/// Counts from the registries we pull, produced by `tools/registries.py merge`.
public struct RegistrySummary: Codable, Equatable, Sendable {
    public struct Count: Codable, Equatable, Sendable { public var count: Int; public var withWebsite: Int
        enum CodingKeys: String, CodingKey { case count, withWebsite = "with_website" } }
    public var generated: String
    public var knownSites: Int
    public var unresolved: Int
    public var jurisdictions: [String: Count]
    public var inSeveral: Int
    enum CodingKeys: String, CodingKey { case generated, unresolved, jurisdictions
        case knownSites = "known_sites", inSeveral = "in_several" }
}

public enum JurisdictionLoader {
    struct File: Decodable { var kind: String?; var reviewed: String?; var jurisdictions: [Jurisdiction] }

    /// Every jurisdiction in every `*.yml` in the folder.
    public static func load(directory: URL) throws -> [Jurisdiction] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "yml" }
        var out: [Jurisdiction] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let f = try YAMLDecoder().decode(File.self, from: String(contentsOf: file, encoding: .utf8))
            out += f.jurisdictions.map { var j = $0; if j.kind == nil { j.kind = f.kind }; return j }
        }
        var seen = Set<String>()
        for j in out where !seen.insert(j.id).inserted { throw RegistryError.duplicateID(j.id) }
        return out
    }

    public static func loadSummary(_ url: URL) -> RegistrySummary? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(RegistrySummary.self, from: $0) }
    }
}

/// One line of what the app tells a person about where they live.
public struct JurisdictionStatement: Equatable, Sendable {
    public var symbol: String
    public var text: String
    public var url: String?               // where to read the law or bill, when the line is about one
    public init(symbol: String, text: String, url: String? = nil) { self.symbol = symbol; self.text = text; self.url = url }
}

public extension Jurisdiction {
    /// A link to the real page where a fact was found, labeled with the site it is on.
    struct SourceLink: Equatable, Sendable, Identifiable {
        public var title: String
        public var url: String
        public var id: String { url }
    }

    /// Every page this place's facts came from: the sources we recorded, the regulator and the registry's agency page.
    var sourceLinks: [SourceLink] {
        var seen = Set<String>(), out: [SourceLink] = []
        func add(_ url: String?, _ label: String?) {
            guard let url, let host = URL(string: url)?.host, seen.insert(url).inserted else { return }
            out.append(.init(title: label ?? host.replacingOccurrences(of: "www.", with: ""), url: url))
        }
        if let r = regulator { add(r.url, r.name) }
        if let b = brokerRegistry { add(b.url, b.agency) }
        for u in sources ?? [] { add(u, nil) }
        for p in pending ?? [] { add(p.url, nil) }
        return out
    }

    /// The place's name in the current language ("California" becomes "Californie" in French; countries come from the system's own
    /// region names, so "Germany" is "Deutschland" in German).
    var displayName: String {
        if kind == "country", let local = Locale(identifier: L10n.language).localizedString(forRegionCode: code), !local.isEmpty { return local }
        return L10n.t(name)
    }

    /// What this place's law means for the person and what the app does about it, in plain words. `platforms` are the services
    /// the app can guide them through; `summary` has the registry counts. `others` are the other places, for comparison.
    func statements(summary: RegistrySummary?, platforms: [Platform], others: [Jurisdiction] = []) -> [JurisdictionStatement] {
        if isCountry { return countryStatements(summary: summary, platforms: platforms, others: others) }
        var out: [JurisdictionStatement] = []
        let place = displayName
        let total = summary?.knownSites
        let counts = summary.map { s in s.jurisdictions.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.count)" }.joined(separator: ", ") }

        // 1. Registry
        switch brokerRegistry?.status {
        case "live":
            if let n = summary?.jurisdictions[code]?.count {
                out.append(.init(symbol: "list.bullet.rectangle", text: L10n.f("%@ requires data brokers to register themselves. We pull this registry (%@ brokers) and add every broker on it to our list.", place, n)))
            } else {
                out.append(.init(symbol: "list.bullet.rectangle", text: L10n.f("%@ requires data brokers to register themselves. We pull this registry and add every broker on it to our list.", place)))
            }
        case "planned":
            out.append(.init(symbol: "clock", text: L10n.f("%@ is setting up a data broker registry. We will pull it as soon as it opens.", place)))
        default:
            out.append(.init(symbol: "list.bullet.rectangle", text: L10n.f("%@ does not run a data broker registry. Our list still comes from the registries other states publish.", place)))
        }

        // 2. Deletion platform
        if let id = deletionPlatform, let p = platforms.first(where: { $0.id == id }) {
            out.append(.init(symbol: "bolt.shield",
                             text: L10n.f("%@ has an automatic opt-out for all of these registries (%@). We integrate with this process to simplify it: we walk you through the one request, then leave those brokers' own forms alone for a while.", place, p.shortName)))
        } else if deletionMechanismNote != nil {
            out.append(.init(symbol: "bolt.shield", text: L10n.f("%@ is building one request that reaches every registered broker. We will add it when it opens.", place)))
        }

        // 3. Beyond the registry
        if let total {
            out.append(.init(symbol: "globe",
                             text: L10n.f("We also go beyond your state's registry: our list combines every registry we can read (%@) with other known brokers, %@ sites in all, whichever state or country they registered in.", counts ?? "", total)))
        }

        // 4. Privacy law
        if let law = privacyLaw {
            let when = law.effective ?? ""
            var line = law.isInEffect()
                ? (when.isEmpty ? L10n.f("%@'s privacy law, the %@, gives residents the right to delete their data and to opt out of its sale.", place, law.name)
                                : L10n.f("%@'s privacy law, the %@ (in effect since %@), gives residents the right to delete their data and to opt out of its sale.", place, law.name, when))
                : L10n.f("%@'s privacy law, the %@ (takes effect %@), gives residents the right to delete their data and to opt out of its sale. Until then, brokers are not required to honor it.", place, law.name, when)
            if law.narrow == true { line += " " + L10n.t("It applies only to very large platforms, so it rarely reaches data brokers.") }
            else if law.isInEffect(), law.name.contains("Maryland") { line += " " + L10n.t("Applies to processing from 2026-04-01.") }
            out.append(.init(symbol: "scroll", text: line))
            if law.universalOptOut == "required" {
                out.append(.init(symbol: "hand.raised", text: L10n.f("Businesses in %@ must honor a universal opt-out signal such as Global Privacy Control. Turning it on in your browser helps on every site you visit.", place)))
            } else if law.universalOptOut == "reported" {
                out.append(.init(symbol: "hand.raised", text: L10n.f("Some sources say businesses in %@ must honor universal opt-out signals such as Global Privacy Control. Turning it on in your browser costs nothing.", place)))
            }
        } else {
            out.append(.init(symbol: "scroll", text: L10n.f("%@ has no comprehensive privacy law, so no state law makes brokers honor you. Most still accept opt-out requests from anyone, and that is what this app sends.", place)))
        }
        out += pendingStatements()
        out += comparison(summary: summary, platforms: platforms, others: others)
        return out
    }

    /// Laws that are being considered or have passed but are not in effect yet, so nobody mistakes them for rights they have today.
    func pendingStatements(now: Date = Date()) -> [JurisdictionStatement] {
        (pending ?? []).filter { p in p.effective.flatMap { Jurisdiction.day($0) }.map { $0 > now } ?? true }.map { p in
            let note = p.note ?? ""
            switch p.stage {
            case "passed":
                return .init(symbol: "calendar.badge.clock", text: L10n.f("Passed but not in effect yet (takes effect %@): %@. %@", p.effective ?? "-", p.name, note), url: p.url)
            case "advancing":
                return .init(symbol: "arrow.triangle.2.circlepath", text: L10n.f("Moving through the legislature, not law yet: %@. %@", p.name, note), url: p.url)
            default:
                return .init(symbol: "text.badge.plus", text: L10n.f("Being considered, not law yet: %@. %@", p.name, note), url: p.url)
            }
        }
    }

    /// Where the person's state offers less, points at states that offer more and what that means there, with an example of each.
    /// Nothing is added for a state that is already strong.
    func comparison(summary: RegistrySummary?, platforms: [Platform], others: [Jurisdiction]) -> [JurisdictionStatement] {
        guard strength < .strong else { return [] }
        let pool = others.filter { $0.code != code }.sorted { $0.name < $1.name }
        var examples: [JurisdictionStatement] = []

        // One request reaches every registered broker.
        if let j = pool.first(where: { $0.deletionPlatform != nil && $0.registryIsLive }),
           let p = platforms.first(where: { $0.id == j.deletionPlatform }) {
            if let n = summary?.jurisdictions[j.code]?.count {
                examples.append(.init(symbol: "arrow.up.right.circle", text: L10n.f("In %@, one free request through %@ reaches all %@ registered data brokers, and they are legally required to process it. There you would file once instead of once per site.", j.displayName, p.shortName, n)))
            } else {
                examples.append(.init(symbol: "arrow.up.right.circle", text: L10n.f("In %@, one free request through %@ reaches every registered data broker, and they are legally required to process it. There you would file once instead of once per site.", j.displayName, p.shortName)))
            }
        }
        // A registry plus a privacy law plus a required universal opt-out signal.
        if let j = pool.first(where: { $0.registryIsLive && $0.privacyLaw?.isInEffect() == true && $0.privacyLaw?.universalOptOut == "required" && $0.deletionPlatform == nil }),
           let law = j.privacyLaw {
            examples.append(.init(symbol: "arrow.up.right.circle",
                                  text: L10n.f("In %@, brokers must register publicly and say how to opt out, and the %@ lets residents demand deletion and opt out of the sale of their data. Businesses there must also honor a universal opt-out signal such as Global Privacy Control.", j.displayName, law.name)))
        }
        // A privacy law with a required universal opt-out signal.
        if let j = pool.first(where: { !$0.registryIsLive && $0.privacyLaw?.isInEffect() == true && $0.privacyLaw?.universalOptOut == "required" }),
           let law = j.privacyLaw {
            examples.append(.init(symbol: "arrow.up.right.circle",
                                  text: L10n.f("In %@, the %@ gives residents a legal right to delete their data and opt out of its sale. Businesses there are required to respond to a verified request.", j.displayName, law.name)))
        }
        guard !examples.isEmpty else { return [] }
        let limit = strength == .solid ? 1 : 3
        var out: [JurisdictionStatement] = [.init(symbol: "arrow.up.forward.app",
            text: L10n.f("Some places go further than %@. Here is what stronger rules look like, so you know what to expect and what a family member living there would get:", displayName))]
        out += examples.prefix(limit)
        out.append(.init(symbol: "person.2", text: L10n.t("Add a family member's address and their state's rules apply to them. Brokers outside those states usually still accept opt-out requests, and that is what this app sends.")))
        return out
    }
}

public extension Jurisdiction {
    /// The same plain-words account for a country (or the EU): its law, what it gives residents, who regulates it, whether it runs a broker
    /// registry, and how our list reaches beyond it.
    func countryStatements(summary: RegistrySummary?, platforms: [Platform], others: [Jurisdiction]) -> [JurisdictionStatement] {
        var out: [JurisdictionStatement] = []
        let place = displayName

        guard let law = privacyLaw else {
            out.append(.init(symbol: "scroll", text: L10n.f("We do not have %@'s data protection rules yet. Most brokers still accept opt-out requests from anyone, and that is what this app sends.", place)))
            return out + comparison(summary: summary, platforms: platforms, others: others)
        }

        // 1. The law
        if law.isInEffect() {
            if let when = law.effective { out.append(.init(symbol: "scroll", text: L10n.f("%@ has a data protection law: %@ (in effect since %@).", place, L10n.t(law.name), when))) }
            else { out.append(.init(symbol: "scroll", text: L10n.f("%@ has a data protection law: %@.", place, L10n.t(law.name)))) }
        } else {
            out.append(.init(symbol: "scroll", text: L10n.f("%@ has passed a data protection law, %@, which takes effect %@. Until then, organizations there are not required to honor it.", place, L10n.t(law.name), law.effective ?? "-")))
        }
        if let act = law.nationalAct, bloc != nil {
            out.append(.init(symbol: "building.columns", text: L10n.f("As a member of the EU/EEA, the GDPR applies in %@ directly. The national law beside it is the %@.", place, act)))
        }

        // 2. What it gives residents
        switch law.deletionRight {
        case .yes: out.append(.init(symbol: "trash", text: L10n.t("You can ask organizations to delete your personal data. The usual exceptions apply, such as a legal duty to keep it.")))
        case .limited: out.append(.init(symbol: "trash", text: L10n.t("You can ask organizations to delete or correct your data in some circumstances, but it is not an absolute right.")))
        case .unclear: out.append(.init(symbol: "trash", text: L10n.t("We could not confirm a general right to have your data deleted under this law, so a deletion request may be refused.")))
        case .no: out.append(.init(symbol: "trash", text: L10n.t("This law gives no general right to have your data deleted. You can usually withdraw your consent.")))
        }
        switch law.objection {
        case "general" where bloc != nil || code == "EU": out.append(.init(symbol: "hand.raised", text: L10n.t("You can object to the use of your data, and an objection to direct marketing is absolute.")))
        case "general": out.append(.init(symbol: "hand.raised", text: L10n.t("You can object to some uses of your data, including direct marketing.")))
        case "marketing": out.append(.init(symbol: "hand.raised", text: L10n.t("You can opt out of direct marketing at any time.")))
        case "limited": out.append(.init(symbol: "hand.raised", text: L10n.t("You can withdraw your consent, and opt out of direct marketing in some cases.")))
        default: break
        }

        // 3. The regulator
        if let r = regulator {
            if let url = r.url, let host = URL(string: url)?.host {
                out.append(.init(symbol: "person.badge.shield.checkmark", text: L10n.f("Your regulator is %@ (%@). You can complain to it if a company ignores a request.", r.name, host)))
            } else {
                out.append(.init(symbol: "person.badge.shield.checkmark", text: L10n.f("Your regulator is %@. You can complain to it if a company ignores a request.", r.name)))
            }
        }

        // 4. Registries
        let total = summary?.knownSites
        switch (brokerRegistry?.status, brokerRegistry?.kind ?? "brokers") {
        case ("live", "brokers"):
            out.append(.init(symbol: "list.bullet.rectangle", text: L10n.f("%@ requires some data brokers to register with %@. We do not pull that registry yet.", place, brokerRegistry?.agency ?? "")))
        case ("live", "agents"):
            out.append(.init(symbol: "list.bullet.rectangle", text: L10n.f("In Quebec, businesses that build credit-style files on people must register with %@. %@ has no general data broker registry.", brokerRegistry?.agency ?? "", place)))
        case ("live", _):
            out.append(.init(symbol: "list.bullet.rectangle", text: L10n.f("%@ requires organizations to register with %@, but that lists organizations in general, not data brokers, so we do not pull it.", place, brokerRegistry?.agency ?? "")))
        default:
            out.append(.init(symbol: "list.bullet.rectangle", text: L10n.f("%@ does not run a data broker registry, so there is no official list of brokers to pull.", place)))
        }
        if let total {
            out.append(.init(symbol: "globe", text: L10n.f("We go beyond any one country's registry: our list combines every registry we can read (US states so far) with other known brokers, %@ sites in all. Many of them are US companies that may not have to follow your country's law, but most accept opt-out requests from anyone and this app sends them.", total)))
        }
        return out + pendingStatements() + comparison(summary: summary, platforms: platforms, others: others)
    }
}
