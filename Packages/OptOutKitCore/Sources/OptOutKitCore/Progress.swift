import Foundation

/// Per-device progress. Platform stores persist this as JSON; the core stays platform-neutral.
public enum CheckSource: String, Codable, Sendable { case automatic, selfReported }

public struct CheckRecord: Codable, Equatable, Sendable {
    public var date: Date
    public var result: CheckResult
    public var source: CheckSource
    public init(date: Date, result: CheckResult, source: CheckSource = .automatic) {
        self.date = date; self.result = result; self.source = source
    }

    enum CodingKeys: String, CodingKey { case date, result, source }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        result = try c.decode(CheckResult.self, forKey: .result)
        source = try c.decodeIfPresent(CheckSource.self, forKey: .source) ?? .automatic
    }
}

/// Whether a submitted opt-out has been confirmed by automatic checks.
public enum Verification: Equatable, Sendable {
    case unverified              // submitted, no conclusive check yet
    case verified(since: Date)   // two separate-day checks found nothing
    case relisted(on: Date)      // a check found the person listed again
}

public struct Progress: Codable, Equatable, Sendable {
    public var completedSteps: [String: Set<Int>] = [:]
    public var doneAt: [String: Date] = [:]
    public var checks: [String: [CheckRecord]] = [:]
    /// What the person (or a scan) saw on directory sites, whether or not an opt-out was submitted there.
    public var siteChecks: [String: [CheckRecord]] = [:]
    /// Automatic opt-out submissions (and the ones that were stopped) per directory site.
    public var optOutAttempts: [String: [OptOutAttempt]] = [:]
    /// Sites the person reported as not working (broken link, gated by something else, blocked them).
    public var siteIssues: [String: [SiteIssue]] = [:]
    /// Sites the person set aside (skipped or not working); they wait a week before they are offered again.
    public var siteSkips: [String: [SiteSkip]] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey { case completedSteps, doneAt, checks, siteChecks, optOutAttempts, siteIssues, siteSkips }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        completedSteps = try c.decodeIfPresent([String: Set<Int>].self, forKey: .completedSteps) ?? [:]
        doneAt = try c.decodeIfPresent([String: Date].self, forKey: .doneAt) ?? [:]
        checks = try c.decodeIfPresent([String: [CheckRecord]].self, forKey: .checks) ?? [:]
        siteChecks = try c.decodeIfPresent([String: [CheckRecord]].self, forKey: .siteChecks) ?? [:]
        optOutAttempts = try c.decodeIfPresent([String: [OptOutAttempt]].self, forKey: .optOutAttempts) ?? [:]
        siteIssues = try c.decodeIfPresent([String: [SiteIssue]].self, forKey: .siteIssues) ?? [:]
        siteSkips = try c.decodeIfPresent([String: [SiteSkip]].self, forKey: .siteSkips) ?? [:]
    }

    /// Records what was seen on a directory site: a scan result or the person's own look.
    public mutating func recordSiteCheck(_ result: CheckResult, site: String, source: CheckSource, on date: Date = Date()) {
        siteChecks[site, default: []].append(CheckRecord(date: date, result: result, source: source))
    }

    public func latestSiteCheck(_ site: String) -> CheckRecord? {
        // A look counts unless it was inconclusive; "blocked by payment" is a real look, so it is not asked about again soon.
        siteChecks[site]?.filter { $0.result != .inconclusive }.max { $0.date < $1.date }
    }

    /// How long a look that found no listing holds: the run leaves the site alone and the Sites tab counts it as done. After it the site is searched again,
    /// since brokers add records.
    public static let notListedWindow: TimeInterval = 30 * 86_400

    /// The latest real look at the site (a scan, the person's own look, or the site's own search run by its opt-out form) found no listing, within `notListedWindow`.
    public func notListedRecently(_ site: String, now: Date = Date()) -> Bool {
        guard let look = latestSiteCheck(site), look.result == .removed else { return false }
        return now.timeIntervalSince(look.date) < Self.notListedWindow
    }

    /// Every site `notListedRecently` holds for: left out of the semi-automated queue like a site set aside, since there is nothing there to do.
    public func notListedSites(now: Date = Date()) -> Set<String> { Set(siteChecks.keys.filter { notListedRecently($0, now: now) }) }

        public mutating func record(_ result: CheckResult, for brokerID: String, on date: Date = Date()) {
        checks[brokerID, default: []].append(CheckRecord(date: date, result: result))
    }

    /// Conclusive checks after the opt-out was submitted decide it. Verified needs two "removed"
    /// in a row on different days, so one odd page cannot mark someone safe. Inconclusive checks are ignored.
    public func verification(for brokerID: String, calendar: Calendar = .current) -> Verification {
        guard let submitted = doneAt[brokerID] else { return .unverified }
        let conclusive = (checks[brokerID] ?? []).filter { $0.date >= submitted && $0.result.isConclusive }
            .sorted { $0.date < $1.date }
        guard let last = conclusive.last else { return .unverified }
        if last.result == .stillListed { return .relisted(on: last.date) }
        guard conclusive.count >= 2 else { return .unverified }
        let prev = conclusive[conclusive.count - 2]
        if prev.result == .removed, !calendar.isDate(prev.date, inSameDayAs: last.date) { return .verified(since: last.date) }
        return .unverified
    }

    /// When the next automatic check is due, or nil if nothing is waiting on one.
    /// First check after the site's processing time, every 2 days until verified, then every `recheckDays`.
    public func nextCheck(for broker: Broker, calendar: Calendar = .current) -> Date? {
        guard let submitted = doneAt[broker.id] else { return nil }
        let all = (checks[broker.id] ?? []).filter { $0.date >= submitted }
        func plus(_ days: Int, _ d: Date) -> Date { calendar.date(byAdding: .day, value: days, to: d) ?? d }
        guard let last = all.map(\.date).max() else { return plus(broker.processingDays ?? 3, submitted) }
        if case .verified = verification(for: broker.id, calendar: calendar) { return plus(broker.recheckDays, last) }
        return plus(2, last)
    }

    public func isStepDone(_ brokerID: String, _ index: Int) -> Bool {
        completedSteps[brokerID]?.contains(index) ?? false
    }

    public func isDone(_ brokerID: String) -> Bool { doneAt[brokerID] != nil }

    /// A step is available once every earlier step is done.
    public func isUnlocked(_ brokerID: String, step index: Int) -> Bool {
        (0..<index).allSatisfy { isStepDone(brokerID, $0) }
    }

    public mutating func complete(_ broker: Broker, step index: Int, now: Date = Date()) {
        guard broker.steps.indices.contains(index), isUnlocked(broker.id, step: index) else { return }
        completedSteps[broker.id, default: []].insert(index)
        if (0..<broker.steps.count).allSatisfy({ isStepDone(broker.id, $0) }) { doneAt[broker.id] = now }
    }

    public mutating func reset(_ brokerID: String) {
        completedSteps[brokerID] = nil
        doneAt[brokerID] = nil
        checks[brokerID] = nil
    }

    /// Next broker in queue order that is not done. Drives the "next-best step" button.
    public func nextBroker(in queue: [Broker]) -> Broker? { queue.first { !isDone($0.id) } }

    /// Share of queued brokers done. TODO: exposure ring should count only re-verified brokers.
    public func completion(in queue: [Broker]) -> Double {
        queue.isEmpty ? 0 : Double(queue.filter { isDone($0.id) }.count) / Double(queue.count)
    }
}
