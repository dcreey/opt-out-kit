import Foundation

/// How far a site can be automated, as judged by tools/profile_brokers.py from the shape of its opt-out page.
public enum Automation: String, Codable, Sendable {
    case scriptable          // plain form: a script could drive it
    case guided              // a person must do part of it (human check, phone, ID, email only)
    case needsBrowser = "needs_browser"   // built by JavaScript; needs a real browser even to read
    case blocked             // refuses plain requests
    case robotsDisallowed = "robots_disallowed"
    case unreachable
    case unknown

    public var label: String {
        switch self {
        case .scriptable: return L10n.t("Could be scripted")
        case .guided: return L10n.t("Opened for you")
        case .needsBrowser: return L10n.t("Needs a real browser")
        case .blocked: return L10n.t("Blocks automated requests")
        case .robotsDisallowed: return L10n.t("Asks bots not to visit")
        case .unreachable: return L10n.t("Did not respond")
        case .unknown: return L10n.t("Not yet understood")
        }
    }
}

/// One input on a site's real opt-out form, as the profiler read it.
public struct FormField: Codable, Equatable, Hashable, Sendable {
    public var type: String
    public var name: String
    public var label: String

    public init(type: String, name: String, label: String) { self.type = type; self.name = name; self.label = label }

    /// What a person would call it: the label if the site gave one, else a tidy version of the field name.
    public var display: String {
        let t = label.trimmingCharacters(in: CharacterSet(charactersIn: " *:"))
        if !t.isEmpty, t.count < 100 { return t }
        let base = name.split(separator: "[").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "]")) } ?? name
        return base.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// The real opt-out form the profiler found by following links, with how many hops it took from the home page.
public struct OptOutForm: Codable, Equatable, Hashable, Sendable {
    public var page: URL
    public var method: String
    public var action: URL?
    public var fields: [FormField]
    public var hops: Int

    public init(page: URL, method: String, action: URL?, fields: [FormField], hops: Int) {
        self.page = page; self.method = method; self.action = action; self.fields = fields; self.hops = hops
    }
}

/// How to ask one directory site "is this person listed?", learned by tools/profile_search.py from a made-up
/// name and a known common name. Same idea as a broker's `recheck:` block.
public struct SearchCheck: Codable, Equatable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case calibrated, blocked, robotsDisallowed = "robots_disallowed", undifferentiated, needsPost = "needs_post"
        case needsBrowser = "needs_browser", noSearch = "no_search"
        case termsGate = "terms_gate"      // results sit behind an "I agree to our terms" prompt, which we never accept for anyone
    }
    public var status: Status
    public var searchURL: String?
    public var validPage: [String]?
    public var noResults: [String]?
    public var ignoreLocation: Bool?
    public var calibration: Recheck.Calibration?
    public var method: String?
    public var body: String?
    /// The search only works in a real browser (the app's web view), because results are built by JavaScript.
    public var needsBrowser: Bool?
    /// For sites a plain request cannot read: the search request found on the home page, to try in a web view.
    public var candidate: Candidate?
    public var checked: String?

    public struct Candidate: Codable, Equatable, Hashable, Sendable {
        public var method: String
        public var url: String
        public var body: String?
        public init(method: String, url: String, body: String? = nil) { self.method = method; self.url = url; self.body = body }
    }

    public init(status: Status, searchURL: String? = nil, validPage: [String]? = nil, noResults: [String]? = nil, ignoreLocation: Bool? = nil,
                calibration: Recheck.Calibration? = nil, method: String? = nil, body: String? = nil, needsBrowser: Bool? = nil,
                candidate: Candidate? = nil, checked: String? = nil) {
        self.status = status; self.searchURL = searchURL; self.validPage = validPage; self.noResults = noResults
        self.ignoreLocation = ignoreLocation; self.calibration = calibration; self.method = method; self.body = body
        self.needsBrowser = needsBrowser; self.candidate = candidate; self.checked = checked
    }

    enum CodingKeys: String, CodingKey {
        case status, checked, calibration, method, body, candidate
        case needsBrowser = "needs_browser"
        case searchURL = "search_url", validPage = "valid_page", noResults = "no_results", ignoreLocation = "ignore_location"
    }

    /// A usable check, or nil when the site cannot be checked automatically.
    public var recheck: Recheck? {
        guard status == .calibrated, let searchURL, let validPage, !validPage.isEmpty else { return nil }
        return Recheck(searchURL: searchURL, validPage: validPage, noResults: noResults,
                       needsBrowser: needsBrowser, ignoreLocation: ignoreLocation, calibration: calibration, method: method, body: body)
    }

    public var statusLabel: String {
        switch status {
        case .calibrated: return L10n.t("Can be checked automatically")
        case .blocked: return L10n.t("Blocks automated checks")
        case .robotsDisallowed: return L10n.t("Asks bots not to search it")
        case .undifferentiated: return L10n.t("Search results can't be told apart")
        case .needsPost: return L10n.t("Needs a form submission to search")
        case .needsBrowser: return L10n.t("Search needs a real browser")
        case .termsGate: return L10n.t("Results are behind terms you must accept yourself")
        case .noSearch: return L10n.t("No simple name search found")
        }
    }
}

public extension DirectoryEntry {
    /// Whether the site has a plain address that searches it by name, so a person can be taken to their own results.
    var hasListingSearch: Bool {
        searchCheck?.recheck != nil || (searchCheck?.candidate.map { $0.method.uppercased() == "GET" } ?? false)
    }

    /// The site's search results for this person (name and, when known, city), or nil if there is no such address or the person
    /// may not be searched (minors and public figures, see `Person.canBeSearched`).
    func listingSearchURL(for person: Person) -> URL? {
        guard person.canBeSearched(), hasListingSearch else { return nil }
        let template = searchCheck?.recheck?.searchURL ?? searchCheck?.candidate?.url
        guard let template else { return nil }
        let address = person.addresses.first
        return Rechecker.fill(template, name: person.legalName, city: address?.city, state: address?.state, encoding: .path).flatMap(URL.init(string:))
    }
}

/// What actually blocked the opt-out form when its real page was loaded with a made-up profile and nothing was sent. Each blocker
/// is "check: a reCAPTCHA checkbox", "certify: <the box's text>" or "terms". Empty means nothing blocked the form on load.
/// An invisible check can still appear when the form is sent; the app then stops and asks (see `AutoOptOutResult.challenged`).
public struct LiveCheck: Codable, Equatable, Hashable, Sendable {
    public var checked: String
    public var blockers: [String]
    public init(checked: String, blockers: [String]) { self.checked = checked; self.blockers = blockers }
}

/// What opening the site's page in a real browser (scripts running) found when the crawler had not read a form: whether an opt-out form is
/// there, on which page, and what a person would have to clear before sending (a human check, a terms prompt, a confirmation box).
public struct LiveFormCheck: Codable, Equatable, Hashable, Sendable {
    public var checked: String
    public var found: Bool
    public var page: String?
    public var blockers: [String]
    public init(checked: String, found: Bool, page: String? = nil, blockers: [String] = []) { self.checked = checked; self.found = found; self.page = page; self.blockers = blockers }
    enum CodingKeys: String, CodingKey { case checked, found, page, blockers }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checked = try c.decode(String.self, forKey: .checked); found = try c.decode(Bool.self, forKey: .found)
        page = try c.decodeIfPresent(String.self, forKey: .page); blockers = try c.decodeIfPresent([String].self, forKey: .blockers) ?? []
    }
}

/// Who the company is, what it tracks and who it sells to, read from the company's own home page and privacy policy (see
/// `tools/describe_brokers.py`). Every claim comes from that text; where it says nothing the summary says so.
public struct BrokerAbout: Codable, Equatable, Hashable, Sendable {
    public var category: String
    public var summary: String
    public var tracks: [String]
    public var sellsTo: [String]
    public var sellsNote: String?
    public var source: String?
    public init(category: String, summary: String, tracks: [String] = [], sellsTo: [String] = [], sellsNote: String? = nil, source: String? = nil) {
        self.category = category; self.summary = summary; self.tracks = tracks; self.sellsTo = sellsTo; self.sellsNote = sellsNote; self.source = source
    }
    enum CodingKeys: String, CodingKey { case category, summary, tracks, source; case sellsTo = "sells_to"; case sellsNote = "sells_note" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        category = try c.decode(String.self, forKey: .category); summary = try c.decode(String.self, forKey: .summary)
        tracks = try c.decodeIfPresent([String].self, forKey: .tracks) ?? []; sellsTo = try c.decodeIfPresent([String].self, forKey: .sellsTo) ?? []
        sellsNote = try c.decodeIfPresent(String.self, forKey: .sellsNote); source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

/// How much a broker matters to remove first, from 0 to 100: what kind of company it is, how sensitive and broad the data it names is,
/// how many kinds of buyers it names, and how many states list it.
public enum BrokerPriority {
    /// A tier is the top tenth of brokers by score (high), the next three tenths (medium), or the rest, from the spread of scores in the directory.
    public static func tier(_ score: Int) -> String {
        score >= 60 ? L10n.t("High priority") : score >= 45 ? L10n.t("Medium priority") : L10n.t("Lower priority")
    }
}

/// A warning to show before a person starts this site's opt-out, because the opt-out itself asks for something sensitive in return.
/// The words shown come from `kind`, so they are translated; `note` and `sources` are the site-specific facts and where they came from.
public struct CautionInfo: Codable, Equatable, Hashable, Sendable {
    public var kind: String          // biometric
    public var note: String?
    public var sources: [String]
    public init(kind: String, note: String? = nil, sources: [String] = []) { self.kind = kind; self.note = note; self.sources = sources }
    enum CodingKeys: String, CodingKey { case kind, note, sources }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind); note = try c.decodeIfPresent(String.self, forKey: .note); sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
    }

    public var title: String { L10n.t("Read this first") }
    public var summary: String {
        switch kind {
        case "biometric": return L10n.t("This opt-out asks for a photo of your face and your consent to biometric data. The company says it uses the photo only to block your face from its search results, but you hand a face photo to the company you want to be removed from. Privacy guides are divided on whether it is worth it. The app never uploads a photo for you: this one you do yourself, if you decide to.")
        default: return L10n.t("This opt-out asks for something sensitive in return. Read what it asks for before you start.")
        }
    }
}

/// Why a site is kept out of the app: its only way to opt out is for a business (a sales or contact form asking for a company and title,
/// a signup, a login), or it is not a company that holds personal data about people. These sites are never shown; they are documented in
/// docs/EXCLUDED_SITES.md so they are not added back.
public struct ExcludedCheck: Codable, Equatable, Hashable, Sendable {
    public var checked: String
    public var kind: String        // business_only | not_a_data_broker
    public var reason: String
    public init(checked: String, kind: String, reason: String) { self.checked = checked; self.kind = kind; self.reason = reason }
}

/// Proof that the site no longer responds: every address failed the same way on two tries (see `tools/check_closed.py` and CLOSED_SITES.md).
public struct ClosedCheck: Codable, Equatable, Hashable, Sendable {
    public var checked: String
    public var evidence: [String]
    public init(checked: String, evidence: [String]) { self.checked = checked; self.evidence = evidence }
}

/// What a real, reviewed run showed: the screenshot of the page after sending either showed a confirmation (`confirmed`) or it did not
/// (`failed`, with what the page showed instead). This outranks every guess from reading the page.
public struct RunCheck: Codable, Equatable, Hashable, Sendable {
    public var date: String
    public var result: String          // confirmed | failed
    public var note: String?
    public init(date: String, result: String, note: String? = nil) { self.date = date; self.result = result; self.note = note }
}

/// One site we know about but have no hand-written flow for yet. Generated, provisional, and safe to regenerate.
public struct DirectoryEntry: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var domain: String
    public var name: String
    public var bucket: String           // "direct" (EasyOptOuts submits) or "indirect" (mirror of another site)
    public var tier: Tier?              // provisional A-D; nil when the page could not be read
    public var automation: Automation
    public var confidence: String?
    public var optOutURL: URL?
    public var optOutForm: OptOutForm?  // nil when the profiler could not find the real form
    public var family: String?          // sites sharing one opt-out target
    public var familyParent: String?
    public var template: String?        // sites running the same opt-out form: one flow, one request per site
    public var searchCheck: SearchCheck?  // how to tell whether a person is listed, when that can be automated
    public var liveCheck: LiveCheck?      // what blocked the form on a real page load, when that was measured
    public var runCheck: RunCheck?        // what a real, reviewed run showed
    public var about: BrokerAbout?        // who it is, what it tracks, who it buys and sells
    public var priority: Int?             // 0-100: how much it matters to opt out of first
    public var regionalSites: [RegionalSite]?   // its other-country sites, found by tools/regional_sites.py
    public var languages: SiteLanguages?        // the languages its site is offered in, and the translated address of its opt-out page
    public var regions: RegionScope?     // whose data it collects: the places named in its pages or vendor listings (see tools/tag_regions.py)
    public var persistence: PersistenceInfo?   // whether an opt-out here lasts, or has to be repeated
    public var caution: CautionInfo?      // a warning shown before the opt-out starts (it asks for something sensitive in return)
    public var excluded: ExcludedCheck?   // kept out of the app: its opt-out is for businesses, or it is not a data broker
    public var closed: ClosedCheck?       // evidence that the site no longer responds, so there is nothing to opt out of
    public var liveForm: LiveFormCheck?   // an opt-out form found on the live page when the crawl could not read one
    public var contactEmail: String?      // the privacy address found for this site
    public var contactEmailSource: String?   // where it was found: the opt-out page or its privacy policy
    public var registeredIn: [String]?    // two-letter codes of the states whose broker registry lists this site
    public var signals: [String]?
    public var profiled: String?
    /// True for a site whose page must never have anything of the person's put into it (its form is a sign-up, search or contact form, not a request): the page is shown and the person does the rest.
    public var noFill: Bool?
    /// True for a site with no usable page and no email yet: its link or address is to be found by hand later, so it is not a task today.
    public var findLater: Bool?

    public init(id: String, domain: String, name: String, bucket: String, tier: Tier?, automation: Automation,
                confidence: String? = nil, optOutURL: URL? = nil, optOutForm: OptOutForm? = nil, family: String? = nil,
                familyParent: String? = nil, template: String? = nil, searchCheck: SearchCheck? = nil, liveCheck: LiveCheck? = nil, runCheck: RunCheck? = nil, liveForm: LiveFormCheck? = nil, closed: ClosedCheck? = nil, excluded: ExcludedCheck? = nil, caution: CautionInfo? = nil, persistence: PersistenceInfo? = nil, regions: RegionScope? = nil, languages: SiteLanguages? = nil, regionalSites: [RegionalSite]? = nil, about: BrokerAbout? = nil, priority: Int? = nil, contactEmail: String? = nil, registeredIn: [String]? = nil,
                signals: [String]? = nil, profiled: String? = nil) {
        self.id = id; self.domain = domain; self.name = name; self.bucket = bucket; self.tier = tier; self.automation = automation
        self.confidence = confidence; self.optOutURL = optOutURL; self.optOutForm = optOutForm; self.family = family
        self.familyParent = familyParent; self.template = template; self.searchCheck = searchCheck; self.liveCheck = liveCheck; self.runCheck = runCheck; self.liveForm = liveForm; self.closed = closed; self.excluded = excluded; self.caution = caution; self.persistence = persistence; self.regions = regions; self.languages = languages; self.regionalSites = regionalSites; self.about = about; self.priority = priority; self.contactEmail = contactEmail; self.registeredIn = registeredIn
        self.signals = signals; self.profiled = profiled
    }

    enum CodingKeys: String, CodingKey {
        case id, domain, name, bucket, tier, automation, confidence, family, template, signals, profiled, contactEmailSource = "contact_email_source"
        case searchCheck = "search_check", liveCheck = "live_check", runCheck = "run_check", liveForm = "live_form", closed, excluded, caution, persistence, regions, languages, regionalSites = "regional_sites", about, priority, contactEmail = "contact_email", registeredIn = "registered_in"
        case optOutURL = "opt_out_url", optOutForm = "opt_out_form", familyParent = "family_parent", noFill = "no_fill", findLater = "find_later"
    }
}

public enum Directory {
    /// Sites with no hand-written flow yet. A flow covers a site when it names the domain in `covers:`,
    /// or its id is the site's name (spokeo for spokeo.com).
    public static func unguided(_ entries: [DirectoryEntry], brokers: [Broker]) -> [DirectoryEntry] {
        let covered = Set(brokers.flatMap { $0.covers ?? [] })
        return entries.filter { e in
            !covered.contains(e.domain) &&
            !brokers.contains { e.id == $0.id || e.domain.hasPrefix($0.id + ".") }
        }
    }

    /// The hand-written flow that owns this site: its own (spokeo for spokeo.com) or the one whose request clears it (`covers:`).
    public static func owner(of entry: DirectoryEntry, brokers: [Broker]) -> Broker? {
        brokers.first { $0.id == entry.id || entry.domain.hasPrefix($0.id + ".") || ($0.covers ?? []).contains(entry.domain) }
    }

    /// The generated entry for a hand-written flow's own site (spokeo for spokeo.com), when there is one.
    public static func entry(for broker: Broker, in entries: [DirectoryEntry]) -> DirectoryEntry? {
        entries.first { $0.id == broker.id || $0.domain.hasPrefix(broker.id + ".") }
    }

    /// How many directory sites share this entry's opt-out (including itself), or 1 when it stands alone.
    public static func familySize(of entry: DirectoryEntry, in entries: [DirectoryEntry]) -> Int {
        guard let f = entry.family else { return 1 }
        return entries.filter { $0.family == f }.count
    }
}


/// What the semi-automated flow does with a site's page. Every site with a page is semi-automated; this says how much the app does on it.
public enum PageMode: Equatable, Sendable {
    /// A form the app reads: it fills it in, the person clears whatever the page shows, and it is sent.
    case form
    /// The app fills in whatever it can read on the page and never presses send: the person does the rest and says when it is done (no readable form; a form that asks for an
    /// agent's details, questions the app cannot read, or a file).
    case fillsAndHolds
    /// The page is shown and nothing of the person's is put into it: a business contact form, a site that carries a caution (a face photo), a page the survey found to be a sign-up form.
    case showsOnly
}

public extension DirectoryEntry {
    /// Whether a form is known on this site's page: read by the crawl, or found when the live page was loaded.
    var hasKnownForm: Bool { optOutForm != nil || liveForm?.found == true }

    var pageMode: PageMode {
        let blockers = Set(liveForm?.blockers ?? [])
        if noFill == true || caution != nil || blockers.contains("business") { return .showsOnly }
        if !hasKnownForm || !blockers.isDisjoint(with: ["agent", "other", "file"]) || runCheck?.result == "failed" { return .fillsAndHolds }
        return .form
    }
}
