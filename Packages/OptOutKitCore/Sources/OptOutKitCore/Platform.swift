import Foundation
import Yams

/// A government or industry service that sends one request to many brokers at once (California's DROP is the first). It is shaped
/// like a hand-written broker walkthrough, plus who may use it, which of our sites it reaches, and how long to wait before
/// trusting it. Adding another jurisdiction is a new file in `platforms/`, not new code.
public struct Platform: Equatable, Identifiable, Sendable {
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

public enum PlatformLoader {
    struct Meta: Decodable {
        struct Body: Decodable {
            var shortName: String
            var jurisdiction: String
            var states: [String]
            var requestURL: URL
            var holdDays: Int
            var live: Bool?
            var summary: String
            var coverageFile: String?
            enum CodingKeys: String, CodingKey {
                case jurisdiction, states, summary, live
                case shortName = "short_name"
                case requestURL = "request_url", holdDays = "hold_days", coverageFile = "coverage_file"
            }
        }
        var platform: Body
    }

    struct CoverageFile: Decodable {
        var registered: Int
        var covered: [String: Platform.Coverage]
    }

    /// Loads every `*.yml` in `platforms/`. Each file is a broker walkthrough with a `platform:` block, plus the coverage JSON it names.
    public static func load(directory: URL) throws -> [Platform] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "yml" }
        return try files.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { file in
            let text = try String(contentsOf: file, encoding: .utf8)
            let broker = try YAMLDecoder().decode(Broker.self, from: text)
            if broker.id.isEmpty { throw RegistryError.emptyID(file: file.lastPathComponent) }
            if broker.steps.isEmpty { throw RegistryError.noSteps(broker.id) }
            let meta = try YAMLDecoder().decode(Meta.self, from: text).platform
            var coverage: [String: Platform.Coverage] = [:]
            var registered = 0
            if let name = meta.coverageFile {
                let data = try Data(contentsOf: directory.appendingPathComponent(name))
                let file = try JSONDecoder().decode(CoverageFile.self, from: data)
                coverage = file.covered; registered = file.registered
            }
            return Platform(walkthrough: broker, shortName: meta.shortName, jurisdiction: meta.jurisdiction, states: meta.states, requestURL: meta.requestURL,
                            holdDays: meta.holdDays, live: meta.live ?? true, summary: meta.summary, registered: registered, coverage: coverage)
        }
    }
}
