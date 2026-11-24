import Foundation

/// One stretch of the automatic opt-out's schedule (a month when it runs monthly). Periods are back to back from the first run, so "how many
/// sites are handled this period" means the same thing however many times the run is started inside it: a site that went through once in a
/// period is handled, and later runs in that period leave it alone.
public struct RunPeriod: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }

    /// The period that holds `now`, counting from `anchor` (the first run) in steps of `length`.
    public static func containing(_ now: Date, anchor: Date, length: TimeInterval = AutoSettings.optOutEvery) -> RunPeriod {
        guard now > anchor else { return RunPeriod(start: anchor, end: anchor.addingTimeInterval(length)) }
        let n = (now.timeIntervalSince(anchor) / length).rounded(.down)
        let start = anchor.addingTimeInterval(n * length)
        return RunPeriod(start: start, end: start.addingTimeInterval(length))
    }

    public func previous(length: TimeInterval = AutoSettings.optOutEvery) -> RunPeriod {
        RunPeriod(start: start.addingTimeInterval(-length), end: start)
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }
}

/// How many of the automatic sites went through in one period.
public struct PeriodTally: Equatable, Sendable {
    public var period: RunPeriod
    public var handled: Int
    public var total: Int
    public var complete: Bool { total > 0 && handled >= total }
}

public enum RunPeriods {
    /// The sites (by id) that went through in `period`: a form was sent for them, by the automatic run or by the person.
    public static func handled(in period: RunPeriod, siteIDs: [String], attempts: [String: [OptOutAttempt]]) -> Set<String> {
        Set(siteIDs.filter { id in attempts[id]?.contains { $0.wasSubmitted && period.contains($0.date) } ?? false })
    }

    public static func tally(in period: RunPeriod, siteIDs: [String], attempts: [String: [OptOutAttempt]]) -> PeriodTally {
        PeriodTally(period: period, handled: handled(in: period, siteIDs: siteIDs, attempts: attempts).count, total: siteIDs.count)
    }

    /// The current period first, then earlier ones back to the first run, at most `limit` of them.
    public static func history(anchor: Date, now: Date, siteIDs: [String], attempts: [String: [OptOutAttempt]],
                               limit: Int = 12, length: TimeInterval = AutoSettings.optOutEvery) -> [PeriodTally] {
        var out: [PeriodTally] = []
        var period = RunPeriod.containing(now, anchor: anchor, length: length)
        while out.count < limit {
            out.append(tally(in: period, siteIDs: siteIDs, attempts: attempts))
            if period.start <= anchor { break }
            period = period.previous(length: length)
        }
        return out
    }
}

/// Where one site of the automatic run stands this period, for the activity page's three groups.
public enum ActivityGroup: String, CaseIterable, Sendable {
    case needsYou      // the latest attempt this period did not go through (a check, a refusal, an error): it is in the semi-automated queue
    case sent          // a request went through this period
    case notListed     // the site's own search found no record of the person: nothing to opt out of (done until it is searched again)
    case notTried      // nothing this period yet: not reached, held back by the run's own rules, or set aside by the person; on the automatic page, "Still to do"
    // The automatic page's own groups (decided 2026-11-24: a second run in a period showed the first run's sends as "Not tried"):
    case noAction      // nothing to do: not listed, only holds data on other people, covered by a platform request, or set aside by the person
    case earlier       // handled by an earlier run this period: sent (or emailed) before this run started
}

public struct ActivitySite: Equatable, Sendable {
    public var id: String
    public var group: ActivityGroup
    /// When it went through (sent) or when the attempt that did not go through was made (needs you).
    public var date: Date?
    /// The outcome and detail of the attempt that did not go through.
    public var outcome: String?
    public var detail: String?
    /// Sent, and the latest send was not confirmed by the site in time (it still counts as sent).
    public var unconfirmed = false
}

public extension RunPeriods {
    /// Sorts the run's sites into the three groups by their attempts in `period` (every attempt when there is no period yet). A site sent this period is
    /// "sent" even if a later try failed, because the request stands; an emailed request is the person's and does not count either way.
    /// `since`: only the attempts of the run that began then (the automatic page shows the current run only); otherwise the period's.
    static func activity(siteIDs: [String], attempts: [String: [OptOutAttempt]], period: RunPeriod?, since: Date? = nil) -> [ActivitySite] {
        siteIDs.map { id in
            let list = (attempts[id] ?? []).filter { a in since.map { a.date >= $0 } ?? (period?.contains(a.date) ?? true) }
            if let sent = list.filter(\.wasSubmitted).max(by: { $0.date < $1.date }) { return ActivitySite(id: id, group: .sent, date: sent.date, unconfirmed: sent.wasUnconfirmed) }
            if let last = list.filter({ !$0.wasEmailed }).max(by: { $0.date < $1.date }) {
                if last.wasNotListed { return ActivitySite(id: id, group: .notListed, date: last.date) }
                return ActivitySite(id: id, group: .needsYou, date: last.date, outcome: last.outcome, detail: last.detail)
            }
            return ActivitySite(id: id, group: .notTried)
        }
    }
}

/// One site's standing over every run there has been, for the page that combines them all.
public struct AllRunsSite: Equatable, Sendable {
    public var id: String
    /// Sent: a request went through at least once. Needs you: tried, never sent. Not tried: no run has reached it.
    public var group: ActivityGroup
    public var sends: Int
    public var tries: Int
    public var lastSent: Date?
    /// The latest attempt of any outcome (an emailed request is the person's and is left out).
    public var last: OptOutAttempt?
}

public extension RunPeriods {
    /// Every run combined: each site's sends and tries over all time, and the group its whole history puts it in.
    static func allRuns(siteIDs: [String], attempts: [String: [OptOutAttempt]]) -> [AllRunsSite] {
        siteIDs.map { id in
            let list = (attempts[id] ?? []).filter { !$0.wasEmailed }
            let sent = list.filter(\.wasSubmitted)
            let latest = list.max { $0.date < $1.date }
            let group: ActivityGroup = !sent.isEmpty ? .sent : list.isEmpty ? .notTried : latest?.wasNotListed == true ? .notListed : .needsYou
            return AllRunsSite(id: id, group: group, sends: sent.count, tries: list.count, lastSent: sent.map(\.date).max(), last: list.max { $0.date < $1.date })
        }
    }
}
