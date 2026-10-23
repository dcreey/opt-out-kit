import Foundation

/// Screenshots of what each site showed when an automatic opt-out finished, kept sealed with the household's key (they can show the
/// person's name and address). The latest one per person and site is kept; the person reviews them to confirm what happened.
public struct EvidenceStore: Sendable {
    public let directory: URL
    private let keys: KeyProviding

    public init(directory: URL, keys: KeyProviding) { self.directory = directory; self.keys = keys }

    private func file(person: UUID, site: String) -> URL {
        let safe = site.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(person.uuidString).appendingPathComponent(safe + ".jpg.sealed")
    }

    public func save(_ jpeg: Data, person: UUID, site: String) throws {
        let url = file(person: person, site: site)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sealed = try SealedStore.seal(jpeg, key: keys.key())
        #if os(iOS)
        try sealed.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try sealed.write(to: url, options: [.atomic])
        #endif
    }

    public func load(person: UUID, site: String) -> Data? {
        guard let data = try? Data(contentsOf: file(person: person, site: site)), let key = try? keys.key() else { return nil }
        return try? SealedStore.open(data, key: key)
    }

    public func exists(person: UUID, site: String) -> Bool { FileManager.default.fileExists(atPath: file(person: person, site: site).path) }

    /// Removes one person's screenshots (when they are deleted from the app).
    public func removeAll(person: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(person.uuidString))
    }

    /// Removes screenshots older than `days`.
    public func prune(olderThan days: Int, now: Date = Date()) {
        guard let people = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for p in people {
            for f in (try? FileManager.default.contentsOfDirectory(at: p, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
                if now.timeIntervalSince(date) > Double(days) * 86_400 { try? FileManager.default.removeItem(at: f) }
            }
        }
    }
}
