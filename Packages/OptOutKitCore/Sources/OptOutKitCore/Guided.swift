import Foundation

/// One thing the person does (or the app does for them) in a guided opt-out, shown in the bottom panel.
public struct GuidedStep: Equatable, Identifiable, Sendable {
    public enum Action: Equatable, Sendable {
        case openPage(URL)
        case copy(field: String)
        case instruction
        case autofill                       // the app fills the form
        case clearBlockers                  // the person ticks a certification, accepts terms or solves a bot check
        case send                           // the app presses submit once the blockers are cleared
        case waitForEmail(subject: String?, minutes: Int?)
        case confirm
        case pickListing(search: URL)       // the person taps their own listing in the site's search results
    }

    /// How the app can tell the step is done without being told. Nil means only the Next button can say so.
    public enum Rule: Equatable, Sendable {
        case pageLoaded
        case urlChanged
        case urlContains(String)
        case textContains(String)
        case formFilled
        case blockersCleared
        case formSent
        case copied
    }

    public var id: Int
    public var title: String
    public var detail: String?
    public var action: Action
    public var rule: Rule?

    public init(id: Int, title: String, detail: String? = nil, action: Action, rule: Rule? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.action = action; self.rule = rule
    }

    public var isAutomatic: Bool { rule != nil }
}

public struct GuidedPlan: Equatable, Sendable {
    public var siteID: String
    public var siteName: String
    public var steps: [GuidedStep]
    /// True when the form is filled and sent by the app, so a confirmation email step may be added after sending.
    public var addsEmailStepAfterSend: Bool
    /// Names of the form's fields that take the address of the person's own listing, filled once they have picked it.
    public var listingFields: [String] = []
}

public enum GuidedEvent: Equatable, Sendable {
    case pageLoaded(URL?)
    case url(URL?)
    case text(String)
    case formFilled
    case blockersCleared
    case formSent(awaitingEmail: Bool)
    case copied
    case searchLanded(URL?)         // the search results finished loading; this address is the one that is NOT a listing
    case nextTapped
    case backTapped
}

/// The state of a guided flow: which step is current, which are done, and what moves it on. Pure, so it is easy to test.
public struct GuidedFlow: Equatable, Sendable {
    public private(set) var plan: GuidedPlan
    public private(set) var index = 0
    public private(set) var completed: [Int] = []          // step ids, in the order they were finished
    public private(set) var autoCompleted: Set<Int> = []   // which of them the app detected itself
    private var stepStartURL: URL?
    private var lastURL: URL?
    /// The listing the person picked, once the "tap your listing" step is done.
    public private(set) var chosenListing: URL?
    private var searchBaseline: URL?

    public init(plan: GuidedPlan) { self.plan = plan }

    /// Picks the flow up where the person left off: every step before `index` counts as done.
    public mutating func resume(at index: Int) {
        let target = max(0, min(index, plan.steps.count))
        completed = plan.steps.prefix(target).map(\.id)
        self.index = target
    }

    public var total: Int { plan.steps.count }
    public var isFinished: Bool { index >= plan.steps.count }
    public var current: GuidedStep? { plan.steps.indices.contains(index) ? plan.steps[index] : nil }
    /// "Step 2 of 5", or nil when the flow is finished.
    public var progressLabel: String? { isFinished ? nil : "Step \(index + 1) of \(total)" }

    /// Applies an event and returns the id of a step it finished, if any.
    @discardableResult
    public mutating func apply(_ event: GuidedEvent) -> Int? {
        switch event {
        case .pageLoaded(let url), .url(let url):
            lastURL = url ?? lastURL
        default: break
        }
        if case .formSent(let awaitingEmail) = event, awaitingEmail, plan.addsEmailStepAfterSend,
           !plan.steps.contains(where: { if case .waitForEmail = $0.action { return true } else { return false } }) {
            plan.steps.append(GuidedStep(id: plan.steps.count, title: "Confirm the email they sent you",
                                         detail: "Open the message and click its link. We cannot read your inbox.",
                                         action: .waitForEmail(subject: nil, minutes: nil)))
        }
        guard let step = current else { return nil }
        if case .pickListing(let search) = step.action {
            // Done only when the person says the page they are on is their listing ("This is my listing"): pages of results,
            // pagination and redirects all look alike, so the app never guesses.
            switch event {
            case .searchLanded(let u): searchBaseline = u ?? search; return nil
            case .nextTapped:
                guard Self.isListing(lastURL, searchedAt: searchBaseline ?? search) else { return nil }
                chosenListing = lastURL
                return finish(step, automatic: false)
            default: break
            }
        }
        switch event {
        case .nextTapped: return finish(step, automatic: false)
        case .backTapped:
            if index > 0 { index -= 1; completed.removeAll { $0 == plan.steps[index].id }; stepStartURL = lastURL }
            return nil
        default:
            return matches(step.rule, event) ? finish(step, automatic: true) : nil
        }
    }

    /// A page of the same site as the search results, but not the results page itself or the home page.
    public static func isListing(_ url: URL?, searchedAt search: URL) -> Bool {
        guard let url, let host = url.host, let searchHost = search.host,
              LinkRules.registrable(host) == LinkRules.registrable(searchHost) else { return false }
        func norm(_ u: URL) -> String { (u.host ?? "") + u.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "?" + (u.query ?? "") }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return !path.isEmpty && norm(url) != norm(search)
    }

    private func matches(_ rule: GuidedStep.Rule?, _ event: GuidedEvent) -> Bool {
        guard let rule else { return false }
        switch (rule, event) {
        case (.pageLoaded, .pageLoaded): return true
        case (.urlChanged, .url(let u)): return u != nil && u != stepStartURL
        case (.urlContains(let part), .url(let u)): return u?.absoluteString.contains(part) ?? false
        case (.textContains(let part), .text(let t)): return t.range(of: part, options: .caseInsensitive) != nil
        case (.formFilled, .formFilled): return true
        case (.blockersCleared, .blockersCleared): return true
        case (.formSent, .formSent): return true
        case (.copied, .copied): return true
        default: return false
        }
    }

    private mutating func finish(_ step: GuidedStep, automatic: Bool) -> Int {
        completed.append(step.id)
        if automatic { autoCompleted.insert(step.id) }
        index += 1
        stepStartURL = lastURL
        return step.id
    }
}

public enum GuidedPlanner {
    /// A guided walk through a hand-written broker flow (brokers/*.yml).
    public static func plan(for broker: Broker) -> GuidedPlan {
        var steps: [GuidedStep] = []
        for (i, s) in broker.steps.enumerated() {
            let rule = rule(for: s.doneWhen)
            if let url = s.open {
                steps.append(GuidedStep(id: i, title: "Open \(url.host ?? "the site")", action: .openPage(url), rule: .pageLoaded))
            } else if let field = s.copy {
                steps.append(GuidedStep(id: i, title: "Copy your \(Describe.field(field).lowercased())", detail: "Tap Copy, then paste it into the form. It is cleared from the clipboard after a minute.", action: .copy(field: field), rule: .copied))
            } else if let w = s.waitForEmail {
                var detail = "Open the email and click its link. We cannot read your inbox."
                if let subject = w.subject { detail = "Look for an email titled \"\(subject)\". " + detail }
                if let m = w.withinMinutes { detail += " The link expires in \(m) minutes." }
                steps.append(GuidedStep(id: i, title: "Confirm the email they send you", detail: detail,
                                        action: .waitForEmail(subject: w.subject, minutes: w.withinMinutes)))
            } else if let m = s.searchMatch {
                steps.append(GuidedStep(id: i, title: "Find your listing", detail: m, action: .instruction, rule: rule))
            } else if let say = s.say {
                steps.append(GuidedStep(id: i, title: say, action: s.needsConfirm ? .confirm : .instruction, rule: rule))
            } else {
                steps.append(GuidedStep(id: i, title: s.title, action: .instruction, rule: rule))
            }
        }
        return GuidedPlan(siteID: broker.id, siteName: broker.name, steps: steps, addsEmailStepAfterSend: false)
    }

    /// A walk for a site whose opt-out form wants the address of the person's own listing: the app searches for them, they tap
    /// their listing, the app fills in the form with that address, they clear the check and the app sends it.
    public static func listingPlan(for entry: DirectoryEntry, search: URL) -> GuidedPlan {
        guard let form = entry.optOutForm else { return plan(for: entry) }
        var steps: [GuidedStep] = []
        func add(_ title: String, _ detail: String? = nil, _ action: GuidedStep.Action, _ rule: GuidedStep.Rule? = nil) {
            steps.append(GuidedStep(id: steps.count, title: title, detail: detail, action: action, rule: rule))
        }
        add("Open your own listing", "We searched \(entry.domain) for you. Tap the result that is you, then tap \"This is my listing\". If none is you, tap Not working.", .pickListing(search: search))
        add("Open the opt-out page", entry.domain, .openPage(form.page), .pageLoaded)
        add("We fill in your details", "Your email and the address of your listing.", .autofill, .formFilled)
        add("Clear the check", "Solve the bot check, tick any confirmation box and accept terms yourself if asked. We wait for you.", .clearBlockers, .blockersCleared)
        add("We send it", "Then we look for the site's confirmation.", .send, .formSent)
        var p = GuidedPlan(siteID: entry.id, siteName: entry.domain, steps: steps, addsEmailStepAfterSend: true)
        p.listingFields = form.fields.filter(FormFiller.isListingField).map(\.name)
        return p
    }

    /// A guided walk for a directory site: the app fills the form and sends it, and the person clears whatever only they can.
    public static func plan(for entry: DirectoryEntry) -> GuidedPlan {
        var steps: [GuidedStep] = []
        func add(_ title: String, _ detail: String? = nil, _ action: GuidedStep.Action, _ rule: GuidedStep.Rule? = nil) {
            steps.append(GuidedStep(id: steps.count, title: title, detail: detail, action: action, rule: rule))
        }
        if let form = entry.optOutForm {
            add("Open the opt-out page", entry.domain, .openPage(form.page), .pageLoaded)
            add("We fill in your details", "Only the fields this form asks for.", .autofill, .formFilled)
            add("Clear the check", "Solve the bot check, tick any confirmation box and accept terms yourself if asked. We wait for you.", .clearBlockers, .blockersCleared)
            add("We send it", "Then we look for the site's confirmation.", .send, .formSent)
            return GuidedPlan(siteID: entry.id, siteName: entry.domain, steps: steps, addsEmailStepAfterSend: true)
        }
        let start = entry.optOutURL ?? URL(string: "https://\(entry.domain)/")!
        add("Open the site's opt-out page", entry.domain, .openPage(start), .pageLoaded)
        add("Find the opt-out or privacy request form and fill it in", "We could not find the form automatically.", .instruction)
        add("Submit it", nil, .confirm)
        add("Confirm the email they send you, if they send one", "Open the message and click its link.", .waitForEmail(subject: nil, minutes: nil))
        return GuidedPlan(siteID: entry.id, siteName: entry.domain, steps: steps, addsEmailStepAfterSend: false)
    }

    private static func rule(for d: Step.DoneWhen?) -> GuidedStep.Rule? {
        guard let d else { return nil }
        if let u = d.urlContains { return .urlContains(u) }
        if let t = d.textContains { return .textContains(t) }
        if d.urlChanges == true { return .urlChanged }
        return nil
    }
}

// MARK: Reporting a site that does not work

public enum IssueKind: String, Codable, CaseIterable, Sendable {
    case brokenLink, gatedByOther, blockedMe, other

    public var label: String {
        switch self {
        case .brokenLink: return "The page or link is broken"
        case .gatedByOther: return "It needs something else (login, payment, ID or a phone call)"
        case .blockedMe: return "The site blocked me"
        case .other: return "Something else is wrong"
        }
    }
}

public struct SiteIssue: Codable, Equatable, Sendable {
    public var date: Date
    public var kind: IssueKind
    public init(date: Date, kind: IssueKind) { self.date = date; self.kind = kind }
}

public extension Progress {
    mutating func reportIssue(_ kind: IssueKind, site: String, on date: Date = Date()) {
        siteIssues[site, default: []].append(SiteIssue(date: date, kind: kind))
    }

    /// The latest problem the person reported for a site within `days`, so queues can leave it alone for a while.
    func activeIssue(for site: String, now: Date = Date(), within days: Int = 30) -> SiteIssue? {
        siteIssues[site]?.filter { now.timeIntervalSince($0.date) < Double(days) * 86_400 }.max { $0.date < $1.date }
    }
}
