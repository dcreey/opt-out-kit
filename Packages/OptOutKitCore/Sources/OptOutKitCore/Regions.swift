import Foundation

/// The places whose residents a broker collects data about. Every site came from a US state registry, so "US" is always there; the others are
/// added only when something says so (a vendor listing, a policy naming a non-US law), and what said so is kept.
public struct RegionScope: Codable, Equatable, Hashable, Sendable {
    public var list: [String]            // "US", "EU", "UK", "CA", ...
    public var evidence: String?
    public var checked: String?
    public init(list: [String], evidence: String? = nil, checked: String? = nil) { self.list = list; self.evidence = evidence; self.checked = checked }
}

/// A broker's site for another country or region (example.co.uk, fr.example.com, example.com/de/), with the opt-out or privacy page found on it.
public struct RegionalSite: Codable, Equatable, Hashable, Sendable {
    public var region: String            // ISO country code ("GB", "FR")
    public var url: String
    public var how: String               // hreflang, country domain, country subdomain, country path, probed country domain
    public var privacyPage: String?
    public var hasForm: Bool?
    enum CodingKeys: String, CodingKey { case region, url, how, privacyPage = "privacy_page", hasForm = "has_form" }
    /// A site reached by a link or a language alternate on the broker's own page. A probed country domain is only a lead.
    public var isStrong: Bool { !how.hasPrefix("probed") }
    public init(region: String, url: String, how: String, privacyPage: String? = nil, hasForm: Bool? = nil) { self.region = region; self.url = url; self.how = how; self.privacyPage = privacyPage; self.hasForm = hasForm }
}

/// The languages a broker's site is offered in (two-letter codes), and its opt-out page in each, when the page says where its translations are.
public struct SiteLanguages: Codable, Equatable, Hashable, Sendable {
    public var list: [String]
    public var pages: [String: String]    // language tag ("fr", "fr-FR") -> address of the opt-out page in that language
    public var checked: String?
    public init(list: [String], pages: [String: String] = [:], checked: String? = nil) { self.list = list; self.pages = pages; self.checked = checked }
}

public enum Regions {
    static let eu: Set<String> = ["AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE", "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE", "IS", "LI", "NO"]

    /// The region labels that cover a person in this country ("FR" is covered by sites tagged FR or EU; "GB" by UK).
    public static func labels(forCountry code: String) -> Set<String> {
        let c = code.uppercased()
        var out: Set<String> = [c]
        if eu.contains(c) { out.insert("EU") }
        if c == "GB" { out.insert("UK") }
        return out
    }

    /// The places a person's own country covers, "US" when it is not known (the directory is a US one).
    public static func labels(forCountry code: String?) -> Set<String> { labels(forCountry: code ?? "US") }

    /// Whether a site collects data about people in this country. A site with no tag counts as US.
    public static func reaches(_ entry: DirectoryEntry, country: String?) -> Bool {
        !Set(entry.regions?.list ?? ["US"]).isDisjoint(with: labels(forCountry: country ?? "US"))
    }

    /// Splits sites into those that reach the person's country and those that do not. The two always add up to the input.
    public static func partition(_ entries: [DirectoryEntry], country: String?) -> (inRegion: [DirectoryEntry], elsewhere: [DirectoryEntry]) {
        var a: [DirectoryEntry] = [], b: [DirectoryEntry] = []
        for e in entries { if reaches(e, country: country) { a.append(e) } else { b.append(e) } }
        return (a, b)
    }

    /// The English name of a country, as a form asks for it ("France", "United Kingdom").
    public static func englishName(_ code: String) -> String? { Locale(identifier: "en_US").localizedString(forRegionCode: code.uppercased()) }

    /// The law a person in this country invokes, named the way the request should name it.
    public static func law(forCountry code: String?) -> String {
        let c = (code ?? "US").uppercased()
        switch c {
        case "US": return "the privacy laws that apply to me (including the CCPA/CPRA and other state privacy laws)"
        case "GB": return "the UK GDPR and the Data Protection Act 2018 (including Articles 17 and 21)"
        case "CA": return "PIPEDA, and Quebec's Law 25 where it applies"
        case "BR": return "the LGPD (Lei Geral de Prote\u{E7}\u{E3}o de Dados, Article 18)"
        case "AR": return "Ley 25.326 de Protecci\u{F3}n de los Datos Personales (Articles 16 and 27)"
        case "AU": return "the Privacy Act 1988 and the Australian Privacy Principles"
        default:
            if eu.contains(c) { return "the GDPR (including Articles 17 and 21)" }
            return "the data protection laws that apply to me"
        }
    }

    /// The broker's own site for this person's country, when it has one: a French resident uses the broker's French site, not its US one.
    public static func regionalSite(for entry: DirectoryEntry, country: String?) -> RegionalSite? {
        guard let c = country?.uppercased(), c != "US" else { return nil }
        return entry.regionalSites?.first { $0.isStrong && $0.region.uppercased() == c }
    }

    /// The opt-out page in the person's language, when the site says where it is. A tag for their own country wins ("fr-CA" for someone in Canada).
    public static func localizedPage(for entry: DirectoryEntry, language: String, country: String?) -> URL? {
        let lang = language.lowercased().split(separator: "-").first.map(String.init) ?? language.lowercased()
        guard lang != "en", let pages = entry.languages?.pages else { return nil }
        let matches = pages.filter { $0.key.lowercased().split(separator: "-").first.map(String.init) == lang }
        let pick = matches.first { $0.key.lowercased().hasSuffix("-" + (country ?? "").lowercased()) } ?? matches.sorted { $0.key < $1.key }.first
        return pick.flatMap { URL(string: $0.value) }
    }

    /// The name of a language for display, in English.
    public static func languageName(_ code: String) -> String { Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code }
}
