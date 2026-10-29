import Foundation

/// What a link pasted from an email says about itself, checked against the directory and what the person already did.
public enum LinkCheck: Equatable, Sendable {
    /// The link's site is one we know. `completedOn` is when a request there was already finished; `awaitingEmail` when it still waits on this email.
    case known(entryID: String, name: String, completedOn: Date?, awaitingEmail: Bool)
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

    public static func check(_ url: URL, entries: [DirectoryEntry], attempts: [String: [OptOutAttempt]]) -> LinkCheck {
        guard let host = url.host else { return .unknown(host: "") }
        let owner = registrable(host)
        guard let entry = entries.first(where: { owners(of: $0).contains(owner) }) else { return .unknown(host: host) }
        let history = attempts[entry.id] ?? []
        return .known(entryID: entry.id, name: entry.name, completedOn: FollowUps.completedOn(history), awaitingEmail: FollowUps.isPending(history))
    }
}

/// Requests that were sent but said an email would follow with more to do. Finishing one adds an "email_done" attempt, so nothing else is stored.
public enum FollowUps {
    /// The state of the latest word from the site: an email is still due when the newest send-or-finish note is "submitted_email".
    public static func isPending(_ history: [OptOutAttempt]) -> Bool {
        history.filter { $0.outcome == "submitted" || $0.outcome == "submitted_email" || $0.outcome == "email_done" }
            .max { $0.date < $1.date }?.outcome == "submitted_email"
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
