import Foundation

/// One thing the person (or the app) does that handles one or more sites. A request that reaches many sites is one task.
public struct PlanTask: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case platform(String)      // an official one-request service, by platform id
        case flow(String)          // a hand-written walkthrough, by broker id
        case site(String)          // a directory site, by entry id (the lead site when sites share one opt-out)
        case automatic             // every site the app opts out of by itself: one task, one run
    }
    public var kind: Kind
    public var title: String
    /// Every site domain this one task handles, its own first. A shared request lists them all, so no site is counted twice.
    public var domains: [String]
    public var reason: String
    /// Two-letter codes of the states whose broker registry lists any of these sites.
    public var registeredIn: Set<String>
    public var id: String {
        switch kind { case .platform(let i): return "platform-\(i)"; case .flow(let i): return "flow-\(i)"; case .site(let i): return "site-\(i)"; case .automatic: return "automatic" }
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
                                reason: L10n.f("One free request to %@ reaches all of these.", p.shortName), registeredIn: states(unique))
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
            byMethod[v.method, default: []].append(PlanTask(kind: .flow(b.id), title: b.name, domains: unique.isEmpty ? [b.id] : unique, reason: v.reason, registeredIn: states(unique)))
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
            claimed.formUnion(domains)
            byMethod[best.1.method, default: []].append(PlanTask(kind: .site(lead.id), title: lead.domain, domains: domains,
                                                                   reason: L10n.f("One opt-out request handles all %@ sites that share this process.", domains.count), registeredIn: states(domains)))
        }
        for e in entries where !claimed.contains(e.domain) {
            claimed.insert(e.domain)
            let v = classifyEntry(e)
            byMethod[v.method, default: []].append(PlanTask(kind: .site(e.id), title: e.domain, domains: [e.domain], reason: v.reason, registeredIn: Set(e.registeredIn ?? [])))
        }
        for m in order {
            guard var tasks = byMethod[m], !tasks.isEmpty else { continue }
            if m == .automatic {
                // The app does all of these by itself, so they are one task however many sites that is.
                let domains = tasks.flatMap(\.domains)
                tasks = [PlanTask(kind: .automatic, title: L10n.t("Let the app do these for you"), domains: domains,
                                  reason: L10n.f("One run fills in and sends all %@ opt-out forms. You only handle a check or an email link if a site asks.", domains.count),
                                  registeredIn: states(domains))]
            }
            steps.append(PlanStep(kind: .method(m), title: m.title, explanation: m.explanation, tasks: tasks.sorted { $0.title.lowercased() < $1.title.lowercased() }))
        }
        return steps
    }
}

public extension PlanTask {
    /// Whether any site this task handles is on the broker registry of one of these states.
    func isRegistered(in places: Set<String>) -> Bool { !registeredIn.isDisjoint(with: places) }
}
