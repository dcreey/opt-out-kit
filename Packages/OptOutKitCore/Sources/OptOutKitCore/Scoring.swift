import Foundation

/// Points for finishing the list and staying finished. They reward looking, never submitting: a point is paid when a
/// check observes something, not when someone taps Done (docs/DESIGN.md, "Verified points"). No leaderboards, nothing
/// leaves the phone, and finding a listing is never penalised.
public struct Score: Equatable, Sendable {
    public var points: Int
    public var level: Level
    public var nextLevelAt: Int?

    public struct Level: Equatable, Sendable {
        public var name: String
        public var from: Int
    }

    public static let levels = [
        Level(name: "Exposed", from: 0), Level(name: "Covering Tracks", from: 25), Level(name: "Low Profile", from: 75),
        Level(name: "Ghost", from: 150), Level(name: "Off the Grid", from: 300),
    ]

    /// 10 for an automatically verified opt-out, 5 for each site the person looked at and found clean, 3 for each time
    /// they honestly report a listing (it is how the list gets finished), 2 for reporting results behind payment,
    /// 2 for a clean automatic scan result.
    public static func compute(_ progress: Progress, brokers: [Broker]) -> Score {
        var points = 0
        for broker in brokers {
            if case .verified = progress.verification(for: broker.id) { points += 10 }
        }
        for (_, records) in progress.siteChecks {
            guard let latest = records.filter({ $0.result != .inconclusive }).max(by: { $0.date < $1.date }) else { continue }
            switch (latest.source, latest.result) {
            case (.selfReported, .removed): points += 5
            case (.selfReported, .stillListed): points += 3
            case (.automatic, .removed): points += 2
            case (.selfReported, .paywalled): points += 2      // looked, and found the results behind payment
            default: break
            }
        }
        let level = levels.last { points >= $0.from } ?? levels[0]
        let next = levels.first { $0.from > points }?.from
        return Score(points: points, level: level, nextLevelAt: next)
    }
}

public extension DirectoryEntry {
    /// Sites a person can look at themselves: not covered by an automatic check, and with somewhere to look.
    var needsManualCheck: Bool { searchCheck?.recheck == nil }

    /// Where to send the person to look for themselves: the site's own search with their name filled in when that is a
    /// plain GET, else its home page.
    func lookupURL(for person: Person) -> URL {
        if let c = searchCheck?.candidate, c.method.uppercased() == "GET",
           let name = person.allNames.first(where: { $0.split(separator: " ").count >= 2 }),
           let url = Rechecker.url(c.url, name: name, city: person.addresses.first?.city, state: person.addresses.first?.state) {
            return url
        }
        return URL(string: "https://\(domain)/") ?? URL(string: "https://example.invalid/")!
    }
}
