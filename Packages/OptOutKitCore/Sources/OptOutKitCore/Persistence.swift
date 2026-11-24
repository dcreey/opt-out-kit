import Foundation

/// Whether an opt-out at a broker lasts. Read from the broker's own privacy policy (see `tools/describe_persistence.py`); where the
/// policy is silent the result is `unknown`, and the broker is treated as one that refills its data, so the person is asked to repeat it.
public struct PersistenceInfo: Codable, Equatable, Hashable, Sendable {
    public var result: String          // permanent | temporary | unknown
    public var reupMonths: Int?
    public var quote: String?
    public var source: String?
    public init(result: String, reupMonths: Int? = nil, quote: String? = nil, source: String? = nil) { self.result = result; self.reupMonths = reupMonths; self.quote = quote; self.source = source }
    enum CodingKeys: String, CodingKey { case result, quote, source; case reupMonths = "reup_months" }
}

public extension DirectoryEntry {
    /// Months after a request is sent when it should be repeated, or nil when the policy says the opt-out is kept for good.
    /// Six months for kinds that re-list people quickly, twelve otherwise.
    var reupMonths: Int? {
        if persistence?.result == "permanent" { return nil }
        if let m = persistence?.reupMonths { return m }
        return (about?.category == "people_search" || about?.category == "location_data") ? 6 : 12
    }

    /// The last day a request was sent to this site, if any.
    func lastSent(in attempts: [String: [OptOutAttempt]]) -> Date? { (attempts[id] ?? []).filter(\.wasSubmitted).map(\.date).max() }

    /// Whether a request sent earlier still holds: sent, and not yet due to be repeated.
    func isCurrent(attempts: [String: [OptOutAttempt]], now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let sent = lastSent(in: attempts) else { return false }
        guard let months = reupMonths, let due = calendar.date(byAdding: .month, value: months, to: sent) else { return true }
        return now < due
    }

    /// The date a request sent on `sent` should be repeated, or nil when it lasts.
    func reupDate(after sent: Date, calendar: Calendar = .current) -> Date? { reupMonths.flatMap { calendar.date(byAdding: .month, value: $0, to: sent) } }

    /// Done for now: a request that still holds, a recent look found no listing here (`Progress.notListedRecently`), or the site holds data only on a group
    /// of people (`onlyFor`). Every "is this site done" asks this.
    func isHandled(_ progress: Progress, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        isCurrent(attempts: progress.optOutAttempts, now: now, calendar: calendar) || progress.notListedRecently(id, now: now) || onlyFor != nil
    }

    /// Sent before, and now due to be repeated.
    func isDueToRenew(attempts: [String: [OptOutAttempt]], now: Date = Date(), calendar: Calendar = .current) -> Bool {
        lastSent(in: attempts) != nil && !isCurrent(attempts: attempts, now: now, calendar: calendar)
    }
}
