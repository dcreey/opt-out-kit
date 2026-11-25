import Foundation

/// One distinct paragraph of terms text, identified by the hash of its canonical form. The library holds hashes, never
/// site text. A paragraph only counts once a person has read it (`reviewed`) and judged it (`verdict`).
public struct TermsParagraph: Codable, Equatable, Sendable {
    public var hash: String
    public var sites: Int
    public var kinds: [String]
    public var flags: [String]
    public var prefix: String
    public var reviewed: Bool
    public var verdict: String?     // "ok" or "exclude"
    /// The language the paragraph is written in ("en", "fr", "es", "de"). The list keeps each site's own wording and never
    /// translates it; a person reviewing a paragraph reads it in this language. Nil means English (older entries).
    public var lang: String?

    public init(hash: String, sites: Int, kinds: [String], flags: [String], prefix: String, reviewed: Bool, verdict: String?, lang: String? = nil) {
        self.hash = hash; self.sites = sites; self.kinds = kinds; self.flags = flags
        self.prefix = prefix; self.reviewed = reviewed; self.verdict = verdict; self.lang = lang
    }

    public var language: String { lang ?? "en" }

    public var approvedByReviewer: Bool { reviewed && verdict == "ok" }
    /// Wording that bans or implies automated access can never be accepted by the app, whatever a reviewer says,
    /// because the web view that would click "I agree" is itself automated.
    public var forbidsAutomation: Bool { flags.contains("automation") }
}

public struct TermsLibrary: Codable, Equatable, Sendable {
    public var version: Int
    public var paragraphs: [TermsParagraph]

    /// How many paragraphs the list holds in each language, and how many of those a person has reviewed.
    public var languages: [String: (total: Int, reviewed: Int)] {
        var out: [String: (total: Int, reviewed: Int)] = [:]
        for p in paragraphs {
            var e = out[p.language] ?? (0, 0)
            e.total += 1; if p.approvedByReviewer { e.reviewed += 1 }
            out[p.language] = e
        }
        return out
    }

    public init(version: Int, paragraphs: [TermsParagraph]) { self.version = version; self.paragraphs = paragraphs }

    var byHash: [String: TermsParagraph] { Dictionary(paragraphs.map { ($0.hash, $0) }, uniquingKeysWith: { a, _ in a }) }

    public var reviewedCount: Int { paragraphs.filter(\.approvedByReviewer).count }
}

/// The person's explicit, versioned approval: "accept terms for me when they match the reviewed list".
public struct TermsApproval: Codable, Equatable, Sendable {
    public var libraryVersion: Int
    public var approvedAt: Date
    public init(libraryVersion: Int, approvedAt: Date = Date()) { self.libraryVersion = libraryVersion; self.approvedAt = approvedAt }
}

public struct ConsentLogEntry: Codable, Equatable, Sendable {
    public var domain: String
    public var date: Date
    public var paragraphs: Int
    public var libraryVersion: Int
    public init(domain: String, date: Date = Date(), paragraphs: Int, libraryVersion: Int) {
        self.domain = domain; self.date = date; self.paragraphs = paragraphs; self.libraryVersion = libraryVersion
    }
}

public enum TermsDecision: Equatable, Sendable {
    case accept(paragraphs: Int, libraryVersion: Int)   // every substantial paragraph is reviewed ok and the person approved
    case notApproved(paragraphs: Int)                  // text is fine, but the person has not turned this on (or the list changed)
    case unreviewed(count: Int)                        // some paragraph has not been read by a person
    case excluded(flags: [String])                     // a paragraph was ruled out, or bans automated access
    case nothingToJudge                                // no text was captured, so nothing can be accepted
}

public enum TermsGate {
    /// Decides whether the app may press "I agree" for the person. It may only when ALL of these hold:
    /// every substantial paragraph in the prompt and the linked documents is on the reviewed list with verdict ok
    /// (after placeholder canonicalization), none forbids automation, and the person approved this exact list version.
    public static func decide(prompt: String, documents: [String], domain: String,
                              library: TermsLibrary, approval: TermsApproval?) -> TermsDecision {
        let hashes = ([prompt] + documents).reduce(into: Set<String>()) { $0.formUnion(TermsText.paragraphHashes($1, domain: domain)) }
        guard !hashes.isEmpty else { return .nothingToJudge }
        let known = library.byHash
        var unreviewed = 0
        var blocking = Set<String>()
        for h in hashes {
            guard let p = known[h] else { unreviewed += 1; continue }
            if p.forbidsAutomation { blocking.insert("automation"); continue }
            if p.reviewed && p.verdict == "exclude" { blocking.insert("excluded by reviewer"); continue }
            if !p.approvedByReviewer { unreviewed += 1 }
        }
        if !blocking.isEmpty { return .excluded(flags: blocking.sorted()) }
        if unreviewed > 0 { return .unreviewed(count: unreviewed) }
        guard let approval, approval.libraryVersion == library.version else { return .notApproved(paragraphs: hashes.count) }
        return .accept(paragraphs: hashes.count, libraryVersion: library.version)
    }
}

public extension Household {
    /// Device-wide terms settings and the log of every acceptance made for the person.
    var termsApproval: TermsApproval? { settings.termsApproval }
    var consentLog: [ConsentLogEntry] { settings.consentLog }

    var autoSettings: AutoSettings { settings.auto }
    mutating func updateAuto(_ change: (inout AutoSettings) -> Void) { change(&settings.auto) }

    var termsDeclinedVersion: Int? { settings.termsDeclinedVersion }
    mutating func approveTerms(libraryVersion: Int, now: Date = Date()) { settings.termsApproval = TermsApproval(libraryVersion: libraryVersion, approvedAt: now); settings.termsDeclinedVersion = nil }
    /// The person said no to this list version when asked after an update: nothing is accepted for them, and they are not asked again for it.
    mutating func declineTerms(libraryVersion: Int) { settings.termsApproval = nil; settings.termsDeclinedVersion = libraryVersion }
    mutating func revokeTermsApproval() { settings.termsApproval = nil }
    mutating func logConsent(_ entry: ConsentLogEntry) { settings.consentLog.append(entry) }
}
