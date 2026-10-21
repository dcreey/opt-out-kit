import Foundation
import Yams

/// How far a site can be automated, as judged by tools/profile_brokers.py from the shape of its opt-out page.
public enum Automation: String, Codable, Sendable {
    case scriptable          // plain form: a script could drive it
    case guided              // a person must do part of it (bot check, phone, ID, email only)
    case needsBrowser = "needs_browser"   // built by JavaScript; needs a real browser even to read
    case blocked             // refuses plain requests
    case robotsDisallowed = "robots_disallowed"
    case unreachable
    case unknown

    public var label: String {
        switch self {
        case .scriptable: return "Could be scripted"
        case .guided: return "Guided walkthrough"
        case .needsBrowser: return "Needs a real browser"
        case .blocked: return "Blocks automated requests"
        case .robotsDisallowed: return "Asks bots not to visit"
        case .unreachable: return "Did not respond"
        case .unknown: return "Not yet understood"
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
        if !t.isEmpty, t.count < 40 { return t }
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
        case .calibrated: return "Can be checked automatically"
        case .blocked: return "Blocks automated checks"
        case .robotsDisallowed: return "Asks bots not to search it"
        case .undifferentiated: return "Search results can't be told apart"
        case .needsPost: return "Needs a form submission to search"
        case .needsBrowser: return "Search needs a real browser"
        case .termsGate: return "Results are behind terms you must accept yourself"
        case .noSearch: return "No simple name search found"
        }
    }
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
    public var signals: [String]?
    public var profiled: String?

    public init(id: String, domain: String, name: String, bucket: String, tier: Tier?, automation: Automation,
                confidence: String? = nil, optOutURL: URL? = nil, optOutForm: OptOutForm? = nil, family: String? = nil,
                familyParent: String? = nil, template: String? = nil, searchCheck: SearchCheck? = nil,
                signals: [String]? = nil, profiled: String? = nil) {
        self.id = id; self.domain = domain; self.name = name; self.bucket = bucket; self.tier = tier; self.automation = automation
        self.confidence = confidence; self.optOutURL = optOutURL; self.optOutForm = optOutForm; self.family = family
        self.familyParent = familyParent; self.template = template; self.searchCheck = searchCheck
        self.signals = signals; self.profiled = profiled
    }

    enum CodingKeys: String, CodingKey {
        case id, domain, name, bucket, tier, automation, confidence, family, template, signals, profiled
        case searchCheck = "search_check"
        case optOutURL = "opt_out_url", optOutForm = "opt_out_form", familyParent = "family_parent"
    }
}

public extension Registry {
    /// Loads every `*.yml` in the directory folder. Files that fail to decode are an error, not skipped.
    static func loadDirectory(_ directory: URL) throws -> [DirectoryEntry] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "yml" }
        let entries = try files.map { try YAMLDecoder().decode(DirectoryEntry.self, from: String(contentsOf: $0, encoding: .utf8)) }
        var seen = Set<String>()
        for e in entries where !seen.insert(e.id).inserted { throw RegistryError.duplicateID(e.id) }
        return entries.sorted { $0.domain < $1.domain }
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

    /// How many directory sites share this entry's opt-out (including itself), or 1 when it stands alone.
    public static func familySize(of entry: DirectoryEntry, in entries: [DirectoryEntry]) -> Int {
        guard let f = entry.family else { return 1 }
        return entries.filter { $0.family == f }.count
    }
}
