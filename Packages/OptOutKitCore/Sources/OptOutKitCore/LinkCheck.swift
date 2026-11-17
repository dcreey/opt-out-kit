import Foundation

/// What a link pasted from an email says about itself, checked against the directory and what the person already did.
public enum LinkCheck: Equatable, Sendable {
    /// The link's site is one we know. `completedOn` is when a request there was already finished; `awaitingEmail` when it still waits on this email.
    case known(entryID: String, name: String, completedOn: Date?, awaitingEmail: Bool)
    /// Several sites use this link's domain (a privacy-portal provider such as OneTrust, or a group of sister sites) and the address does not say which is meant.
    /// `suggestions` are entry ids, most likely first: sites waiting on an email, then the rest that use the domain. The person says which one it is.
    case shared(host: String, suggestions: [String])
    /// Nothing in the directory has this site.
    case unknown(host: String)

    /// The part of a host that names the owner ("privacy.liveintent.com" is "liveintent.com"; "a.example.co.uk" is "example.co.uk").
    public static func registrable(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let secondLevel: Set<String> = ["co", "com", "org", "net", "gov", "ac"]
        let take = (labels[labels.count - 1].count == 2 && secondLevel.contains(labels[labels.count - 2])) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }

    /// Every owner name the directory knows for one entry: its domain, its opt-out pages and its privacy address.
    static func owners(of entry: DirectoryEntry) -> Set<String> {
        var out: Set<String> = [registrable(entry.domain)]
        for url in [entry.optOutURL, entry.optOutForm?.page, entry.liveForm?.page.flatMap { URL(string: $0) }] {
            if let h = url?.host { out.insert(registrable(h)) }
        }
        if let at = entry.contactEmail?.split(separator: "@").last { out.insert(registrable(String(at))) }
        return out
    }

    /// The full hosts an entry is known by, without a leading "www." ("blackbaud-privacy.my.onetrust.com"): its own domain and the hosts of its opt-out pages.
    static func hosts(of entry: DirectoryEntry) -> Set<String> {
        var out: Set<String> = [entry.domain.lowercased()]
        for url in [entry.optOutURL, entry.optOutForm?.page, entry.liveForm?.page.flatMap { URL(string: $0) }] {
            if let h = url?.host { out.insert(h.lowercased()) }
        }
        return Set(out.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 })
    }

    /// The state of one site as a link check reports it: what was finished, and whether it still waits on an email.
    public static func state(of entry: DirectoryEntry, attempts: [String: [OptOutAttempt]]) -> LinkCheck {
        let history = attempts[entry.id] ?? []
        return .known(entryID: entry.id, name: entry.name, completedOn: FollowUps.completedOn(history), awaitingEmail: FollowUps.isPending(history))
    }

    /// True when the link's address is one this site is known by (its domain, an opt-out page's host, or a subdomain of either). A link the person
    /// assigned to a site by hand is only filled in and sent for them when this holds.
    public static func verifies(_ url: URL, for entry: DirectoryEntry) -> Bool {
        guard let host = url.host else { return false }
        return owners(of: entry).contains(registrable(host))
    }

    /// Which site a link is for. One site that uses the link's domain is that site. When several do (a privacy-portal provider's tenants, sister sites), the
    /// full address picks one only if exactly one site is known by it; otherwise the answer is `.shared` and the person chooses.
    public static func check(_ url: URL, entries: [DirectoryEntry], attempts: [String: [OptOutAttempt]]) -> LinkCheck {
        guard let host = url.host?.lowercased() else { return .unknown(host: "") }
        let owner = registrable(host)
        let matches = entries.filter { owners(of: $0).contains(owner) }
        if matches.isEmpty { return .unknown(host: host) }
        if matches.count == 1 { return state(of: matches[0], attempts: attempts) }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let exact = matches.filter { hosts(of: $0).contains(bare) }
        // Only an address with a name of its own in front of the provider ("blackbaud-privacy.my.onetrust.com": two labels before "onetrust.com") says which site it is.
        // A provider's general address ("privacyportal.onetrust.com") is the same for every site, even when one site's page happens to be recorded under it.
        let extra = bare.split(separator: ".").count - owner.split(separator: ".").count
        if exact.count == 1, extra >= 2 { return state(of: exact[0], attempts: attempts) }
        let waiting = { (e: DirectoryEntry) in FollowUps.isPending(attempts[e.id] ?? []) }
        let primary = { (e: DirectoryEntry) in registrable(e.domain) == owner }
        let isExact = { (e: DirectoryEntry) in exact.contains(where: { $0.id == e.id }) }
        let ordered = matches.sorted { a, b in
            if isExact(a) != isExact(b) { return isExact(a) }
            if waiting(a) != waiting(b) { return waiting(a) }
            if primary(a) != primary(b) { return primary(a) }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return .shared(host: host, suggestions: ordered.map(\.id))
    }

    /// Sites matching what the person typed, for the "which site is this?" search: names and domains that start with it first, then those that contain it.
    public static func find(_ query: String, in entries: [DirectoryEntry], limit: Int = 60) -> [DirectoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        func rank(_ e: DirectoryEntry) -> Int? {
            let name = e.name.lowercased()
            let domain = e.domain.lowercased()
            if name.hasPrefix(q) || domain.hasPrefix(q) || domain.hasPrefix("www." + q) { return 0 }
            let words: [Substring] = name.split(separator: " ")
            if words.contains(where: { $0.hasPrefix(q) }) { return 1 }
            if name.contains(q) || domain.contains(q) { return 2 }
            return nil
        }
        var ranked: [(entry: DirectoryEntry, rank: Int)] = []
        for e in entries { if let r = rank(e) { ranked.append((e, r)) } }
        ranked.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.entry.name.localizedCaseInsensitiveCompare(b.entry.name) == .orderedAscending
        }
        return Array(ranked.prefix(limit).map { $0.entry })
    }
}

/// Requests that were sent but said an email would follow with more to do. Finishing one adds an "email_done" attempt, so nothing else is stored.
public enum FollowUps {
    /// The state of the latest word from the site: an email is still due when the newest send-or-finish note is "submitted_email".
    public static func isPending(_ history: [OptOutAttempt]) -> Bool {
        history.filter { $0.outcome == "submitted" || $0.outcome == "submitted_email" || $0.outcome == "email_done" }
            .max { $0.date < $1.date }?.outcome == "submitted_email"
    }

    /// How many email steps the person has finished for this request since it was last sent: the notes "email_done" after the newest plain send.
    /// A site can ask for several (confirm the address, then confirm the identity); each one finished adds a note and each new one found adds "submitted_email" again.
    public static func stepsDone(_ history: [OptOutAttempt]) -> Int {
        let lastSend = history.filter { $0.outcome == "submitted" }.map(\.date).max() ?? .distantPast
        return history.filter { $0.outcome == "email_done" && $0.date > lastSend }.count
    }

    /// When a note about this request that follows the newest one should be dated: now, but never at or before the newest note, so "newest" is never a tie.
    public static func nextDate(_ history: [OptOutAttempt], now: Date = Date()) -> Date {
        guard let last = history.map(\.date).max(), last >= now else { return now }
        return last.addingTimeInterval(1)
    }

    /// When the request was last finished: sent with nothing more to do, or its email step done.
    public static func completedOn(_ history: [OptOutAttempt]) -> Date? {
        guard !isPending(history) else { return nil }
        return history.filter { $0.outcome == "submitted" || $0.outcome == "email_done" }.map(\.date).max()
    }

    /// Sites usually answer within this many days; a request still waiting on its email after that needs a follow-up.
    public static let overdueDays = 45

    /// Requests that have waited on their email longer than `overdueDays`, oldest first.
    public static func overdue(_ attempts: [String: [OptOutAttempt]], now: Date = Date(), days: Int = overdueDays) -> [(id: String, since: Date)] {
        pending(attempts).filter { now.timeIntervalSince($0.since) >= Double(days) * 86_400 }
    }

    /// Entry ids whose request still waits on an email, oldest first.
    public static func pending(_ attempts: [String: [OptOutAttempt]]) -> [(id: String, since: Date)] {
        attempts.compactMap { id, h in
            isPending(h) ? (id, h.filter { $0.outcome == "submitted_email" }.map(\.date).max() ?? .distantPast) : nil
        }.sorted { $0.since < $1.since }
    }
}
