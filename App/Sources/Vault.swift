import Foundation

/// Placeholder for the profile vault (name, emails, addresses, phones).
/// TODO: back with an encrypted store whose key lives in the Keychain; give each broker only the fields
/// its definition lists, and only after the user confirms a listing (docs/DESIGN.md, "Architecture").
protocol Vault {
    func value(for field: String) -> String?
}
