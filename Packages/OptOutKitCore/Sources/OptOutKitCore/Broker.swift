import Foundation

/// Effort tier from docs/DESIGN.md: A scripted, B scripted + CAPTCHA, C walkthrough, D email/letter only.
public enum Tier: String, Codable, CaseIterable, Comparable, Sendable {
    case A, B, C, D

    public static func < (l: Tier, r: Tier) -> Bool { l.rawValue < r.rawValue }
}

/// One step on a broker's opt-out flow. In YAML a step is a map with one primary key
/// (`open`, `copy`, `say`, `search_match`, `wait_for_email`) and an optional `confirm: true`.
public struct Step: Codable, Equatable, Sendable {
    public struct EmailWait: Codable, Equatable, Sendable {
        public var subject: String?
        public var withinMinutes: Int?

        enum CodingKeys: String, CodingKey { case subject, withinMinutes = "within_minutes" }
    }

    public var open: URL?
    public var copy: String?
    public var say: String?
    public var searchMatch: String?
    public var waitForEmail: EmailWait?
    public var confirm: Bool?

    public init(open: URL? = nil, copy: String? = nil, say: String? = nil, searchMatch: String? = nil,
                waitForEmail: EmailWait? = nil, confirm: Bool? = nil) {
        self.open = open; self.copy = copy; self.say = say
        self.searchMatch = searchMatch; self.waitForEmail = waitForEmail; self.confirm = confirm
    }

    enum CodingKeys: String, CodingKey {
        case open, copy, say, confirm
        case searchMatch = "search_match"
        case waitForEmail = "wait_for_email"
    }

    /// Text shown on the step card.
    public var title: String {
        if let say { return say }
        if open != nil { return "Open the site" }
        if let copy { return "Copy your \(copy)" }
        if let searchMatch { return searchMatch }
        if waitForEmail != nil { return "Wait for the confirmation email" }
        return "Confirm"
    }

    /// True when the user must tap Done before the next card unlocks.
    public var needsConfirm: Bool { confirm ?? false }
}

public struct Broker: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var tier: Tier
    public var covers: [String]?
    public var signals: [String]?
    public var fields: [String]?
    public var steps: [Step]
    public var recheckDays: Int
    /// Days the site needs before an opt-out takes effect; the first check waits this long.
    public var processingDays: Int?
    /// How to check, with no user input, whether the person is still listed.
    public var recheck: Recheck?
    /// ISO date of the last real run; nil until a human has verified the flow.
    public var verified: String?

    enum CodingKeys: String, CodingKey {
        case id, name, tier, covers, signals, fields, steps, verified, recheck
        case recheckDays = "recheck_days"
        case processingDays = "processing_days"
    }

    public init(id: String, name: String, tier: Tier, covers: [String]?, signals: [String]?, fields: [String]?,
                steps: [Step], recheckDays: Int, verified: String?, processingDays: Int? = nil, recheck: Recheck? = nil) {
        self.id = id; self.name = name; self.tier = tier; self.covers = covers; self.signals = signals
        self.fields = fields; self.steps = steps; self.recheckDays = recheckDays; self.verified = verified
        self.processingDays = processingDays; self.recheck = recheck
    }

    public var isVerified: Bool { verified != nil }
}
