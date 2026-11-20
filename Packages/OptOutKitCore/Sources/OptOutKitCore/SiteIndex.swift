import Foundation

/// The sites, looked up by id, by domain and by family, built once when the list changes. The app keeps every site in memory (the plan, the
/// automatic run and the activity page each work over all of them); this is how one site is found in it. Until 2026-11-20 each lookup scanned the
/// list or rebuilt a dictionary of it, and some did so for every site (`isDone` from the Sites rows: about 829 x 829 comparisons each time).
public struct SiteIndex: Sendable {
    public let entries: [DirectoryEntry]
    public let byID: [String: DirectoryEntry]
    public let byDomain: [String: DirectoryEntry]
    private let familySizes: [String: Int]

    public init(_ entries: [DirectoryEntry]) {
        self.entries = entries
        // The first entry wins a repeated id or domain, as `first(where:)` did.
        byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        byDomain = Dictionary(entries.map { ($0.domain, $0) }, uniquingKeysWith: { a, _ in a })
        familySizes = entries.reduce(into: [:]) { sizes, e in if let f = e.family { sizes[f, default: 0] += 1 } }
    }

    public subscript(id id: String) -> DirectoryEntry? { byID[id] }
    public subscript(domain domain: String) -> DirectoryEntry? { byDomain[domain] }

    /// The entries for these domains, in the given order; a domain with no entry is left out.
    public func entries<S: Sequence>(domains: S) -> [DirectoryEntry] where S.Element == String { domains.compactMap { byDomain[$0] } }

    /// How many sites share this entry's opt-out (itself included), or 1 when it stands alone (`Directory.familySize`, without scanning).
    public func familySize(of entry: DirectoryEntry) -> Int { entry.family.map { familySizes[$0] ?? 1 } ?? 1 }
}
