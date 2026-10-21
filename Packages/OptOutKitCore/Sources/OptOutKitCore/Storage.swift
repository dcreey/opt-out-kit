import Foundation
import CryptoKit

public enum StorageError: Error, Equatable {
    case badHeader
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
        try sealed.write(to: url, options: [.atomic, .completeFileProtection])   // iOS data protection: unreadable while locked
        #else
        try sealed.write(to: url, options: [.atomic])   // macOS (tests, tools) has no per-file data protection
        #endif
    }

    public func erase() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
