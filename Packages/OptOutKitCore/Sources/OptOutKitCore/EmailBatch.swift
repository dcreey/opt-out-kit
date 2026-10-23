import Foundation

/// One opt-out email: an address and every site it handles. Sites that share a privacy address share one message.
public struct EmailBatch: Identifiable, Equatable, Sendable {
    public var address: String
    public var domains: [String]
    public var entryIDs: [String]
    public var id: String { address }

    public static func build(entries: [DirectoryEntry]) -> [EmailBatch] {
        var order: [String] = [], map: [String: EmailBatch] = [:]
        for e in entries {
            guard let a = e.contactEmail?.lowercased() else { continue }
            if map[a] == nil { map[a] = EmailBatch(address: a, domains: [], entryIDs: []); order.append(a) }
            map[a]!.domains.append(e.domain); map[a]!.entryIDs.append(e.id)
        }
        return order.map { map[$0]! }
    }

    public var subject: String { "Opt-out and deletion request" }

    /// The message, always in English (brokers read English): who is asking, what they ask for, which sites it covers. The person reads it before sending.
    public func body(name: String, email: String, address street: String) -> String {
        var lines = ["Hello,", "",
                     "I am writing to opt out of the sale and sharing of my personal information, to opt out of targeted advertising and profiling, and to ask you to delete the personal information you hold about me.", "",
                     "Name: \(name)", "Email: \(email)", "Address: \(street)", ""]
        lines.append(domains.count > 1 ? "This request covers each of these sites and brands:" : "This request covers this site:")
        lines += domains.map { "- \($0)" }
        lines += ["", "Please confirm by email when this is done.", "", "Thank you."]
        return lines.joined(separator: "\n")
    }
}
