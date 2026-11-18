import Foundation
import CryptoKit
import Security
import OptOutKitCore

/// Keeps the data-encryption key in the iOS Keychain. It is created on first use and readable once the phone has been unlocked after it starts
/// ("after first unlock"), so the automatic run can keep what it did while the phone is locked in a pocket or charging. Until that first unlock it
/// cannot be read, and a load or save waits for it (`StorageError.locked`). It is deliberately not "ThisDeviceOnly": an ordinary encrypted iPhone
/// backup carries it, so a user who backs up their phone can restore their profiles. It is never synced through iCloud Keychain.
struct KeychainKey: KeyProviding {
    var service = "dev.optoutkit.app.storage"
    var account = "household-key"

    enum KeychainError: Error { case status(OSStatus) }

    /// Read once per launch and kept in memory: every save used to read the Keychain again, and a save while the phone was locked failed.
    private static let cache = KeyCache()

    func key() throws -> SymmetricKey {
        let id = service + "|" + account
        if let key = Self.cache.get(id) { return key }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            upgradeAccessibility()
            let key = SymmetricKey(data: data)
            Self.cache.set(id, key)
            return key
        }
        if status == errSecInteractionNotAllowed { throw StorageError.locked }
        guard status == errSecItemNotFound else { throw KeychainError.status(status) }

        let fresh = SealedStore.newKey()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: fresh.withUnsafeBytes { Data($0) },
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecInteractionNotAllowed { throw StorageError.locked }
        guard added == errSecSuccess else { throw KeychainError.status(added) }
        Self.cache.set(id, fresh)
        return fresh
    }

    /// A key made by an earlier build was readable only while the phone is unlocked. It is moved to "after first unlock" the first time it is read
    /// (which is while the phone is unlocked). If that fails it is tried again at the next launch; the key itself is never changed.
    private func upgradeAccessibility() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock] as CFDictionary)
        if status == errSecSuccess { NSLog("KeychainKey: moved to after-first-unlock") }
    }
}

/// The keys read this launch.
private final class KeyCache: @unchecked Sendable {
    private let lock = NSLock(); private var keys: [String: SymmetricKey] = [:]
    func get(_ id: String) -> SymmetricKey? { lock.lock(); defer { lock.unlock() }; return keys[id] }
    func set(_ id: String, _ key: SymmetricKey) { lock.lock(); keys[id] = key; lock.unlock() }
}
