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
    case notListed                        // the site's own search, run by its form, found no record of the person: nothing there to opt out of
}

/// Fills in and sends one site's opt-out form. The app backs it with its hidden web view; tests use fakes.
public protocol FormSubmitter: Sendable {
    func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome
    /// The same, and a screenshot of what the page showed when it finished (the confirmation, or what stopped it), as JPEG data.
    func submitCapturing(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitEvidence
    /// The same, calling `activity` whenever the page shows a sign of life (a load starting or finishing, the page changing, a request it made coming
    /// back). The run gives up on a site that shows none for `AutoOptOut.idleLimit`.
    func submitCapturing(_ form: OptOutForm, plan: FillPlan, dryRun: Bool, activity: @escaping @Sendable () -> Void) async -> SubmitEvidence
    /// The same, and when the run gives the site up after its form was sent, the submitter hands what its page showed at that moment (its text and a
    /// screenshot) to `giveUp` before it closes the page, so a site that never confirms still leaves something to look at.
    func submitCapturing(_ form: OptOutForm, plan: FillPlan, dryRun: Bool, activity: @escaping @Sendable () -> Void, giveUp: GiveUpCapture) async -> SubmitEvidence
    /// Whether this submitter reports the page's signs of life (so the idle limit applies).
    var reportsActivity: Bool { get }
}

/// What a site's page showed when the run gave the site up after sending its form: filled in by the submitter as it is cancelled, read by the run.
public final class GiveUpCapture: @unchecked Sendable {
    private let lock = NSLock(); private var evidence: SubmitEvidence?, taker: (@Sendable () async -> SubmitEvidence?)?
    public init() {}
    public func set(_ e: SubmitEvidence) { lock.lock(); if evidence == nil { evidence = e }; lock.unlock() }
    /// How the submitter reads its page now (text and screenshot). The run calls it before it cancels the site's work: once cancelled, the work closes its page
    /// and nothing is left to read (quad.com was given up after sending with neither its words nor a screenshot).
    public func whenGivingUp(_ take: @escaping @Sendable () async -> SubmitEvidence?) { lock.lock(); taker = take; lock.unlock() }
    /// Reads the page with `whenGivingUp`'s reader, for at most `seconds`.
    func takeNow(within seconds: TimeInterval) async {
        lock.lock(); let take = taker; lock.unlock()
        guard let take else { return }
        let got: SubmitEvidence? = await withTaskGroup(of: SubmitEvidence?.self) { group in
            group.addTask { await take() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let got { set(got) }
    }
    /// What was captured, waiting up to `seconds` for it (the page is read and photographed while the site is being given up).
    public func wait(upTo seconds: TimeInterval) async -> SubmitEvidence? {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if let e = current { return e }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return current
    }
    private var current: SubmitEvidence? { lock.lock(); defer { lock.unlock() }; return evidence }
}

/// How each site's form is filled for one person, worked out once and kept. Working it out is the slow part of deciding which sites a run tries (about a
/// millisecond a form, for some 800 sites, several times over), and it depends only on the form and the person, not on what was sent. Build 47 worked it
/// out again for every site each time the automatic opt-out page refreshed, which took seconds and made the app slow during a run.
public final class FillPlans: @unchecked Sendable {
    public let person: Person
    private let lock = NSLock(); private var plans: [String: FillPlan] = [:]
    public init(person: Person) { self.person = person }
    public func plan(_ entry: DirectoryEntry, _ form: OptOutForm) -> FillPlan {
        let key = entry.id + "|" + form.page.absoluteString + "|" + (form.action?.absoluteString ?? "") + "|\(form.fields.count)"
        lock.lock(); if let p = plans[key] { lock.unlock(); return p }; lock.unlock()
        let p = FormFiller.plan(for: form, signals: entry.signals, person: person)
        lock.lock(); plans[key] = p; lock.unlock()
        return p
    }
}

/// Lets exactly one of several racing tasks go on (see `AutoOptOut.within`).
final class FirstOnce: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

public struct SubmitEvidence: Sendable {
    public var outcome: SubmitOutcome
    public var screenshot: Data?
    /// What the page said at the end: the text that appeared after sending (the confirmation, the error), or, when nothing was sent, the text on screen.
    public var pageText: String?
    public init(outcome: SubmitOutcome, screenshot: Data? = nil, pageText: String? = nil) { self.outcome = outcome; self.screenshot = screenshot; self.pageText = pageText }
}

public extension FormSubmitter {
    func submitCapturing(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitEvidence {
        SubmitEvidence(outcome: await submit(form, plan: plan, dryRun: dryRun))
    }
    /// A submitter that has no page to watch reports nothing; it is held only to the overall limit, not the idle one.
    func submitCapturing(_ form: OptOutForm, plan: FillPlan, dryRun: Bool, activity: @escaping @Sendable () -> Void) async -> SubmitEvidence {
        await submitCapturing(form, plan: plan, dryRun: dryRun)
    }
    /// A submitter that cannot read its page when it is given up has nothing to hand over.
    func submitCapturing(_ form: OptOutForm, plan: FillPlan, dryRun: Bool, activity: @escaping @Sendable () -> Void, giveUp: GiveUpCapture) async -> SubmitEvidence {
        await submitCapturing(form, plan: plan, dryRun: dryRun, activity: activity)
    }
    /// Whether this submitter reports the page's signs of life (so the idle limit applies).
    var reportsActivity: Bool { false }
}

/// The last sign of life from a site's page, shared between the work and its watchdog, and whether its form has been sent yet.
final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock(); private var last = Date(); private var sentAt: Date?
    func touch() { lock.lock(); last = Date(); lock.unlock() }
    func markSent() { lock.lock(); if sentAt == nil { sentAt = Date() }; last = Date(); lock.unlock() }
    var quietFor: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
    var sent: Bool { lock.lock(); defer { lock.unlock() }; return sentAt != nil }
}

/// What the work of one background-run site tells its watchdog beyond signs of life. The app's page code calls `markSent` the moment it presses a form's
/// send button, so a site given up after that is not recorded as never sent (it may well have gone through) and is never sent again in the same pass.
/// Outside a background run (Solve and send, guides) nothing is listening and the call does nothing.
public enum SiteRun {
    @TaskLocal public static var markSent: (@Sendable () -> Void)?
    /// When the run gives this site up (`AutoOptOut.siteLimit` from its start). The page code waits after sending only as long as leaves `readReserve`, so it
    /// still reads what the page said and takes its screenshot: build 49 waited the full time and was cut off first, so many sites ended "sent, not confirmed"
    /// with nothing to show. Nil outside a background run (Solve and send waits as long as it likes).
    @TaskLocal public static var deadline: Date?
    /// The time kept for reading the page and taking the screenshot once the waiting is over.
    public static let readReserve: TimeInterval = 5
    /// How long a step may still wait, given at most `upTo`: what is left before the deadline less the reserve (never below zero), or `upTo` outside a run.
    public static func wait(upTo: TimeInterval, now: Date = Date()) -> TimeInterval {
        guard let deadline else { return upTo }
        return max(0, min(upTo, deadline.timeIntervalSince(now) - readReserve))
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
    case notListed                     // the site's form searched for the person and found no record: done until `notListedWindow` ends, then searched again

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
        case .notListed: return L10n.t("Not listed: the site found no record of you")
        }
    }
}

public struct OptOutAttempt: Codable, Equatable, Sendable {
    public var date: Date
    public var outcome: String           // "submitted", "submitted_email", "challenged", "rejected", "failed"
    public var detail: String?
    /// What the page said at the end (`AutoOptOut.pageSaid`): the confirmation or error that appeared after sending, or the text on screen when nothing was sent.
    /// Kept on the device only, with the rest of the history (it can hold the person's own details, as the page showed them).
    public var pageSaid: String?
    public init(date: Date, outcome: String, detail: String? = nil, pageSaid: String? = nil) { self.date = date; self.outcome = outcome; self.detail = detail; self.pageSaid = pageSaid }
    /// A form was sent to the site. Emailing a request is tracked separately (`outcome == "emailed"`), so one never stands in for the other.
    public var wasSubmitted: Bool { outcome == "submitted" || outcome == "submitted_email" }
    public var wasEmailed: Bool { outcome == "emailed" }
    /// The site's form searched for the person and found no record (`SubmitOutcome.notListed`). Not a send.
    public static let notListedOutcome = "not_listed"
    public var wasNotListed: Bool { outcome == Self.notListedOutcome }
}

/// Sends opt-out requests automatically for the sites whose form we found, and says plainly what it could not do.
/// Rules it keeps: it never solves a human check or accepts terms; it sends nothing to a site where a recent look found no
/// listing; it sends each site at most once per `minInterval`; and a person's details go only to forms that ask for them.
public struct AutoOptOut: Sendable {
    public static let defaultMinInterval: TimeInterval = 30 * 86_400
    private let submitter: FormSubmitter
    private let minInterval: TimeInterval
    private let spacing: TimeInterval
    /// The most one site may take, from loading its page to the screenshot. A page can wedge a step that has no limit of its own (a script that never
    /// answers, a snapshot that never comes back); without this the whole run waited on that one site for ever.
    private let siteLimit: TimeInterval
    /// The most a site's page may go without any sign of life before the site is given up and moved to semi-automatic.
    private let idleLimit: TimeInterval
    /// How many sites are worked on at once. Each is a different site, so no site sees more than one request at a time; the time a run takes is
    /// mostly waiting on pages, so three at once take about a third of the time.
    private let parallel: Int

    public init(submitter: FormSubmitter, minInterval: TimeInterval = AutoOptOut.defaultMinInterval, spacing: TimeInterval = 2, siteLimit: TimeInterval = AutoOptOut.siteLimit,
                idleLimit: TimeInterval = AutoOptOut.idleLimit, parallel: Int = 1) {
        self.submitter = submitter; self.minInterval = minInterval; self.spacing = spacing; self.siteLimit = siteLimit; self.idleLimit = idleLimit
        self.parallel = max(1, parallel)
    }

    /// How many sites the app's run works on at once: one. The app staying quick matters more than how long a run takes, and every page a run has open
    /// shares the main thread and the processor with the screens the person is using.
    public static let appParallel = 1

    /// Fifteen seconds with no sign of life from the page: no load starting or finishing, no change on the page, no request of its own coming back.
    public static let idleLimit: TimeInterval = 15
    /// What a site whose page went quiet is recorded as. It counts as not gone through, so it moves to the semi-automated queue.
    public static let wentQuiet = "the site stopped answering, so it moved to semi-automatic"

    /// Runs one site's work, giving it up (nil) when `idle` seconds pass with no `touch`, or `cap` seconds in all. `idle` nil: only the cap applies.
    /// `sent`: the work had pressed send (`SiteRun.markSent`) before it was given up. The given-up work is cancelled (the app closes that site's web pages
    /// when it sees the cancel) but not waited for: a step stuck waiting on a page may not notice, so the run must not wait for it. Left running, given-up
    /// pages piled up in memory until iOS closed the app.
    public static func watched<T: Sendable>(idle: TimeInterval?, cap: TimeInterval,
                                            capture: GiveUpCapture? = nil,
                                            _ work: @escaping @Sendable (_ touch: @escaping @Sendable () -> Void) async -> T) async -> (value: T?, quiet: Bool, sent: Bool) {
        let once = FirstOnce(), clock = ActivityClock(), start = Date()
        return await withCheckedContinuation { (c: CheckedContinuation<(value: T?, quiet: Bool, sent: Bool), Never>) in
            let worker = Task {
                let value = await SiteRun.$deadline.withValue(start.addingTimeInterval(cap)) {
                    await SiteRun.$markSent.withValue({ clock.markSent() }) { await work({ clock.touch() }) }
                }
                if once.claim() { c.resume(returning: (value, false, clock.sent)) }
            }
            Task {
                while true {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    // Given up after sending: the page is read first (its words and a screenshot), and only then is the work cancelled.
                    if let idle, clock.quietFor >= idle { if once.claim() { if clock.sent { await capture?.takeNow(within: 6) }; worker.cancel(); c.resume(returning: (nil, true, clock.sent)) }; return }
                    if Date().timeIntervalSince(start) >= cap { if once.claim() { if clock.sent { await capture?.takeNow(within: 6) }; worker.cancel(); c.resume(returning: (nil, false, clock.sent)) }; return }
                }
            }
        }
    }

    /// What a given-up site is recorded as: after its form was sent, that it was sent and not confirmed (never sent again in this pass, and the person is told
    /// it may have gone through); before, that it went quiet or took too long (tried once more at the end of the pass).
    static func givenUp(quiet: Bool, sent: Bool) -> SubmitOutcome {
        if sent { return .failed(sentUnconfirmed) }
        return .failed(quiet ? wentQuiet : tooSlow)
    }

    /// A site given up after its form was sent: the site may have taken it, so it is not sent again by the run; the person checks it in the semi-automated queue.
    public static let sentUnconfirmed = "the form was sent, but the site did not confirm it in time; check it before sending again"

    /// Whether a result is a give-up before anything was sent (the page went quiet or ran out of time), which the run tries once more at the end of the pass.
    static func gaveUpBeforeSending(_ result: AutoOptOutResult) -> Bool { result == .failed(wentQuiet) || result == .failed(tooSlow) }

    /// Forms read from the page, and forms found on the live page (a stand-in form carries the page; the live run decides what is filled).
    public static func standIn(_ e: DirectoryEntry) -> DirectoryEntry {
        guard e.optOutForm == nil, let page = e.liveForm?.page.flatMap(URL.init(string:)), e.liveForm?.found == true else { return e }
        var copy = e; copy.optOutForm = OptOutForm(page: page, method: "post", action: nil, fields: [], hops: 1); return copy
    }

    /// How close together "Re-test all" may send to one site: no gap. The person asked for every site again and confirmed it, so a site sent earlier
    /// the same day is sent again too (a run never sends one page twice: sites that share a page are sent once).
    public static let retestMinInterval: TimeInterval = 0

    /// 60 seconds (decided 2026-11-23): a slow broker page on a phone's connection has time to load, be filled and show its answer, and the run still settles
    /// a site at least every 62 seconds (`progressEvery`). A page that is stuck rather than slow is given up sooner by `idleLimit` (no sign of life for 15
    /// seconds). It was two and a half minutes until build 48, then 28 seconds, which cut off slow pages that were still working ("the site took too long").
    public static let siteLimit: TimeInterval = 60
    /// The longest a run goes without settling a site: the site limit and the pause after it.
    public static let progressEvery: TimeInterval = 62
    /// What a site that ran out of time is recorded as. It counts as not gone through, so it moves to the semi-automated queue.
    public static let tooSlow = "the site took too long to answer, so the run moved on"

    /// The work's result, or nil when `seconds` pass first. The work is left to finish (or not) on its own: a step stuck waiting on a page cannot be
    /// cancelled, so the run must not wait for it.
    public static func within<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async -> T) async -> T? {
        let once = FirstOnce()
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            let worker = Task { let value = await work(); if once.claim() { c.resume(returning: value) } }
            Task { try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)); if once.claim() { worker.cancel(); c.resume(returning: nil) } }
        }
    }

    /// Decides what to do for one site without touching the network. Nil means "go ahead and submit" with this plan.
    public static func precheck(entry: DirectoryEntry, person: Person, progress: Progress, now: Date,
                                minInterval: TimeInterval = defaultMinInterval, hold: PlatformHold? = nil,
                                period: RunPeriod? = nil, plans: FillPlans? = nil) -> (result: AutoOptOutResult?, plan: FillPlan?) {
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
        if progress.notListedRecently(entry.id, now: now) { return (.skippedNotListed, nil) }
        if form.fields.isEmpty, entry.liveForm?.found == true { return (nil, FillPlan(values: [], verdict: .ready)) }        // the live page decides what is filled
        let plan = plans?.plan(entry, form) ?? FormFiller.plan(for: form, signals: entry.signals, person: person)
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
    public static func backgroundAttemptable(_ entry: DirectoryEntry, person: Person, progress: Progress, now: Date = Date(), plans: FillPlans? = nil) -> Bool {
        guard entry.pageMode == .form else { return false }
        if progress.isParked(entry.id, now: now) { return false }
        if let form = entry.optOutForm {
            if FormFiller.hasTypedCode(form) || FormFiller.needsListing(form) { return false }
            if !form.fields.isEmpty, (plans?.plan(entry, form) ?? FormFiller.plan(for: form, signals: entry.signals, person: person)).verdict != .ready { return false }
        } else if entry.liveForm?.found != true { return false }
        return true
    }

    /// Whether the site's latest attempt went through (a form was sent).
    public static func lastAttemptWentThrough(_ entry: DirectoryEntry, progress: Progress) -> Bool {
        progress.optOutAttempts[entry.id]?.last?.wasSubmitted ?? false
    }

    /// Whether the site's latest attempt was given up before anything was sent (the page went quiet or ran out of time): the site was never really tried, so it is
    /// not left for the next full pass. Build 48 gave up on many sites that way (its waits used up the time), and they sat in the semi-automated queue for six months.
    public static func lastAttemptGaveUpBeforeSending(_ entry: DirectoryEntry, progress: Progress) -> Bool {
        guard let last = progress.optOutAttempts[entry.id]?.last, last.outcome == "failed" else { return false }
        return last.detail == wentQuiet || last.detail == tooSlow
    }

    /// The sites a repeat pass (and "Run now" after a full pass) takes on: those whose latest attempt went through, and those whose latest attempt was given up
    /// before anything was sent. Not one stopped by a check, refused, or sent and not confirmed: those wait for the person or the next full pass.
    public static func inRepeatPass(_ entry: DirectoryEntry, progress: Progress) -> Bool {
        (progress.optOutAttempts[entry.id]?.last?.wasNotListed ?? false)          // searched again once `notListedWindow` is over (`precheck` holds it until then)
            || lastAttemptWentThrough(entry, progress: progress) || lastAttemptGaveUpBeforeSending(entry, progress: progress) || sentUnconfirmedOnce(entry, progress: progress)
    }

    /// The site's latest attempt was sent and not confirmed in time, and the one before was not: it gets one more try, which now reads the page before its time
    /// is up (`SiteRun.deadline`). Sending an opt-out a second time does no harm; a second unconfirmed send is left for the person, so it is never sent over and over.
    public static func sentUnconfirmedOnce(_ entry: DirectoryEntry, progress: Progress) -> Bool {
        let list = progress.optOutAttempts[entry.id] ?? []
        guard let last = list.last, last.outcome == "failed", last.detail == sentUnconfirmed else { return false }
        let before = list.dropLast().last
        return !(before?.outcome == "failed" && before?.detail == sentUnconfirmed)
    }

    /// The sites one kind of background run works through: the full pass tries every site that can be tried; the repeat pass the ones `inRepeatPass` takes.
    public static func backgroundSites(_ kind: RunKind, entries: [DirectoryEntry], person: Person, progress: Progress, now: Date = Date(), plans: FillPlans? = nil) -> [DirectoryEntry] {
        entries.filter { e in
            guard backgroundAttemptable(e, person: person, progress: progress, now: now, plans: plans) else { return false }
            return kind == .full || inRepeatPass(e, progress: progress)
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
                    onResult: (@Sendable (DirectoryEntry, AutoOptOutResult, String?) async -> Void)? = nil,
                    shouldStop: (@Sendable () async -> Bool)? = nil) async -> [(DirectoryEntry, AutoOptOutResult)] {
        let targets = entries.map(Self.standIn).filter { $0.optOutForm != nil }
        var out: [(index: Int, entry: DirectoryEntry, result: AutoOptOutResult)] = []
        // Sites that share one opt-out page (a family) are sent once; the others get the same result and picture. One whose page is being sent
        // right now waits for that send's result.
        var sent: [String: (AutoOptOutResult, Data?, String?)] = [:]
        var waiting: [String: [Int]] = [:]
        // Pages given up before anything was sent: each is tried once more after every other site, with the sites that share it.
        var retry: [(key: String, indices: [Int], form: OptOutForm, plan: FillPlan)] = []
        var done = 0, total = targets.count
        let submitter = self.submitter, idle = submitter.reportsActivity ? idleLimit : nil, cap = siteLimit, spacing = self.spacing
        func record(_ i: Int, _ result: AutoOptOutResult, shot: Data?, said: String? = nil) async {
            let entry = targets[i]
            out.removeAll { $0.index == i }          // a site tried again keeps only its last result
            out.append((i, entry, result))
            if let shot, !dryRun { evidence?(entry, shot) }
            await onResult?(entry, result, said)          // kept right away: closing the app now must not lose a request that was already sent
        }
        func advance() { done += 1; progressCallback?(done, total) }
        let attempt: @Sendable (OptOutForm, FillPlan) async -> SubmitEvidence = { form, plan in
            let capture = GiveUpCapture()
            let watched = await Self.watched(idle: idle, cap: cap, capture: capture) { touch in
                await submitter.submitCapturing(form, plan: plan, dryRun: dryRun, activity: touch, giveUp: capture)
            }
            if let value = watched.value { return value }
            var given = SubmitEvidence(outcome: Self.givenUp(quiet: watched.quiet, sent: watched.sent))
            // A site given up after its form was sent keeps what its page showed then (its words and a screenshot), so the person can see why it is not confirmed.
            if watched.sent, !dryRun, let seen = await capture.wait(upTo: 5) { given.screenshot = seen.screenshot; given.pageText = seen.pageText }
            return given
        }
        var plans: [String: (OptOutForm, FillPlan)] = [:]
        await withTaskGroup(of: (Int, String, SubmitEvidence).self) { group in
            var inFlight = 0, launched = 0
            func collect() async {
                guard let (i, key, report) = await group.next() else { return }
                inFlight -= 1
                let result = Self.result(for: report.outcome)
                sent[key] = (result, report.screenshot, report.pageText)
                let sharers = [i] + (waiting.removeValue(forKey: key) ?? [])
                // Its second try is a step of the run from now on, so the count never reads finished before the end.
                if Self.gaveUpBeforeSending(result), let (form, plan) = plans[key] { retry.append((key, sharers, form, plan)); total += 1 }
                for j in sharers { await record(j, result, shot: report.screenshot, said: report.pageText); advance() }
            }
            for (i, entry) in targets.enumerated() {
                // The app is about to be suspended or closed, or the person pressed Stop: start no more sites. The ones in progress finish, so what
                // is done is kept and the rest waits for the next run.
                if await shouldStop?() == true { break }
                let pre = Self.precheck(entry: entry, person: person, progress: progress, now: now, minInterval: minInterval, hold: holds[entry.id], period: period)
                if let result = pre.result { await record(i, result, shot: nil); advance(); continue }
                guard let plan = pre.plan, let form = entry.optOutForm else { advance(); continue }
                let key = form.page.absoluteString + "|" + (form.action?.absoluteString ?? "")
                if let again = sent[key] {
                    await record(i, again.0, shot: again.1, said: again.2); advance()
                    if Self.gaveUpBeforeSending(again.0), let r = retry.firstIndex(where: { $0.key == key }) { retry[r].indices.append(i) }
                    continue
                }
                if waiting[key] != nil { waiting[key]!.append(i); continue }
                while inFlight >= parallel { await collect() }
                // Waiting for a free lane took time: Stop may have been pressed meanwhile.
                if await shouldStop?() == true { break }
                // Requests are spaced out a little: each lane waits before its next site.
                let wait = launched >= parallel ? spacing : 0
                waiting[key] = []; plans[key] = (form, plan); inFlight += 1; launched += 1
                group.addTask {
                    if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                    return (i, key, await attempt(form, plan))
                }
            }
            while inFlight > 0 { await collect() }
        }
        // A page that went quiet or ran out of time before anything was sent is often only slow for a moment: it is tried once more, after every other site,
        // so it does not hold the others up. Each try counts as a step of the run, so the progress keeps moving.
        if !retry.isEmpty, await shouldStop?() != true {
            for item in retry {
                if await shouldStop?() == true { break }
                if spacing > 0 { try? await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000)) }
                let report = await attempt(item.form, item.plan)
                let result = Self.result(for: report.outcome)
                for j in item.indices { await record(j, result, shot: report.screenshot, said: report.pageText) }
                advance()
            }
        }
        // In the order the sites were given, whatever order they finished in.
        return out.sorted { $0.index < $1.index }.map { ($0.entry, $0.result) }
    }

    /// What a site that answers "Too many requests" is reported as: not a failure of the form, so nothing is recorded against the site and it stays to try again.
    /// The reason shown while a page says the site's search found no record of the person (`SubmitOutcome.notListed`).
    public static let noRecordFound = "the site found no record of you"

    public static let rateLimited = "the site said too many requests; wait a few minutes and try it again"

    public static func result(for outcome: SubmitOutcome) -> AutoOptOutResult {
        switch outcome {
        case .submitted(let email): return .submitted(awaitingEmail: email)
        case .filledNotSubmitted: return .dryRunReady
        case .challenged(let why): return .challenged(why)
        case .rejected(let why): return .rejected(why)
        case .failed(let why): return why == rateLimited ? .needsYou(why) : .failed(why)
        case .notListed: return .notListed
        }
    }

    /// The attempts worth remembering: only ones that reached the site. Skips and "needs you" are recomputed each run.
    public static func attempt(for result: AutoOptOutResult, now: Date, pageSaid: String? = nil) -> OptOutAttempt? {
        let said = Self.pageSaid(pageSaid)
        switch result {
        case .submitted(let email): return OptOutAttempt(date: now, outcome: email ? "submitted_email" : "submitted", pageSaid: said)
        // The form did not go through and the person emailed the site instead: the request was made, so the site counts as done.
        case .emailed: return OptOutAttempt(date: now, outcome: "submitted", detail: "sent by email instead")
        case .challenged(let why): return OptOutAttempt(date: now, outcome: "challenged", detail: why, pageSaid: said)
        case .rejected(let why): return OptOutAttempt(date: now, outcome: "rejected", detail: why, pageSaid: said)
        case .failed(let why): return OptOutAttempt(date: now, outcome: "failed", detail: why, pageSaid: said)
        // Not a send (never counted as sent), but what the site answered is kept to show on its page.
        case .notListed: return OptOutAttempt(date: now, outcome: OptOutAttempt.notListedOutcome, pageSaid: said)
        default: return nil
        }
    }

    /// The most of a page's text kept with an attempt: enough for a confirmation or an error message, not the whole page.
    public static let pageSaidLimit = 400

    /// A page's text as kept with an attempt: lines trimmed, blank ones dropped, at most `pageSaidLimit` characters (cut at a word, with "…"); nil when empty.
    public static func pageSaid(_ text: String?) -> String? {
        guard let text else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let joined = lines.joined(separator: "\n")
        guard !joined.isEmpty else { return nil }
        if joined.count <= pageSaidLimit { return joined }
        var cut = String(joined.prefix(pageSaidLimit))
        if let space = cut.lastIndex(where: { $0 == " " || $0 == "\n" }), cut.distance(from: cut.startIndex, to: space) > pageSaidLimit / 2 { cut = String(cut[..<space]) }
        return cut + "…"
    }
}

public extension Progress {
    mutating func recordOptOutAttempt(_ attempt: OptOutAttempt, site: String) {
        optOutAttempts[site, default: []].append(attempt)
        // The site's own search found nothing: that is a look like a scan's, so the run leaves the site alone and it counts as done (`notListedRecently`).
        if attempt.wasNotListed { recordSiteCheck(.removed, site: site, source: .automatic, on: attempt.date) }
    }
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
    /// The person pressed Stop. Nothing starts by itself again (not on opening the app, not on schedule) until they press Run now or Re-test all.
    /// Build 47 carried a stopped run on at the next opening, so Stop seemed to do nothing.
    public var stoppedByPerson: Bool?
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
    /// The pass under way is a "Re-test all": carried on after a Stop or a cut-off, it still sends again to the sites sent earlier in the period,
    /// not only to the ones never sent.
    public var passEverySite: Bool?
    /// When the run the automatic page shows began: the page lists only what this run did, so a new run never shows the last one's results. A run that is
    /// stopped or cut off and carried on is the same run. Nil before the first run (the page then shows the period, as before build 54).
    public var runStarted: Date?

    public static let scanEvery: TimeInterval = 86_400            // daily
    public static let optOutEvery: TimeInterval = 91 * 86_400     // every three months
    /// A full re-test of every site comes every second period (about six months).
    public static let fullEvery: TimeInterval = 2 * optOutEvery

    public init() {}

    public func scanDue(now: Date) -> Bool { scanEnabled && (lastScan.map { now.timeIntervalSince($0) >= Self.scanEvery } ?? true) }
    /// Whether a run starts by itself now: one is due on schedule, or a run was cut off (the app closed or suspended) and has sites left. Never after the
    /// person stopped it.
    public func startsByItself(now: Date) -> Bool {
        guard optOutEnabled, stoppedByPerson != true else { return false }
        return optOutDue(now: now) || optOutResumePending == true
    }

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
        if passStarted != nil, passKind == .full { passEverySite = true; return }
        passStarted = now; passKind = .full; optOutResumePending = true; passEverySite = true; runStarted = now
    }
    /// The kind of the run due on `date` (the next period's start), for saying what is coming.
    public func kindOfRun(on date: Date) -> RunKind { nextRunKind(now: date) }
    public var hasDecided: Bool { decidedAt != nil }

    /// Turns both on at the person's first-run approval. Either can be switched off later.
    public mutating func turnOnBoth(now: Date = Date()) { decidedAt = now; scanEnabled = false; optOutEnabled = true }       // nothing scans yet, so only the opt-out turns on
    public mutating func declineForNow(now: Date = Date()) { decidedAt = now; scanEnabled = false; optOutEnabled = false }
}
