import Foundation

/// What happened to the automatic run as it went, kept so a run export (`RunExport`) can say why a run stopped and what the app was doing at each site: the run
/// starting and ending, the app going to the background and coming back, iOS granting or taking back the run's background time, a stop, a pause and the
/// person's answer to "Carry on?", and each site's result with whether the app was on screen. Kept on the phone only, sealed like the household
/// (`UserDatabase` kind `runLog`); it leaves the phone only inside an export the person shares (docs/PRINCIPLES.md).
public struct RunLogEntry: Codable, Equatable, Sendable {
    public var date: Date
    /// What happened (`RunLog.Event`).
    public var event: String
    /// The site, for a site's result.
    public var site: String?
    public var detail: String?
    /// Whether the app was on screen when it happened.
    public var appActive: Bool?
    /// Seconds since the app last left the screen, when it was away.
    public var awayFor: Double?

    public init(date: Date = Date(), event: String, site: String? = nil, detail: String? = nil, appActive: Bool? = nil, awayFor: Double? = nil) {
        self.date = date; self.event = event; self.site = site; self.detail = detail; self.appActive = appActive; self.awayFor = awayFor
    }
}

public struct RunLog: Codable, Equatable, Sendable {
    public enum Event: String, Sendable {
        case runStarted = "run-started", runEnded = "run-ended", site
        case background, foreground
        case backgroundTimeRequested = "background-time-requested"
        case backgroundTimeGranted = "background-time-granted", backgroundTimeRefused = "background-time-refused"
        case scheduledTaskEnded = "scheduled-task-ended", memoryWarning = "memory-warning", stoppedEarly = "stopped-early"
        case backgroundTimeEnded = "background-time-ended", finishSiteTimeEnded = "finish-site-time-ended"
        case stopAfterSite = "stop-after-site", stoppedByPerson = "stopped-by-person", paused
        case foundCutOff = "found-cut-off", resumeAsked = "resume-asked", resumeAccepted = "resume-accepted", resumeDeclined = "resume-declined"
    }

    public var entries: [RunLogEntry] = []
    /// The newest this many are kept: some three full runs of about 500 sites each.
    public static let kept = 2000

    public init(entries: [RunLogEntry] = []) { self.entries = entries }

    public mutating func add(_ entry: RunLogEntry) {
        entries.append(entry)
        if entries.count > Self.kept { entries.removeFirst(entries.count - Self.kept) }
    }

    /// The entries from `date` on (the current run, for an export).
    public func since(_ date: Date?) -> [RunLogEntry] {
        guard let date else { return entries }
        return entries.filter { $0.date >= date }
    }
}

/// The run log's one sealed row (`UserDatabase` kind `runLog`).
public struct RunLogStore {
    private let database: UserDatabase
    private let keys: KeyProviding
    public init(database: UserDatabase, keys: KeyProviding) { self.database = database; self.keys = keys }

    public func save(_ log: RunLog) throws {
        try database.put(.runLog, try SealedStore.seal(JSONEncoder().encode(log), key: keys.key()))
    }

    /// The log, or an empty one when there is none or it cannot be read (a log is never worth stopping the app for).
    public func load() -> RunLog {
        guard let sealed = (try? database.get(.runLog)) ?? nil, let plain = try? SealedStore.open(sealed, key: keys.key()),
              let log = try? JSONDecoder().decode(RunLog.self, from: plain) else { return RunLog() }
        return log
    }

    public func clear() { try? database.delete(.runLog) }
}

/// The step a background run's site is on ("loading the page", "pressing send", "taking the screenshot"...), so a site given up for going quiet or running out of
/// time says in the run log where it was (`RunLog`, a site's entry). The run works on one site at a time (`AutoOptOut.appParallel`). Cheap: a lock and a string.
public enum RunStep {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var current = "", since = Date(), frozen: String?

    /// The site's work reached `step`.
    public static func note(_ step: String) { lock.lock(); current = step; since = Date(); lock.unlock() }
    /// A new site begins.
    public static func begin() { lock.lock(); current = "starting"; since = Date(); frozen = nil; lock.unlock() }
    /// The run gave the site up: what it was doing then, and for how long.
    static func freeze() { lock.lock(); frozen = "\(current), for \(Int(Date().timeIntervalSince(since))) s"; lock.unlock() }
    /// The step the last given-up site was on, once.
    public static func takeFrozen() -> String? { lock.lock(); defer { frozen = nil; lock.unlock() }; return frozen }
}
