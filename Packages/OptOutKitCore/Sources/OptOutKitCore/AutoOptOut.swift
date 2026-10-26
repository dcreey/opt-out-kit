import Foundation

public enum SubmitOutcome: Equatable, Sendable {
    case submitted(awaitingEmail: Bool)   // a success message was seen; awaitingEmail when it asks for an email confirmation
    case filledNotSubmitted               // dry run: the form was filled and left unsent
    case challenged(String)               // a visible bot check, terms prompt or similar stopped the run; never solved or accepted
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
/// Rules it keeps: it never solves a bot check or accepts terms; it sends nothing to a site where a recent look found no
/// listing; it sends each site at most once per `minInterval`; and a person's details go only to forms that ask for them.
public struct AutoOptOut: Sendable {
    public static let defaultMinInterval: TimeInterval = 7 * 86_400
    private let submitter: FormSubmitter
    private let minInterval: TimeInterval
    private let spacing: TimeInterval

    public init(submitter: FormSubmitter, minInterval: TimeInterval = AutoOptOut.defaultMinInterval, spacing: TimeInterval = 2) {
        self.submitter = submitter; self.minInterval = minInterval; self.spacing = spacing
    }

    /// Decides what to do for one site without touching the network. Nil means "go ahead and submit" with this plan.
    public static func precheck(entry: DirectoryEntry, person: Person, progress: Progress, now: Date,
                                minInterval: TimeInterval = defaultMinInterval, hold: PlatformHold? = nil) -> (result: AutoOptOutResult?, plan: FillPlan?) {
        guard let form = entry.optOutForm else { return (.needsYou(L10n.t("No opt-out form found for this site yet.")), nil) }
        if let hold, now < hold.until { return (.coveredByPlatform(name: hold.name, until: hold.until), nil) }
        if let issue = progress.activeIssue(for: entry.id, now: now) {
            return (.needsYou(L10n.f("You reported this site as not working (%@).", issue.kind.label.lowercased())), nil)
        }
        if let last = progress.optOutAttempts[entry.id]?.filter(\.wasSubmitted).map(\.date).max(), now.timeIntervalSince(last) < minInterval {
            return (.tooSoon(until: last.addingTimeInterval(minInterval)), nil)
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

    /// Runs the opt-out for every site with a form, one at a time. `dryRun` fills forms but never sends them.
    public func run(entries: [DirectoryEntry], person: Person, progress: Progress, now: Date = Date(), dryRun: Bool = false,
                    holds: [String: PlatformHold] = [:], progressCallback: (@Sendable (Int, Int) -> Void)? = nil,
                    evidence: (@Sendable (DirectoryEntry, Data) -> Void)? = nil) async -> [(DirectoryEntry, AutoOptOutResult)] {
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
            let pre = Self.precheck(entry: entry, person: person, progress: progress, now: now, minInterval: minInterval, hold: holds[entry.id])
            if let result = pre.result { out.append((entry, result)) }
            else if let plan = pre.plan, let form = entry.optOutForm {
                let key = form.page.absoluteString + "|" + (form.action?.absoluteString ?? "")
                if let again = sent[key] {
                    out.append((entry, again.0))
                    if let shot = again.1, !dryRun { evidence?(entry, shot) }
                    progressCallback?(i + 1, targets.count)
                    continue
                }
                let report = await submitter.submitCapturing(form, plan: plan, dryRun: dryRun)
                if let shot = report.screenshot, !dryRun { evidence?(entry, shot) }
                let result = Self.result(for: report.outcome)
                sent[key] = (result, report.screenshot)
                out.append((entry, result))
                if spacing > 0 { try? await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000)) }
            }
            progressCallback?(i + 1, targets.count)
        }
        return out
    }

    static func result(for outcome: SubmitOutcome) -> AutoOptOutResult {
        switch outcome {
        case .submitted(let email): return .submitted(awaitingEmail: email)
        case .filledNotSubmitted: return .dryRunReady
        case .challenged(let why): return .challenged(why)
        case .rejected(let why): return .rejected(why)
        case .failed(let why): return .failed(why)
        }
    }

    /// The attempts worth remembering: only ones that reached the site. Skips and "needs you" are recomputed each run.
    public static func attempt(for result: AutoOptOutResult, now: Date) -> OptOutAttempt? {
        switch result {
        case .submitted(let email): return OptOutAttempt(date: now, outcome: email ? "submitted_email" : "submitted")
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

    public static let scanEvery: TimeInterval = 86_400            // daily
    public static let optOutEvery: TimeInterval = 7 * 86_400      // weekly

    public init() {}

    public func scanDue(now: Date) -> Bool { scanEnabled && (lastScan.map { now.timeIntervalSince($0) >= Self.scanEvery } ?? true) }
    public func optOutDue(now: Date) -> Bool { optOutEnabled && (lastOptOut.map { now.timeIntervalSince($0) >= Self.optOutEvery } ?? true) }
    public var hasDecided: Bool { decidedAt != nil }

    /// Turns both on at the person's first-run approval. Either can be switched off later.
    public mutating func turnOnBoth(now: Date = Date()) { decidedAt = now; scanEnabled = true; optOutEnabled = true }
    public mutating func declineForNow(now: Date = Date()) { decidedAt = now; scanEnabled = false; optOutEnabled = false }
}
