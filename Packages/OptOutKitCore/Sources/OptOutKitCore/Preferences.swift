import Foundation

/// The app's small preferences and "has seen this" flags (language, the tours, the day's batches, ...), read and written the way `UserDefaults` is, but kept as
/// rows of the app's database (`StoredPreferences`) instead of a property-list file, so the app does no file work while it runs (docs/STORAGE.md). The method
/// names are `UserDefaults`' own, so the code that uses them did not change; tests may still hand in a `UserDefaults` suite.
public protocol Preferences: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    func bool(forKey key: String) -> Bool
    func string(forKey key: String) -> String?
    func integer(forKey key: String) -> Int
    func double(forKey key: String) -> Double
    func array(forKey key: String) -> [Any]?
    func stringArray(forKey key: String) -> [String]?
    func data(forKey key: String) -> Data?
}

public extension Preferences {
    func bool(forKey key: String) -> Bool {
        switch object(forKey: key) {
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["yes", "true", "1"].contains(s.lowercased())
        default: return false
        }
    }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func integer(forKey key: String) -> Int {
        switch object(forKey: key) {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? 0
        default: return 0
        }
    }
    func double(forKey key: String) -> Double {
        switch object(forKey: key) {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s) ?? 0
        default: return 0
        }
    }
    func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
}

/// Preferences held in memory only (the fallback before the database is available, and for previews).
public final class MemoryPreferences: Preferences, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private let lock = NSLock()
    public init() {}
    public func object(forKey key: String) -> Any? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func set(_ value: Any?, forKey key: String) { lock.lock(); values[key] = value; lock.unlock() }
    public func removeObject(forKey key: String) { lock.lock(); values[key] = nil; lock.unlock() }
}

/// The preferences as rows of the app's database (`UserDatabase`, kind `setting`): all read once into memory, every change written through. A value is any
/// property-list value (a Bool, number, string, date, data, array or dictionary), stored as a binary property list so its type comes back as it went in.
/// Preferences are not sealed: they hold no personal data (the person's place and details are in the sealed household), and the app reads them while the
/// phone is locked, when the Keychain key is not available.
///
/// When the database cannot be opened yet (the phone has not been unlocked since it started) the preferences work in memory, and `reload()` at the unlock
/// brings in what is stored and writes what was set meanwhile.
public final class StoredPreferences: Preferences, @unchecked Sendable {
    private let database: UserDatabase
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var loaded = false
    private var unsaved = Set<String>()

    public init(database: UserDatabase) {
        self.database = database
        reload()
    }

    /// Reads every stored preference (once the database can be opened) and writes the ones set before that. Safe to call again.
    public func reload() {
        lock.lock(); defer { lock.unlock() }
        guard let rows = try? database.all(.setting) else { return }
        for (key, body) in rows where !unsaved.contains(key) {
            if let list = (try? PropertyListSerialization.propertyList(from: body, format: nil)) as? [Any], let value = list.first { values[key] = value }
        }
        loaded = true
        for key in unsaved { write(key) }
    }

    public func object(forKey key: String) -> Any? { lock.lock(); defer { lock.unlock() }; return values[key] }

    public func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        guard let value else { remove(key); return }
        guard PropertyListSerialization.propertyList(value, isValidFor: .binary) else { assertionFailure("preference \(key) is not a property-list value"); return }
        values[key] = value
        write(key)
    }

    public func removeObject(forKey key: String) { lock.lock(); defer { lock.unlock() }; remove(key) }

    private func remove(_ key: String) {
        values[key] = nil
        if (try? database.delete(.setting, key: key)) == nil { unsaved.insert(key) } else { unsaved.remove(key) }
    }

    /// Writes one preference through to the database (called with the lock held); one that cannot be written yet is kept to write at `reload()`.
    private func write(_ key: String) {
        guard let value = values[key], let body = try? PropertyListSerialization.data(fromPropertyList: [value], format: .binary, options: 0),
              (try? database.put(.setting, key: key, body)) != nil else { unsaved.insert(key); return }
        unsaved.remove(key)
    }

    // MARK: The move from UserDefaults (build 51 and earlier)

    /// Moves what the app kept in its `UserDefaults` domain into the database, once: each value is stored, read back and compared, and only then removed from
    /// `UserDefaults`. A value already stored here is kept (it is newer: the move runs before anything else is set). The system's own keys (Apple..., NS...)
    /// are left alone. Returns how many were moved.
    @discardableResult
    public func importLegacy(from defaults: UserDefaults, domain: String?) -> Int {
        guard let domain, let old = defaults.persistentDomain(forName: domain) else { return 0 }
        var moved = 0
        for (key, value) in old where !key.hasPrefix("Apple") && !key.hasPrefix("NS") && !key.hasPrefix("com.apple") && !key.hasPrefix("AK") {
            lock.lock(); let present = values[key] != nil; lock.unlock()
            if !present {
                guard PropertyListSerialization.propertyList(value, isValidFor: .binary) else { continue }
                set(value, forKey: key)
                guard let back = object(forKey: key), (back as AnyObject).isEqual(value), loaded, !unsavedContains(key) else { continue }          // not stored yet (locked): keep the old one
            }
            defaults.removeObject(forKey: key)
            moved += 1
        }
        return moved
    }

    private func unsavedContains(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return unsaved.contains(key) }
}
