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
