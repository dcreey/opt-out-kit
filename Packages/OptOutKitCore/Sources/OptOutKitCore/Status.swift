import Foundation

/// Where one person stands with one broker.
public enum PersonStatus: Equatable, Sendable {
    case notStarted
    case inProgress(stepsDone: Int, of: Int)
    case done(on: Date, recheckDue: Date)
}

public struct BrokerStatus: Equatable, Sendable {
    public var person: Person
    public var status: PersonStatus
}

/// One line that sums a broker up across every profile in the household.
public enum StatusSummary: Equatable, Sendable {
    case notStarted
    case inProgress
    case partial(done: Int, of: Int)
    case complete

    public var label: String {
        switch self {
        case .notStarted: return "Not started"
        case .inProgress: return "In progress"
        case .partial(let d, let n): return "Partial: \(d) of \(n) profiles opted out"
        case .complete: return "Opted out"
        }
    }
}

public extension Household {
    func statuses(for broker: Broker) -> [BrokerStatus] {
        people.map { person in
            let p = progress(for: person.id)
            if let when = p.doneAt[broker.id] {
                let due = Calendar.current.date(byAdding: .day, value: broker.recheckDays, to: when) ?? when
                return BrokerStatus(person: person, status: .done(on: when, recheckDue: due))
            }
            let n = p.completedSteps[broker.id]?.count ?? 0
            return BrokerStatus(person: person,
                                status: n == 0 ? .notStarted : .inProgress(stepsDone: n, of: broker.steps.count))
        }
    }

    func summary(for broker: Broker) -> StatusSummary {
        let all = statuses(for: broker).map(\.status)
        let done = all.filter { if case .done = $0 { return true } else { return false } }.count
        if !all.isEmpty, done == all.count { return .complete }
        if done > 0 { return .partial(done: done, of: all.count) }
        if all.contains(where: { if case .inProgress = $0 { return true } else { return false } }) { return .inProgress }
        return .notStarted
    }
}

/// Plain-English text for the registry's technical tags, for the broker details page.
public enum Describe {
    public static func tier(_ tier: Tier) -> String {
        switch tier {
        case .A: return "A simple form and an email link"
        case .B: return "A form plus a CAPTCHA that you solve"
        case .C: return "A guided walkthrough with a phone, ID or account step"
        case .D: return "Email or letter only"
        }
    }

    private static let signals: [String: String] = [
        "captcha": "You solve a CAPTCHA",
        "email_link": "Sends you a confirmation email",
        "time_limited_link": "The email link expires quickly",
        "phone_verify": "Needs a phone code or call",
        "app_only": "Works only in a real browser",
        "third_party_refused": "You must submit it yourself",
        "search_first": "You find your listing first",
    ]

    public static func signal(_ tag: String) -> String { signals[tag] ?? tag.replacingOccurrences(of: "_", with: " ") }

    public static func field(_ tag: String) -> String {
        switch tag {
        case "full_name": return "Full name"
        case "email": return "Email address"
        case "phone": return "Phone number"
        case "birthdate": return "Birthdate"
        case "address": return "Address"
        default: return tag.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
