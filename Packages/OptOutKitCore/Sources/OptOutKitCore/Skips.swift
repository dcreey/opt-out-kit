import Foundation

/// A site the person set aside instead of doing it: skipped, or reported as not working. It leaves today's batch so the batch fills with the
/// next sites, and comes back after a week with a reminder. A site skipped a second time can be set aside for good.
public struct SiteSkip: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable { case skipped, notWorking }
    public var date: Date
    public var reason: Reason
    public var forever: Bool
    public init(date: Date, reason: Reason, forever: Bool = false) { self.date = date; self.reason = reason; self.forever = forever }
}

public extension Progress {
    /// How long a skipped site waits before it is offered again.
    static let skipWait: TimeInterval = 7 * 86_400

    mutating func skipSite(_ site: String, reason: SiteSkip.Reason, forever: Bool = false, on date: Date = Date()) {
        siteSkips[site, default: []].append(SiteSkip(date: date, reason: reason, forever: forever))
    }

    /// How many times the person has set this site aside.
    func skipCount(_ site: String) -> Int { siteSkips[site]?.count ?? 0 }

    func lastSkip(_ site: String) -> SiteSkip? { siteSkips[site]?.max { $0.date < $1.date } }

    func isSkippedForever(_ site: String) -> Bool { siteSkips[site]?.contains { $0.forever } ?? false }

    /// Finished (a form was sent) after the last time it was set aside: the skip no longer matters.
    private func finishedSinceSkip(_ site: String) -> Bool {
        guard let skip = lastSkip(site) else { return false }
        return optOutAttempts[site]?.contains { $0.wasSubmitted && $0.date > skip.date } ?? false
    }

    /// Set aside right now: skipped for good, or skipped less than a week ago, and not finished since.
    func isParked(_ site: String, now: Date = Date()) -> Bool {
        guard let skip = lastSkip(site), !finishedSinceSkip(site) else { return false }
        return isSkippedForever(site) || now.timeIntervalSince(skip.date) < Self.skipWait
    }

    func parkedSites(now: Date = Date()) -> Set<String> { Set(siteSkips.keys.filter { isParked($0, now: now) }) }

    /// When a waiting site comes back; nil when it is not waiting or was skipped for good.
    func skipReturns(_ site: String, now: Date = Date()) -> Date? {
        guard isParked(site, now: now), !isSkippedForever(site), let skip = lastSkip(site) else { return nil }
        return skip.date.addingTimeInterval(Self.skipWait)
    }

    /// Sites skipped a week or more ago, not skipped for good and not finished since: time to remind the person.
    func skippedDue(now: Date = Date()) -> [String] {
        siteSkips.keys.filter { site in
            guard let skip = lastSkip(site), !isSkippedForever(site), !finishedSinceSkip(site) else { return false }
            return now.timeIntervalSince(skip.date) >= Self.skipWait
        }.sorted()
    }

    /// Every site still set aside or due to be offered again (not finished since).
    func skippedSites() -> [String] { siteSkips.keys.filter { lastSkip($0) != nil && !finishedSinceSkip($0) }.sorted() }

    /// Brings a site back into the queue now.
    mutating func unskip(_ site: String) { siteSkips[site] = nil }
}
