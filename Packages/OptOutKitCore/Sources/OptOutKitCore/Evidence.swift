import CryptoKit
import Foundation

/// Screenshots of what each site showed when an automatic opt-out finished, kept sealed with the household's key (they can show the
/// person's name and address), as rows of the app's database (`UserDatabase`). The latest one per person and site is kept; the person reviews them to confirm
/// what happened.
public struct EvidenceStore: Sendable {
    private let database: UserDatabase
    private let keys: KeyProviding

    public init(database: UserDatabase, keys: KeyProviding) { self.database = database; self.keys = keys }

    /// The row's key. It is opaque: a keyed hash of the person and of the site, so the database does not say which people or which sites have a screenshot
    /// (the old files' names did). The same person gives the same prefix, which is how one person's screenshots are removed together.
    static func rowKey(person: String, site: String, key: SymmetricKey) -> String {
        personPrefix(person: person, key: key) + tag("site:", site.replacingOccurrences(of: "/", with: "_"), key)
    }

    /// What every row key of this person starts with ("<hash of the person>/").
    static func personPrefix(person: String, key: SymmetricKey) -> String { tag("person:", person.uppercased(), key) + "/" }

    private static func tag(_ label: String, _ text: String, _ key: SymmetricKey) -> String {
        let sub = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data("exnay.evidence.row-key.v1".utf8), outputByteCount: 32)
        return HMAC<SHA256>.authenticationCode(for: Data((label + text).utf8), using: sub).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func key(person: UUID, site: String) throws -> String { Self.rowKey(person: person.uuidString, site: site, key: try keys.key()) }

    public func save(_ jpeg: Data, person: UUID, site: String) throws {
        try database.put(.evidence, key: try key(person: person, site: site), try SealedStore.seal(jpeg, key: keys.key()))      // written by runs while the phone is locked
    }

    public func load(person: UUID, site: String) -> Data? {
        guard let k = try? keys.key(), let rowKey = try? key(person: person, site: site), let data = (try? database.get(.evidence, key: rowKey)) ?? nil else { return nil }
        return try? SealedStore.open(data, key: k)
    }

    public func exists(person: UUID, site: String) -> Bool { (try? key(person: person, site: site)).map { database.exists(.evidence, key: $0) } ?? false }

    /// Removes one person's screenshots (when they are deleted from the app).
    public func removeAll(person: UUID) {
        guard let k = try? keys.key() else { return }
        try? database.deleteAll(.evidence, keyPrefix: Self.personPrefix(person: person.uuidString, key: k))
    }

    /// Removes every screenshot (when the app is reset).
    public func removeEverything() { try? database.deleteAll(.evidence) }

    /// Removes screenshots older than `days`.
    public func prune(olderThan days: Int, now: Date = Date()) {
        try? database.delete(.evidence, savedBefore: now.addingTimeInterval(-Double(days) * 86_400))
    }
}
