import Foundation

public struct DueCheck: Equatable, Sendable {
    public var person: Person
    public var broker: Broker
}

/// Something worth telling the user about after a round of checks.
public enum CheckEvent: Equatable, Sendable {
    case verified(personID: UUID, brokerID: String)
    case relisted(personID: UUID, brokerID: String)
}

/// Finds the checks that are due, runs them, and records what they found.
public struct CheckRunner: Sendable {
    private let rechecker: Rechecker
    public init(fetcher: PageFetcher) { rechecker = Rechecker(fetcher: fetcher) }

    /// Submitted opt-outs whose next check time has passed. Brokers with no `recheck:` block are skipped.
    public static func due(in household: Household, brokers: [Broker], now: Date = Date()) -> [DueCheck] {
        var result: [DueCheck] = []
        for person in household.people {
            let progress = household.progress(for: person.id)
            for broker in brokers where broker.recheck != nil {
                if let when = progress.nextCheck(for: broker), when <= now {
                    result.append(DueCheck(person: person, broker: broker))
                }
            }
        }
        return result
    }

    /// Runs checks one after another, so a broker is never hit in parallel for several people.
    public func run(_ checks: [DueCheck], spacing: TimeInterval = 2) async -> [(DueCheck, CheckOutcome)] {
        var out: [(DueCheck, CheckOutcome)] = []
        for (i, check) in checks.enumerated() {
            if i > 0 && spacing > 0 { try? await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000)) }
            out.append((check, await rechecker.check(check.broker, for: check.person)))
        }
        return out
    }
}

public extension Household {
    /// Records outcomes and returns the changes the user should hear about.
    mutating func apply(_ outcomes: [(DueCheck, CheckOutcome)], now: Date = Date()) -> [CheckEvent] {
        var events: [CheckEvent] = []
        for (check, outcome) in outcomes {
            let before = progress(for: check.person.id).verification(for: check.broker.id)
            mutateProgress(for: check.person.id) { $0.record(outcome.result, for: check.broker.id, on: now) }
            let after = progress(for: check.person.id).verification(for: check.broker.id)
            guard before != after else { continue }
            switch after {
            case .verified: events.append(.verified(personID: check.person.id, brokerID: check.broker.id))
            case .relisted: events.append(.relisted(personID: check.person.id, brokerID: check.broker.id))
            case .unverified: break
            }
        }
        return events
    }
}
