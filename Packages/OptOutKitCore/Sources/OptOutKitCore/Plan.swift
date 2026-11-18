import Foundation

/// One thing the person (or the app) does that handles one or more sites. A request that reaches many sites is one task.
public struct PlanTask: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case platform(String)      // an official one-request service, by platform id
        case flow(String)          // a hand-written walkthrough, by broker id
        case site(String)          // a directory site, by entry id (the lead site when sites share one opt-out)
        case automatic             // every site the app opts out of by itself: one task, one run
        case emails                // every site that takes opt-outs by email: one task, one message per address
        case verify                // every form that only needs the person to tick a human check: one task, one tap per page
    }
    public var kind: Kind
    public var title: String
    /// Every site domain this one task handles, its own first. A shared request lists them all, so no site is counted twice.
    public var domains: [String]
    public var reason: String
    /// How this task gets done; nil for an official service, which is its own kind of thing.
    public var method: OptOutMethod?
    /// Two-letter codes of the states whose broker registry lists any of these sites.
    public var registeredIn: Set<String>
    /// 0-100, the highest `DirectoryEntry.priority` of the sites this task handles; higher is removed first within its band.
    public var priority: Int
    public init(kind: Kind, title: String, domains: [String], reason: String, method: OptOutMethod?, registeredIn: Set<String>, priority: Int = 0) {
        self.priority = priority; self.kind = kind; self.title = title; self.domains = domains; self.reason = reason; self.method = method; self.registeredIn = registeredIn
    }
    public var id: String {
        switch kind { case .platform(let i): return "platform-\(i)"; case .flow(let i): return "flow-\(i)"; case .site(let i): return "site-\(i)"; case .automatic: return "automatic"; case .emails: return "emails"; case .verify: return "verify" }
    }
    public var siteCount: Int { domains.count }
    public var isShared: Bool { domains.count > 1 }
}

/// A step in the person's plan: an official service, or one of the ways we do the rest.
public struct PlanStep: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case platform(String), method(OptOutMethod) }
    public var kind: Kind
    public var title: String
    public var explanation: String
    public var tasks: [PlanTask]
    public var id: String { switch kind { case .platform(let i): return "step-platform-\(i)"; case .method(let m): return "step-\(m.rawValue)" } }
    /// How many sites finishing this whole step handles.
    public var siteCount: Int { tasks.reduce(0) { $0 + $1.siteCount } }
}

/// Builds the ordered plan: the official removal service for the person's place first, then our automatic opt-out, semi-automated,
/// guided and manual. A site belongs to the first step that handles it and to no later one; sites that share one opt-out are one task.
public enum OptOutPlan {
    /// Sites with no route to opt out yet (no form, no page, no email): not tasks, kept to be unlocked once a route is found.
    public static func locked(_ steps: [PlanStep], entries: [DirectoryEntry]) -> [DirectoryEntry] {
        let planned = Set(steps.flatMap { $0.tasks.flatMap(\.domains) })
        return entries.filter { $0.closed == nil && !planned.contains($0.domain) }.sorted { $0.domain < $1.domain }
    }

    /// Whether the site has a form the app can fill in (read from the page, or found on the live page).
    public static func hasForm(_ e: DirectoryEntry) -> Bool { e.optOutForm != nil || e.liveForm?.found == true }

    /// The single sites of the semi-automated step that the app fills in and sends for the person (they only tick the check), in the
    /// order the step lists them. Shared-form groups are not in it: they are one task each.
    public static func verifyQueue(_ steps: [PlanStep], entries: [DirectoryEntry]) -> [String] {
        let byDomain = Dictionary(entries.map { ($0.domain, $0) }, uniquingKeysWith: { a, _ in a })
        let eligible: [DirectoryEntry] = steps.filter { $0.kind == .method(.semiAutomatic) }.flatMap(\.tasks).compactMap { t in
            guard case .site = t.kind, t.domains.count == 1, let e = byDomain[t.domains[0]], hasForm(e) else { return nil }
            if let f = e.optOutForm, FormFiller.needsListing(f) { return nil }
            return e
        }
        // Forms that ask for a typed code come last; otherwise the brokers that matter most come first.
        func typed(_ e: DirectoryEntry) -> Int { ((e.optOutForm.map(FormFiller.hasTypedCode) ?? false) || (e.liveForm?.blockers.contains("code") ?? false)) ? 1 : 0 }
        let forms = eligible.sorted { (typed($0), -($0.priority ?? 0), $0.domain) < (typed($1), -($1.priority ?? 0), $1.domain) }.map(\.domain)
        // Sites with no form, only an email address, come one at a time too, after the form sites: each shows "no form exists, send an email instead".
        let emailOnly = steps.flatMap(\.tasks).filter { $0.kind == .emails }.flatMap(\.domains).compactMap { byDomain[$0] }
            .filter { $0.contactEmail != nil && !hasForm($0) }
            .sorted { (-($0.priority ?? 0), $0.domain) < (-($1.priority ?? 0), $1.domain) }.map(\.domain)
        return forms + emailOnly
    }

    public static func build(entries: [DirectoryEntry], brokers: [Broker], platforms: [Platform],
                             classifyEntry: (DirectoryEntry) -> MethodVerdict, classifyBroker: (Broker) -> MethodVerdict) -> [PlanStep] {
        let byDomain = Dictionary(entries.map { ($0.domain, $0) }, uniquingKeysWith: { a, _ in a })
        func states(_ domains: [String]) -> Set<String> { Set(domains.flatMap { byDomain[$0]?.registeredIn ?? [] }) }
        var claimed = Set<String>()
        var steps: [PlanStep] = []

        // 1. Official services, in the order given.
        for p in platforms {
            let unique = entries.map(\.domain).filter { !claimed.contains($0) && p.covers(domain: $0) != nil }
            guard !unique.isEmpty else { continue }
            claimed.formUnion(unique)
            let task = PlanTask(kind: .platform(p.id), title: p.shortName, domains: unique,
                                reason: L10n.f("One free request to %@ reaches all of these.", p.shortName), method: nil, registeredIn: states(unique))
            steps.append(PlanStep(kind: .platform(p.id), title: p.shortName,
                                  explanation: L10n.f("%@ sends your deletion request to every broker registered in %@. Do this first: it handles these sites in one go.", p.shortName, p.jurisdiction),
                                  tasks: [task]))
        }

        // 2. Our own steps. Hand-written flows first, because one flow can clear several sites.
        var byMethod: [OptOutMethod: [PlanTask]] = [:]
        for b in brokers {
            let own = Directory.entry(for: b, in: entries)?.domain
            let domains = ([own].compactMap { $0 } + (b.covers ?? [])).filter { !claimed.contains($0) }
            let unique = Array(NSOrderedSet(array: domains)) as! [String]
            guard !unique.isEmpty || own == nil else { continue }
            claimed.formUnion(unique)
            let v = classifyBroker(b)
            byMethod[v.method, default: []].append(PlanTask(kind: .flow(b.id), title: b.name, domains: unique.isEmpty ? [b.id] : unique, reason: v.reason, method: v.method, registeredIn: states(unique)))
        }
        // Sites that share one opt-out (the same family, the same form template or the same opt-out page) are one task, filed under
        // the most automated way any of them can be done. Sites are linked through any of these, so a chain still ends up as one.
        let order = OptOutMethod.allCases
        let open = entries.filter { !claimed.contains($0.domain) }
        var parent = Array(0..<open.count)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        var firstWith: [String: Int] = [:]
        for (i, e) in open.enumerated() {
            let keys = [e.family.map { "f:\($0)" }, e.template.map { "t:\($0)" }, e.optOutURL.map { "u:\($0.absoluteString)" }].compactMap { $0 }
            for k in keys { if let j = firstWith[k] { parent[find(i)] = find(j) } else { firstWith[k] = i } }
        }
        for members in Dictionary(grouping: open.indices, by: find).values.map({ $0.map { open[$0] } }) where members.count > 1 {
            let verdicts = members.map { ($0, classifyEntry($0)) }
            let best = verdicts.min { order.firstIndex(of: $0.1.method)! < order.firstIndex(of: $1.1.method)! }!
            let lead = members.first { $0.id == $0.familyParent } ?? best.0
            let domains = [lead.domain] + members.map(\.domain).filter { $0 != lead.domain }.sorted()
            if best.1.method == .manual { continue }
            claimed.formUnion(domains)
            byMethod[best.1.method, default: []].append(PlanTask(kind: .site(lead.id), title: lead.domain, domains: domains,
                                                                   reason: L10n.f("One opt-out request handles all %@ sites that share this process.", domains.count), method: best.1.method, registeredIn: states(domains)))
        }
        // Sites whose only route is an email address (no form we can fill) are one guided task: a message per address, naming every
        // site that address handles. The person reads each one and taps Send. Sites with a form keep their own task; email is the
        // extra layer for those (see `EmailBatch`), never a reason to move them out of the semi-automated step.
        let emailEntries = entries.filter { !claimed.contains($0.domain) && $0.contactEmail != nil && !hasForm($0) && classifyEntry($0).method != .automatic }
        if !emailEntries.isEmpty {
            let domains = emailEntries.map(\.domain)
            claimed.formUnion(domains)
            let addresses = Set(emailEntries.compactMap { $0.contactEmail?.lowercased() }).count
            byMethod[.emailOnly, default: []].append(PlanTask(kind: .emails, title: L10n.t("Send opt-out emails"), domains: domains,
                reason: L10n.f("%@ messages, one per address, each naming every site it handles. You read them and tap Send.", addresses),
                method: .emailOnly, registeredIn: states(domains)))
        }
        for e in entries where !claimed.contains(e.domain) {
            claimed.insert(e.domain)
            let v = classifyEntry(e)
            if v.method == .manual { continue }          // no route to opt out yet: not a task, listed as "later" (see `locked`)
            byMethod[v.method, default: []].append(PlanTask(kind: .site(e.id), title: e.domain, domains: [e.domain], reason: v.reason, method: v.method, registeredIn: Set(e.registeredIn ?? [])))
        }
        for m in order {
            guard var tasks = byMethod[m], !tasks.isEmpty else { continue }
            if m == .automatic {
                // The app does all of these by itself, so they are one task however many sites that is.
                let domains = tasks.flatMap(\.domains)
                tasks = [PlanTask(kind: .automatic, title: L10n.t("Let the app do these for you"), domains: domains,
                                  reason: L10n.f("One run fills in and sends all %@ opt-out forms. You only handle a check or an email link if a site asks.", domains.count),
                                  method: .automatic, registeredIn: states(domains))]
            }
            // Forms that ask the person to type a code take the most effort, so they come last in the semi-automated step.
            func typed(_ t: PlanTask) -> Bool { m == .semiAutomatic && ((byDomain[t.domains.first ?? ""]?.optOutForm.map(FormFiller.hasTypedCode) ?? false) || (byDomain[t.domains.first ?? ""]?.liveForm?.blockers.contains("code") ?? false)) }
            // Each task's sort key is worked out once: checking a form for a typed code inside the comparison did it some 16,000 times a build.
            let sorted = tasks.map { ((typed($0) ? 1 : 0, $0.title.lowercased()), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
            steps.append(PlanStep(kind: .method(m), title: m.title, explanation: m.explanation, tasks: sorted))
        }
        // Each task carries the highest priority among the sites it handles, so the queue can put the brokers that matter most first.
        for i in steps.indices { for j in steps[i].tasks.indices {
            steps[i].tasks[j].priority = steps[i].tasks[j].domains.compactMap { byDomain[$0]?.priority }.max() ?? 0
        } }
        return steps
    }
}

public extension PlanTask {
    /// Whether any site this task handles is on the broker registry of one of these states.
    func isRegistered(in places: Set<String>) -> Bool { !registeredIn.isDisjoint(with: places) }
}


/// Where a task sits in the ranked queue. Lower comes first. "Local" is a place the person lives or has lived; "country" is any broker
/// registered in their country (so far only US states publish registries); everything else is global. Guided and manual tasks are both
/// "manual" here: the person does the steps.
public enum PlanRank: Int, CaseIterable, Comparable, Identifiable, Sendable {
    case localOfficial = 1, ourAutomatic, localSemi, countrySemi, localManualBig, globalSemi, emailOnly, localManualRest, globalManual
    public var id: Int { rawValue }
    public static func < (a: PlanRank, b: PlanRank) -> Bool { a.rawValue < b.rawValue }
    /// A shared manual task has to handle at least this many sites to jump ahead of the global semi-automated ones.
    public static let bigTaskSites = 10

    public var title: String {
        switch self {
        case .localOfficial: return L10n.t("Your place's official removal service")
        case .ourAutomatic: return L10n.t("Done for you by the app")
        case .localSemi: return L10n.t("Semi-automated, registered where you live")
        case .countrySemi: return L10n.t("Semi-automated, registered in your country")
        case .localManualBig: return L10n.t("Big manual tasks where you live or in your country")
        case .globalSemi: return L10n.t("Semi-automated, anywhere")
        case .emailOnly: return L10n.t("Email only")
        case .localManualRest: return L10n.t("Other manual tasks where you live or in your country")
        case .globalManual: return L10n.t("Remaining manual tasks, anywhere")
        }
    }
    public var explanation: String {
        switch self {
        case .localOfficial: return L10n.t("One free request that your state or country already runs, reaching every broker registered there. Do this first.")
        case .ourAutomatic: return L10n.t("Forms the app fills in and sends by itself in one run.")
        case .localSemi: return L10n.t("The app fills in the form; you only solve the check. These brokers are registered where you live, so the law backs your request.")
        case .countrySemi: return L10n.t("The same, for brokers registered somewhere in your country.")
        case .localManualBig: return L10n.t("You do the steps, but each task handles 10 or more sites, so the effort pays off.")
        case .globalSemi: return L10n.t("The app fills in the form; you solve the check. These brokers are not registered near you, but they may still list you.")
        case .emailOnly: return L10n.t("These sites take the request by email and have no form. The app writes one message per address and you tap Send. Do them after the semi-automated ones.")
        case .localManualRest: return L10n.t("Smaller manual tasks for brokers registered where you live or in your country.")
        case .globalManual: return L10n.t("Everything left: manual tasks for brokers registered elsewhere. Do these last.")
        }
    }
}

public struct QueueBand: Identifiable, Equatable, Sendable {
    public var rank: PlanRank
    public var tasks: [PlanTask]
    public var id: Int { rank.rawValue }
    public var siteCount: Int { tasks.reduce(0) { $0 + $1.siteCount } }
}

public extension OptOutPlan {
    /// The rank of one task. `local` are the person's states (where they live and have lived); `countryHasRegistries` says whether a
    /// broker registered in some state counts as being in their country.
    static func rank(of task: PlanTask, local: Set<String>, countryHasRegistries: Bool) -> PlanRank {
        let isLocal = task.isRegistered(in: local)
        let inCountry = isLocal || (countryHasRegistries && !task.registeredIn.isEmpty)
        switch task.kind {
        case .platform: return .localOfficial
        case .automatic: return .ourAutomatic
        default: break
        }
        if task.method == .automatic { return .ourAutomatic }
        if task.method == .semiAutomatic { return isLocal ? .localSemi : inCountry ? .countrySemi : .globalSemi }
        if task.method == .emailOnly || task.kind == .emails { return .emailOnly }
        guard inCountry else { return .globalManual }
        return task.siteCount >= PlanRank.bigTaskSites ? .localManualBig : .localManualRest
    }

    /// Every task in one ranked queue, grouped into bands. Inside a band, tasks near the person come first, then bigger tasks.
    static func queue(_ steps: [PlanStep], local: Set<String>, countryHasRegistries: Bool) -> [QueueBand] {
        let tasks = steps.flatMap(\.tasks)
        let ranked = tasks.map { ($0, rank(of: $0, local: local, countryHasRegistries: countryHasRegistries)) }
        return PlanRank.allCases.compactMap { r in
            let inBand = ranked.filter { $0.1 == r }.map(\.0).sorted { a, b in
                let la = a.isRegistered(in: local), lb = b.isRegistered(in: local)
                if la != lb { return la }
                if a.priority != b.priority { return a.priority > b.priority }
                if a.siteCount != b.siteCount { return a.siteCount > b.siteCount }
                return a.title.lowercased() < b.title.lowercased()
            }
            return inBand.isEmpty ? nil : QueueBand(rank: r, tasks: inBand)
        }
    }
}
