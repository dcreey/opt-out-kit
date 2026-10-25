import Foundation

/// How many sites of one kind of broker.
public struct KindCount: Equatable, Sendable {
    public var kind: String
    public var count: Int
    public init(kind: String, count: Int) { self.kind = kind; self.count = count }
}

/// What a person has done with the app so far, for the summary shown the first time they open it each day. It counts requests SENT to
/// sites (and emails sent), not removals confirmed: a site may still ask for a follow-up step.
public struct ActivitySummary: Equatable, Sendable {
    /// Sites a request was sent to, ever.
    public var sites: Int
    /// Sites an opt-out email was sent for, ever.
    public var emails: Int
    /// The same sites by kind of broker, most first (ties by default rank).
    public var byKind: [KindCount]
    /// The most recent day anything was sent, and what was done that day.
    public var lastDay: Date?
    public var lastDaySites: Int
    public var lastDayKinds: [KindCount]
    /// How many different days the person has sent requests.
    public var activeDays: Int
    public var isEmpty: Bool { sites == 0 && emails == 0 }

    static func sorted(_ counts: [String: Int]) -> [KindCount] {
        counts.map { KindCount(kind: $0.key, count: $0.value) }.sorted {
            ($1.count, BrokerCategory(rawValue: $0.kind)?.rank ?? 99, $0.kind) < ($0.count, BrokerCategory(rawValue: $1.kind)?.rank ?? 99, $1.kind)
        }
    }

    public static func build(entries: [DirectoryEntry], attempts: [String: [OptOutAttempt]], calendar: Calendar = .current) -> ActivitySummary {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var kinds: [String: Int] = [:], sites = 0, emails = 0
        var latest: [(day: Date, kind: String)] = []
        for (id, list) in attempts {
            guard let e = byID[id] else { continue }
            if list.contains(where: \.wasEmailed) { emails += 1 }
            let sent = list.filter(\.wasSubmitted).map(\.date)
            guard let last = sent.max() else { continue }
            let kind = e.about?.category ?? "other"
            sites += 1; kinds[kind, default: 0] += 1
            latest.append((calendar.startOfDay(for: last), kind))
        }
        let lastDay = latest.map(\.day).max()
        var lastKinds: [String: Int] = [:]
        for item in latest where item.day == lastDay { lastKinds[item.kind, default: 0] += 1 }
        return ActivitySummary(sites: sites, emails: emails, byKind: sorted(kinds), lastDay: lastDay, lastDaySites: lastKinds.values.reduce(0, +),
                               lastDayKinds: sorted(lastKinds), activeDays: Set(latest.map(\.day)).count)
    }
}
