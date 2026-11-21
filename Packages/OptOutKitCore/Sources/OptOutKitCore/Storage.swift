import Foundation
import CryptoKit

public enum StorageError: Error, Equatable {
    case badHeader
    /// The phone has not been unlocked since it was turned on, so iOS keeps the key (and the files) closed. Not a fault: it passes at the next unlock.
    case locked

    /// Whether a load or save failed only because the phone is locked: the key could not be read yet (`locked`), or iOS refused to open the file
    /// for its data protection. Such a failure is put off until the phone is unlocked, never shown as damage and never a reason to erase.
    public static func isLocked(_ error: Error) -> Bool {
        if let e = error as? StorageError { return e == .locked }
        let ns = error as NSError
        if ns.domain == NSOSStatusErrorDomain, ns.code == -25308 { return true }          // errSecInteractionNotAllowed
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError {
            let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { $0.domain == NSPOSIXErrorDomain ? $0.code : 0 } ?? 0
            return posix == Int(EPERM) || posix == 0
        }
        return false
    }
}

/// AES-256-GCM sealing for local data. Format: "OOK1" header (authenticated) + nonce + ciphertext + tag.
public enum SealedStore {
    private static let header = Data("OOK1".utf8)

    public static func newKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    public static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: header)
        return header + box.combined!
    }

    public static func open(_ sealed: Data, key: SymmetricKey) throws -> Data {
        guard sealed.starts(with: header) else { throw StorageError.badHeader }
        let box = try AES.GCM.SealedBox(combined: sealed.dropFirst(header.count))
        return try AES.GCM.open(box, using: key, authenticating: header)
    }
}

/// Supplies the encryption key. The app backs this with the Keychain; tests use a fixed key.
public protocol KeyProviding {
    func key() throws -> SymmetricKey
}

public struct FixedKey: KeyProviding {
    private let value: SymmetricKey
    public init(_ value: SymmetricKey = SealedStore.newKey()) { self.value = value }
    public func key() throws -> SymmetricKey { value }
}

/// The whole household as one sealed row of the app's database (`UserDatabase`). Nothing is written in plaintext.
public struct HouseholdStore {
    public let database: UserDatabase
    private let keys: KeyProviding
    private let legacy: UserDatabase.LegacyFiles?

    /// `url` is the database file. `legacy`: where build 51 and earlier kept the household, its screenshots and the profile draft as separate files; they are
    /// moved into the database the first time it is read (`UserDatabase.importLegacy`).
    public init(url: URL, keys: KeyProviding, legacy: UserDatabase.LegacyFiles? = nil) {
        self.database = UserDatabase(url: url)
        self.keys = keys
        self.legacy = legacy
    }

    public var url: URL { database.url }

    /// The same key, for other things kept sealed beside the household (the screenshots of what each site showed).
    public var keyProvider: KeyProviding { keys }

    /// Nil when nothing has been saved yet. Throws when the household exists but cannot be opened
    /// (wrong key, corruption, a locked phone), so callers never overwrite data they could not read.
    public func load() throws -> Household? {
        try moveLegacy()
        guard let sealed = try database.get(.household) else { return nil }
        let plain = try SealedStore.open(sealed, key: keys.key())
        return try JSONDecoder().decode(Household.self, from: plain)
    }

    public func save(_ household: Household) throws {
        // A household still in the old file is moved first: saving over it would lose it.
        try moveLegacy()
        try database.put(.household, try SealedStore.seal(JSONEncoder().encode(household), key: keys.key()))
    }

    public func erase() throws { try database.delete(.household) }

    /// Moves what the old files hold into the database (once per run), the screenshots under their opaque keys.
    private func moveLegacy() throws {
        guard let legacy else { return }
        try database.importLegacy(legacy) { person, site in EvidenceStore.rowKey(person: person, site: site, key: try keys.key()) }
    }
}
