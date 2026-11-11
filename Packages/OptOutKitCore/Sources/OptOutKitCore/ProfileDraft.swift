import Foundation

/// What the person has typed into the profile editor but not yet saved to their profile. Written a moment after typing stops, sealed with the same key as the
/// household, so an app that is closed or crashes in the middle of a first profile gets it back instead of an empty form. Removed the moment the profile is saved.
public struct ProfileDraft: Codable, Equatable, Sendable {
    public var personID: UUID
    public var person: Person
    /// The household email as typed (only meaningful on the owner's profile).
    public var email: String
    public var savedAt: Date
    public init(personID: UUID, person: Person, email: String, savedAt: Date = Date()) {
        self.personID = personID; self.person = person; self.email = email; self.savedAt = savedAt
    }
}

public struct ProfileDraftStore {
    public let url: URL
    private let keys: KeyProviding
    public init(url: URL, keys: KeyProviding) { self.url = url; self.keys = keys }

    public func save(_ draft: ProfileDraft) throws {
        let sealed = try SealedStore.seal(JSONEncoder().encode(draft), key: keys.key())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        // Readable after the first unlock, so a write as the phone locks still lands.
        try sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try sealed.write(to: url, options: [.atomic])
        #endif
    }

    /// The saved draft, or nil when there is none or it cannot be read (a draft is never worth stopping the app for).
    public func load() -> ProfileDraft? {
        guard FileManager.default.fileExists(atPath: url.path),
              let plain = try? SealedStore.open(Data(contentsOf: url), key: keys.key()) else { return nil }
        return try? JSONDecoder().decode(ProfileDraft.self, from: plain)
    }

    public func clear() { try? FileManager.default.removeItem(at: url) }
}
