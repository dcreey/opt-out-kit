import Foundation

/// What a background run does. The first run, and then every six months, is a **full** pass over every site that can be tried. In between (every three months) the
/// **repeat** pass sends again to the sites whose latest attempt went through. A site that does not go through on either is left for the person's semi-automated queue.
public enum RunKind: String, Codable, Sendable { case full, repeatSent }

public enum SubmitOutcome: Equatable, Sendable {
    case submitted(awaitingEmail: Bool)   // a success message was seen; awaitingEmail when it asks for an email confirmation
    case filledNotSubmitted               // dry run: the form was filled and left unsent
    case challenged(String)               // a visible human check, terms prompt or similar stopped the run; never solved or accepted
    case rejected(String)                 // the site refused or flagged a field
    case failed(String)                   // no success message was seen, so nothing is claimed
}

/// Fills in and sends one site's opt-out form. The app backs it with its hidden web view; tests use fakes.
public protocol FormSubmitter: Sendable {
    func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome
    /// The same, and a screenshot of what the page showed when it finished (the confirmation, or what stopped it), as JPEG data.
    func submitCapturing(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitEvidence
}

public struct SubmitEvidence: Sendable {
    public var outcome: SubmitOutcome
    public var screenshot: Data?
    public init(outcome: SubmitOutcome, screenshot: Data? = nil) { self.outcome = outcome; self.screenshot = screenshot }
}

public extension FormSubmitter {
    func submitCapturing(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitEvidence {
        SubmitEvidence(outcome: await submit(form, plan: plan, dryRun: dryRun))
    }
}

/// A site already reached by a platform request the person made (California DROP): we leave it alone until `until`.
public struct PlatformHold: Equatable, Sendable {
    public var name: String
    public var until: Date
    public init(name: String, until: Date) { self.name = name; self.until = until }
}

public enum AutoOptOutResult: Equatable, Sendable {
    case submitted(awaitingEmail: Bool)
    case dryRunReady
    case skippedNotListed            // a recent look found no listing, so no details were sent
    case coveredByPlatform(name: String, until: Date)   // a platform request (California DROP) already covers this site; asked again after the hold
    case tooSoon(until: Date)        // already submitted recently
    case needsData([String])
    case needsYou(String)
    case challenged(String)
    case rejected(String)
    case failed(String)
    case emailed                       // this site did not take the form; the person emailed their opt-out to it instead

    public var label: String {
        switch self {
        case .submitted(let email): return email ? L10n.t("Sent; confirm the email they sent you") : L10n.t("Sent")
        case .dryRunReady: return L10n.t("Ready (dry run, nothing sent)")
        case .skippedNotListed: return L10n.t("Skipped: not listed there")
        case .coveredByPlatform(let name, let until):
            if until == .distantFuture { return L10n.f("Covered by %@: its one request handles this site", name) }
            return L10n.f("Covered by %@ until %@", name, L10n.date(until))
        case .tooSoon: return L10n.t("Sent recently")
        case .needsData(let what): return L10n.f("Add your %@ to your profile", what.joined(separator: ", "))
        case .needsYou(let why): return L10n.f("Needs you: %@", why)
        case .challenged(let why): return L10n.f("Stopped: %@", why)
        case .rejected(let why): return L10n.f("The site refused: %@", why)
        case .failed(let why): return L10n.f("No confirmation: %@", why)
        case .emailed: return L10n.t("Asked by email instead")
        }
    }
}

public struct OptOutAttempt: Codable, Equatable, Sendable {
    public var date: Date
    public var outcome: String           // "submitted", "submitted_email", "challenged", "rejected", "failed"
    public var detail: String?
    public init(date: Date, outcome: String, detail: String? = nil) { self.date = date; self.outcome = outcome; self.detail = detail }
    /// A form was sent to the site. Emailing a request is tracked separately (`outcome == "emailed"`), so one never stands in for the other.
    public var wasSubmitted: Bool { outcome == "submitted" || outcome == "submitted_email" }
    public var wasEmailed: Bool { outcome == "emailed" }
}

/// Sends opt-out requests automatically for the sites whose form we found, and says plainly what it could not do.
/// Rules it keeps: it never solves a human check or accepts terms; it sends nothing to a site where a recent look found no
/// listing; it sends each site at most once per `minInterval`; and a person's details go only to forms that ask for them.
public struct AutoOptOut: Sendable {
    public static let defaultMinInterval: TimeInterval = 30 * 86_400
    private let submitter: FormSubmitter
    private let minInterval: TimeInterval
    private let spacing: TimeInterval

    public init(submitter: FormSubmitter, minInterval: TimeInterval = AutoOptOut.defaultMinInterval, spacing: TimeInterval = 2) {
        self.submitter = submitter; self.minInterval = minInterval; self.spacing = spacing
    }

    /// Decides what to do for one site without touching the network. Nil means "go ahead and submit" with this plan.
    public static func precheck(entry: DirectoryEntry, person: Person, progress: Progress, now: Date,
                                minInterval: TimeInterval = defaultMinInterval, hold: PlatformHold? = nil,
                                period: RunPeriod? = nil) -> (result: AutoOptOutResult?, plan: FillPlan?) {
        guard let form = entry.optOutForm else { return (.needsYou(L10n.t("No opt-out form found for this site yet.")), nil) }
        if let hold, now < hold.until { return (.coveredByPlatform(name: hold.name, until: hold.until), nil) }
        if let issue = progress.activeIssue(for: entry.id, now: now) {
            return (.needsYou(L10n.f("You marked this site as not working (%@).", issue.kind.label.lowercased())), nil)
        }
        if let last = progress.optOutAttempts[entry.id]?.filter(\.wasSubmitted).map(\.date).max() {
            // Inside a run period, a site that already went through in it is handled: every run in the period leaves it alone, and the next period starts afresh.
            if let period { if period.contains(last) { return (.tooSoon(until: period.end), nil) } }
            else if now.timeIntervalSince(last) < minInterval { return (.tooSoon(until: last.addingTimeInterval(minInterval)), nil) }
        }
        // Do not hand details to a site a recent look says does not hold them.
        if let look = progress.latestSiteCheck(entry.id), look.result == .removed, now.timeIntervalSince(look.date) < 30 * 86_400 {
            return (.skippedNotListed, nil)
        }
        if form.fields.isEmpty, entry.liveForm?.found == true { return (nil, FillPlan(values: [], verdict: .ready)) }        // the live page decides what is filled
        let plan = FormFiller.plan(for: form, signals: entry.signals, person: person)
        switch plan.verdict {
        case .ready: return (nil, plan)
        case .needsData(let what): return (.needsData(what), plan)
        case .needsYou(let why): return (.needsYou(why), plan)
        }
    }

    /// Whether the background run may try a site with nobody watching: the app fills the form and presses send itself, and counts the site done only when it sees the
    /// confirmation. Only a site whose form is known and has nothing only a person can do: not a caution or `no_fill` site, business, agent, other or file forms, a typed
    /// code, a form that needs the person's own listing, or one that needs something only the person holds; and not a site the person set aside. A human check, terms
    /// prompt or box to certify that a page shows is never solved or ticked: the engine stops there and the site goes to the person's semi-automated queue.
    public static func backgroundAttemptable(_ entry: DirectoryEntry, person: Person, progress: Progress, now: Date = Date()) -> Bool {
        guard entry.pageMode == .form else { return false }
        if progress.isParked(entry.id, now: now) { return false }
        if let form = entry.optOutForm {
            if FormFiller.hasTypedCode(form) || FormFiller.needsListing(form) { return false }
            if !form.fields.isEmpty, FormFiller.plan(for: form, signals: entry.signals, person: person).verdict != .ready { return false }
        } else if entry.liveForm?.found != true { return false }
        return true
    }

    /// Whether the site's latest attempt went through (a form was sent).
    public static func lastAttemptWentThrough(_ entry: DirectoryEntry, progress: Progress) -> Bool {
        progress.optOutAttempts[entry.id]?.last?.wasSubmitted ?? false
    }

    /// The sites one kind of background run works through: the full pass tries every site that can be tried; the repeat pass only the ones whose latest attempt went through.
    public static func backgroundSites(_ kind: RunKind, entries: [DirectoryEntry], person: Person, progress: Progress, now: Date = Date()) -> [DirectoryEntry] {
        entries.filter { e in
            guard backgroundAttemptable(e, person: person, progress: progress, now: now) else { return false }
            return kind == .full || lastAttemptWentThrough(e, progress: progress)
        }
    }

    /// The sites still to do this period: those with no request sent in `period` (all of them before the first period has started). "Run now" works through
    /// these, so a site already sent this period is not sent again; one that is due again, or did not go through, is tried.
    public static func notSent(in period: RunPeriod?, _ entries: [DirectoryEntry], progress: Progress) -> [DirectoryEntry] {
        guard let period else { return entries }
        return entries.filter { e in !(progress.optOutAttempts[e.id]?.contains { $0.wasSubmitted && period.contains($0.date) } ?? false) }
    }

    /// Runs the opt-out for every site with a form, one at a time. `dryRun` fills forms but never sends them.
    public func run(entries: [DirectoryEntry], person: Person, progress: Progress, now: Date = Date(), dryRun: Bool = false,
                    holds: [String: PlatformHold] = [:], progressCallback: (@Sendable (Int, Int) -> Void)? = nil,
                    evidence: (@Sendable (DirectoryEntry, Data) -> Void)? = nil,
                    period: RunPeriod? = nil,
                    onResult: (@Sendable (DirectoryEntry, AutoOptOutResult) async -> Void)? = nil,
                    shouldStop: (@Sendable () async -> Bool)? = nil) async -> [(DirectoryEntry, AutoOptOutResult)] {
        // Forms read from the page, and forms found on the live page (a stand-in form carries the page; the live run decides what is filled).
        func standIn(_ e: DirectoryEntry) -> DirectoryEntry {
            guard e.optOutForm == nil, let page = e.liveForm?.page.flatMap(URL.init(string:)), e.liveForm?.found == true else { return e }
            var copy = e; copy.optOutForm = OptOutForm(page: page, method: "post", action: nil, fields: [], hops: 1); return copy
        }
        let targets = entries.map(standIn).filter { $0.optOutForm != nil }
        var out: [(DirectoryEntry, AutoOptOutResult)] = []
        // Sites that share one opt-out page (a family) are sent once; the others get the same result and picture.
        var sent: [String: (AutoOptOutResult, Data?)] = [:]
        for (i, entry) in targets.enumerated() {
            // The app is about to be suspended or closed: stop between sites, so what is done is kept and the rest waits for the next run.
            if await shouldStop?() == true { break }
            let pre = Self.precheck(entry: entry, person: person, progress: progress, now: now, minInterval: minInterval, hold: holds[entry.id], period: period)
            if let result = pre.result { out.append((entry, result)); await onResult?(entry, result) }
            else if let plan = pre.plan, let form = entry.optOutForm {
                let key = form.page.absoluteString + "|" + (form.action?.absoluteString ?? "")
                if let again = sent[key] {
                    out.append((entry, again.0))
                    if let shot = again.1, !dryRun { evidence?(entry, shot) }
                    await onResult?(entry, again.0)
                    progressCallback?(i + 1, targets.count)
                    continue
                }
                let report = await submitter.submitCapturing(form, plan: plan, dryRun: dryRun)
                if let shot = report.screenshot, !dryRun { evidence?(entry, shot) }
                let result = Self.result(for: report.outcome)
                sent[key] = (result, report.screenshot)
                out.append((entry, result))
                await onResult?(entry, result)          // kept right away: closing the app now must not lose a request that was already sent
                if spacing > 0 { try? await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000)) }
            }
            progressCallback?(i + 1, targets.count)
        }
        return out
    }

    /// What a site that answers "Too many requests" is reported as: not a failure of the form, so nothing is recorded against the site and it stays to try again.
    public static let rateLimited = "the site said too many requests; wait a few minutes and try it again"

    public static func result(for outcome: SubmitOutcome) -> AutoOptOutResult {
        switch outcome {
        case .submitted(let email): return .submitted(awaitingEmail: email)
        case .filledNotSubmitted: return .dryRunReady
        case .challenged(let why): return .challenged(why)
        case .rejected(let why): return .rejected(why)
        case .failed(let why): return why == rateLimited ? .needsYou(why) : .failed(why)
        }
    }

    /// The attempts worth remembering: only ones that reached the site. Skips and "needs you" are recomputed each run.
    public static func attempt(for result: AutoOptOutResult, now: Date) -> OptOutAttempt? {
        switch result {
        case .submitted(let email): return OptOutAttempt(date: now, outcome: email ? "submitted_email" : "submitted")
        // The form did not go through and the person emailed the site instead: the request was made, so the site counts as done.
        case .emailed: return OptOutAttempt(date: now, outcome: "submitted", detail: "sent by email instead")
        case .challenged(let why): return OptOutAttempt(date: now, outcome: "challenged", detail: why)
        case .rejected(let why): return OptOutAttempt(date: now, outcome: "rejected", detail: why)
        case .failed(let why): return OptOutAttempt(date: now, outcome: "failed", detail: why)
        default: return nil
        }
    }
}

public extension Progress {
    mutating func recordOptOutAttempt(_ attempt: OptOutAttempt, site: String) { optOutAttempts[site, default: []].append(attempt) }
}

/// When the background jobs are due, and what the person agreed to. Stored with the household.
public struct AutoSettings: Codable, Equatable, Sendable {
    public var decidedAt: Date?             // nil until the person has answered the first-run question
    public var scanEnabled = false
    public var optOutEnabled = false
    public var lastScan: Date?
    public var lastOptOut: Date?
    /// What the last opt-out run did, so the result can still be seen after the app is closed.
    public var lastAttempted: Int?          // sites it actually tried
    public var lastSent: Int?
    public var lastNeedYou: Int?
    /// An opt-out run was started and has not finished (the app was closed or suspended): the next time the app is open it carries on with the sites left.
    public var optOutResumePending: Bool?
    /// When the first opt-out run started: periods (months) are counted from here, so each month's tally is comparable.
    public var periodAnchor: Date?
    /// The sites the automatic run has taken on, per person. A site that fails moves out of the automatic group, but it stays here, so the
    /// "handled of total" and the checklist keep showing it (unchecked) in every period until it goes through.
    public var periodTargets: [String: [String]]?
    /// When the last full pass over every site finished; nil until the first one has.
    public var lastFullRun: Date?
    /// A pass that was started and has not finished (the app was closed): when it began and which kind it is, so it carries on with the sites it has not yet tried.
    public var passStarted: Date?
    public var passKind: RunKind?

    public static let scanEvery: TimeInterval = 86_400            // daily
    public static let optOutEvery: TimeInterval = 91 * 86_400     // every three months
    /// A full re-test of every site comes every second period (about six months).
    public static let fullEvery: TimeInterval = 2 * optOutEvery

    public init() {}

    public func scanDue(now: Date) -> Bool { scanEnabled && (lastScan.map { now.timeIntervalSince($0) >= Self.scanEvery } ?? true) }
    public func optOutDue(now: Date) -> Bool {
        guard optOutEnabled else { return false }
        guard let last = lastOptOut else { return true }
        // Due once a new period has begun that no run has been in yet.
        if let periodAnchor { return last < RunPeriod.containing(now, anchor: periodAnchor).start }
        return now.timeIntervalSince(last) >= Self.optOutEvery
    }
    public mutating func addPeriodTargets(_ ids: [String], person: String) {
        var all = periodTargets?[person] ?? []
        for id in ids where !all.contains(id) { all.append(id) }
        var map = periodTargets ?? [:]; map[person] = all; periodTargets = map
    }
    public func periodTargetIDs(person: String) -> [String] { periodTargets?[person] ?? [] }
    /// The next period's start: when the next monthly run is due.
    public func nextOptOutDate(now: Date = Date()) -> Date? {
        guard let periodAnchor else { return lastOptOut?.addingTimeInterval(Self.optOutEvery) }
        return RunPeriod.containing(now, anchor: periodAnchor).end
    }
    /// The kind of the next run: a full pass the first time and then every six months, otherwise a repeat of what went through.
    public func nextRunKind(now: Date = Date()) -> RunKind {
        if let passKind, passStarted != nil { return passKind }
        guard let lastFullRun else { return .full }
        return now >= lastFullRun.addingTimeInterval(Self.fullEvery - 3 * 86_400) ? .full : .repeatSent
    }
    /// A new person's first automatic pass has not finished yet. Until it has, the app does not know which sites need a person, so the semi-automated
    /// queue waits for it. Only the very first pass: a later run (or a re-test by hand) never hides the queue.
    public var firstPassPending: Bool { optOutEnabled && lastOptOut == nil }

    /// The person asked to re-test every site now. A full pass already under way just carries on; anything else (nothing running, or a repeat pass) becomes a fresh full pass.
    public mutating func startFullRetest(now: Date = Date()) {
        if passStarted != nil, passKind == .full { return }
        passStarted = now; passKind = .full; optOutResumePending = true
    }
    /// The kind of the run due on `date` (the next period's start), for saying what is coming.
    public func kindOfRun(on date: Date) -> RunKind { nextRunKind(now: date) }
    public var hasDecided: Bool { decidedAt != nil }

    /// Turns both on at the person's first-run approval. Either can be switched off later.
    public mutating func turnOnBoth(now: Date = Date()) { decidedAt = now; scanEnabled = false; optOutEnabled = true }       // nothing scans yet, so only the opt-out turns on
    public mutating func declineForNow(now: Date = Date()) { decidedAt = now; scanEnabled = false; optOutEnabled = false }
}
