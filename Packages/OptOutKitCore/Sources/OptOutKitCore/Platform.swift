import Foundation

/// A government or industry service that sends one request to many brokers at once (California's DROP is the first). It is shaped
/// like a hand-written broker walkthrough, plus who may use it, which of our sites it reaches, and how long to wait before
/// trusting it. Adding another jurisdiction is a new file in `platforms/`, not new code.
public struct Platform: Codable, Equatable, Identifiable, Sendable {
    /// What a registry says about one of our sites.
    public struct Coverage: Codable, Equatable, Sendable {
        public var broker: String          // the registered business's name
        public var match: Match
        public enum Match: String, Codable, Sendable { case domain, name }     // name matches are likely, not certain
    }

    public var walkthrough: Broker          // the steps the person follows; progress is tracked under its id
    public var shortName: String            // "California DROP", for rows and notes
    public var jurisdiction: String         // "California"
    public var states: [String]             // two-letter codes of the residents who may use it
    public var requestURL: URL
    public var holdDays: Int                // days to leave covered sites alone after the person submits, before checking again
    public var live: Bool                   // false for a mechanism that is announced but not open yet
    public var summary: String
    public var registered: Int              // how many brokers the registry lists
    public var coverage: [String: Coverage] // our site or hand-written flow domain -> registry match

    public init(walkthrough: Broker, shortName: String, jurisdiction: String, states: [String], requestURL: URL, holdDays: Int, live: Bool, summary: String,
                registered: Int, coverage: [String: Coverage]) {
        self.walkthrough = walkthrough; self.shortName = shortName; self.jurisdiction = jurisdiction; self.states = states; self.requestURL = requestURL
        self.holdDays = holdDays; self.live = live; self.summary = summary; self.registered = registered; self.coverage = coverage
    }

    public var id: String { walkthrough.id }
    public var name: String { walkthrough.name }

    /// Whether this person may use it: their current address is in one of its states, or, for the account owner who has not
    /// entered an address yet, the state they chose in the walkthrough is one of them.
    public func eligible(_ person: Person, ownerState: String? = nil) -> Bool {
        let wanted = Set(states.compactMap { USStates.name(for: $0)?.lowercased() })
        if let state = person.currentAddress?.state, !state.trimmingCharacters(in: .whitespaces).isEmpty {
            return USStates.name(for: state).map { wanted.contains($0.lowercased()) } ?? false
        }
        guard person.relationship == .me, let ownerState, let chosen = USStates.name(for: ownerState)?.lowercased() else { return false }
        return wanted.contains(chosen)
    }

    public func covers(domain: String) -> Coverage? {
        let d = domain.lowercased()
        return coverage[d] ?? coverage[LinkRules.registrable(d)]
    }

    /// Our site domains this platform reaches, sorted.
    public var coveredDomains: [String] { coverage.keys.sorted() }

    /// When covered sites may be asked directly again, given when the person submitted.
    public func holdUntil(submitted: Date) -> Date { submitted.addingTimeInterval(Double(holdDays) * 86_400) }
}
