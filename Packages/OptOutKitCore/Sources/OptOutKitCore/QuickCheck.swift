import Foundation

/// Quick checks: which sites a person can look themselves up on, and where. (The points these looks earned were taken off with the Sites tab's points
/// card on 2026-11-24.)
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
