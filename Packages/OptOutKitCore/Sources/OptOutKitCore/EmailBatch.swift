import Foundation

/// One opt-out email: the addresses it goes to (all in Bcc, so no broker sees another) and every site it covers.
public struct EmailBatch: Identifiable, Equatable, Sendable {
    public var address: String           // the first address, or the only one
    public var addresses: [String]       // every distinct address, in order
    public var domains: [String]
    public var entryIDs: [String]
    public var id: String { addresses.joined(separator: ",") }

    /// Gmail accepts at most 500 recipients in one message, and long Bcc lists look like spam, so a very large list is split.
    public static let maxRecipients = 400

    /// One message for everything, or as few as the recipient limit allows.
    public static func single(entries: [DirectoryEntry], maxRecipients: Int = EmailBatch.maxRecipients) -> [EmailBatch] {
        let perAddress = build(entries: entries)
        var out: [EmailBatch] = [], cur: EmailBatch?
        for b in perAddress {
            if var c = cur, c.addresses.count < maxRecipients {
                c.addresses.append(b.address); c.domains += b.domains; c.entryIDs += b.entryIDs; cur = c
            } else {
                if let c = cur { out.append(c) }
                cur = EmailBatch(address: b.address, addresses: [b.address], domains: b.domains, entryIDs: b.entryIDs)
            }
        }
        if let c = cur { out.append(c) }
        return out
    }

    public static func build(entries: [DirectoryEntry]) -> [EmailBatch] {
        var order: [String] = [], map: [String: EmailBatch] = [:]
        for e in entries {
            guard let a = e.contactEmail?.lowercased() else { continue }
            if map[a] == nil { map[a] = EmailBatch(address: a, addresses: [a], domains: [], entryIDs: []); order.append(a) }
            map[a]!.domains.append(e.domain); map[a]!.entryIDs.append(e.id)
        }
        return order.map { map[$0]! }
    }

    public var subject: String { "Opt-out and deletion request" }

    /// The message, always in English (brokers read English): who is asking, what they ask for, which sites it covers. The person reads it before sending.
    public func body(name: String, email: String, address street: String) -> String {
        var lines = [addresses.count > 1 ? "Dear Privacy Team," : "Hello,", "",
                     "I am writing to opt out of the sale and sharing of my personal information, to opt out of targeted advertising and profiling, and to ask you to delete the personal information you hold about me.", "",
                     "Name: \(name)", "Email: \(email)", "Address: \(street)", ""]
        lines.append(domains.count > 1 ? "This request applies to each of these sites and brands, wherever you operate them. Please act on those you operate or own:" : "This request covers this site:")
        lines += domains.map { "- \($0)" }
        lines += ["", "Please confirm by email when this is done.", "", "Thank you."]
        return lines.joined(separator: "\n")
    }
}
