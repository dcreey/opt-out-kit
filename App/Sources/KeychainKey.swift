import Foundation
import CryptoKit
import Security
import OptOutKitCore

/// Keeps the data-encryption key in the iOS Keychain. It is created on first use and readable only while the
/// phone is unlocked. It is deliberately not "ThisDeviceOnly": an ordinary encrypted iPhone backup carries it,
/// so a user who backs up their phone can restore their profiles. It is never synced through iCloud Keychain.
struct KeychainKey: KeyProviding {
    var service = "dev.optoutkit.app.storage"
    var account = "household-key"

    enum KeychainError: Error { case status(OSStatus) }

    func key() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { throw KeychainError.status(status) }

        let fresh = SealedStore.newKey()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: fresh.withUnsafeBytes { Data($0) },
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.status(added) }
        return fresh
    }
}
