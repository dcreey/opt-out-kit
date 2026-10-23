import Foundation

/// The mail apps we can open with a message already written. Each has its own link format; Mail is the system composer.
public enum MailApp: String, CaseIterable, Sendable {
    case mail, gmail, outlook, yahoo, spark, proton, other

    public var name: String {
        switch self {
        case .mail: return "Mail"
        case .gmail: return "Gmail"
        case .outlook: return "Outlook"
        case .yahoo: return "Yahoo Mail"
        case .spark: return "Spark"
        case .proton: return "Proton Mail"
        case .other: return "Another mail app"
        }
    }

    /// The scheme to ask iOS about before offering this app (must be listed in `LSApplicationQueriesSchemes`).
    public var probeScheme: String? {
        switch self {
        case .gmail: return "googlegmail"
        case .outlook: return "ms-outlook"
        case .yahoo: return "ymail"
        case .spark: return "readdle-spark"
        case .proton: return "protonmail"
        case .mail, .other: return nil
        }
    }

    public static var probeSchemes: [String] { allCases.compactMap(\.probeScheme) }

    /// The link that opens this app's compose screen with everything filled in. Bcc is supported by Gmail, Outlook and plain `mailto:`;
    /// for the others the Bcc list is carried the same way and the app is expected to honor it (checked before release).
    public func composeURL(to: String, bcc: [String], subject: String, body: String) -> URL? {
        func items(_ names: (to: String, bcc: String, subject: String, body: String)) -> [URLQueryItem] {
            var q = [URLQueryItem(name: names.subject, value: subject), URLQueryItem(name: names.body, value: body)]
            if !to.isEmpty { q.insert(URLQueryItem(name: names.to, value: to), at: 0) }
            if !bcc.isEmpty { q.insert(URLQueryItem(name: names.bcc, value: bcc.joined(separator: ",")), at: 1) }
            return q
        }
        var c = URLComponents()
        switch self {
        case .gmail:
            c.scheme = "googlegmail"; c.host = ""; c.path = "/co"; c.queryItems = items(("to", "bcc", "subject", "body"))
        case .outlook:
            c.scheme = "ms-outlook"; c.host = "compose"; c.queryItems = items(("to", "bcc", "subject", "body"))
        case .yahoo:
            c.scheme = "ymail"; c.host = "mail"; c.path = "/compose"; c.queryItems = items(("to", "bcc", "subject", "body"))
        case .spark:
            c.scheme = "readdle-spark"; c.host = "compose"; c.queryItems = items(("recipient", "bcc", "subject", "body"))
        case .proton:
            c.scheme = "protonmail"; c.host = ""; c.path = ""
            return URL(string: "protonmail://mailto:" + (to.isEmpty ? "" : to) + "?" + Self.query(items(("to", "bcc", "subject", "body")).filter { $0.name != "to" }))
        case .mail, .other:
            c.scheme = "mailto"; c.path = to; c.queryItems = items(("to", "bcc", "subject", "body")).filter { $0.name != "to" }
        }
        return c.url
    }

    private static func query(_ items: [URLQueryItem]) -> String {
        var c = URLComponents(); c.queryItems = items; return c.percentEncodedQuery ?? ""
    }
}
