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

/// The whole household as one encrypted file on the device. Nothing is written in plaintext.
public struct HouseholdStore {
    public let url: URL
    private let keys: KeyProviding

    public init(url: URL, keys: KeyProviding) {
        self.url = url
        self.keys = keys
    }

    /// The same key, for other things kept sealed beside the household (the screenshots of what each site showed).
    public var keyProvider: KeyProviding { keys }

    /// Nil when nothing has been saved yet. Throws when the file exists but cannot be opened
    /// (wrong key, corruption), so callers never overwrite data they could not read.
    public func load() throws -> Household? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let plain = try SealedStore.open(Data(contentsOf: url), key: keys.key())
        return try JSONDecoder().decode(Household.self, from: plain)
    }

    public func save(_ household: Household) throws {
        let sealed = try SealedStore.seal(JSONEncoder().encode(household), key: keys.key())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        // iOS data protection: unreadable until the phone is first unlocked after it starts. Not "complete" (unreadable whenever locked): the
        // automatic run works while the phone is locked in a pocket or charging overnight, and must be able to keep what it did.
        try sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try sealed.write(to: url, options: [.atomic])   // macOS (tests, tools) has no per-file data protection
        #endif
    }

    public func erase() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
