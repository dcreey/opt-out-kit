import Foundation
import OptOutKitCore

/// Picks, from the addresses found on a site's own page, the one a privacy request should go to. Only an address on the site's own domain counts, never a
/// mail-service or tracking address, and an address that says privacy or opt-out beats a general one.
enum ContactEmailPicker {
    static func best(_ candidates: [String], pageHost: String) -> String? {
        let root = registrable(pageHost)
        guard !root.isEmpty else { return nil }
        let blocked = try! NSRegularExpression(pattern: "^(no.?reply|donotreply|do-not-reply|mailer-daemon|postmaster|abuse|webmaster|sentry|example|user|name|you|your)\\b|@(sentry|wixpress|example|domain|email|yourdomain)\\.", options: .caseInsensitive)
        var seen = Set<String>(), ok: [String] = []
        for raw in candidates {
            let a = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:<>()[]\"'")).lowercased()
            guard a.contains("@"), a.range(of: "^[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}$", options: .regularExpression) != nil, seen.insert(a).inserted else { continue }
            let host = String(a.split(separator: "@").last ?? "")
            guard host == root || host.hasSuffix("." + root) else { continue }
            if blocked.firstMatch(in: a, range: NSRange(a.startIndex..., in: a)) != nil { continue }
            ok.append(a)
        }
        let order = ["privacy", "optout", "opt-out", "dpo", "ccpa", "dsar", "rights", "legal", "compliance", "data", "consumer", "support", "contact", "info"]
        func rank(_ a: String) -> Int { let local = String(a.split(separator: "@").first ?? ""); return order.firstIndex { local.contains($0) } ?? order.count }
        return ok.enumerated().min { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }?.element
    }

    private static func registrable(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let secondLevel: Set<String> = ["co", "com", "org", "net", "gov", "ac"]
        let n = (secondLevel.contains(labels[labels.count - 2]) && labels[labels.count - 1].count == 2) ? 3 : 2
        return labels.suffix(n).joined(separator: ".")
    }
}
