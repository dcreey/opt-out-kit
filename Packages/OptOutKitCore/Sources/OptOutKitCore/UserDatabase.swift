import Foundation
import SQLite3

/// Everything the app keeps for the person lives in one SQLite file: the household (profiles, progress, settings), the screenshots of what each site showed, the
/// profile being typed, and the small preferences (`StoredPreferences`). Each row holds one sealed blob, AES-256-GCM with the Keychain key (`SealedStore`), exactly the bytes the separate files used to hold
/// (until build 52: household.sealed, household.evidence/, profile-draft.sealed), so nothing is stored in plaintext. `HouseholdStore`, `EvidenceStore` and
/// `ProfileDraftStore` are the ways in; the app does no other file work while it runs (docs/PERSISTENCE.md).
///
/// - **Atomic**: a write is one SQLite transaction, as the files were written atomically; a crash leaves the old value or the new, never half.
/// - **Data protection**: the file and its journal are readable after the first unlock since the phone started (`SQLITE_OPEN_FILEPROTECTION_...`), as the
///   files were, so the automatic run keeps what it did while the phone is locked in a pocket. Before that first unlock opening fails and is reported as
///   `StorageError.locked`, which callers put off until the unlock, never show as damage and never take for a reason to erase.
/// - **Erase means erase**: `secure_delete` overwrites what a delete frees, and `auto_vacuum` gives the pages back, so a removed screenshot is not left in the file.
public final class UserDatabase: @unchecked Sendable {
    public enum Kind: String, Sendable { case household, draft, evidence, setting, runLog }

    public enum DatabaseError: Error, CustomStringConvertible {
        case sqlite(String)
        public var description: String { if case .sqlite(let m) = self { return "storage: \(m)" }; return "storage" }
    }

    /// The layout of the file (`PRAGMA user_version`). A file of a newer layout than this build knows is refused rather than guessed at (a downgrade).
    public static let schemaVersion: Int32 = 1

    public let url: URL
    private var db: OpaquePointer?
    private let lock = NSLock()
    private var legacyImported = false

    public init(url: URL) { self.url = url }
    deinit { if let db { sqlite3_close(db) } }

    // MARK: Opening

    /// The open connection, opened on first use. Called with the lock held.
    private func connection() throws -> OpaquePointer {
        if let db { return db }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        #if os(iOS)
        flags |= SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION          // the file and its journal, as the files were
        #endif
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let error = Self.error(handle, rc)
            if let handle { sqlite3_close(handle) }
            throw error
        }
        do {
            // Opening a file that is already there changes nothing in it (even setting auto_vacuum again rewrites the header, so it is set only on a new file):
            // a household that could not be read is never touched, not even by being opened.
            var pages: Int64 = 0
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(opened, "PRAGMA page_count", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW { pages = sqlite3_column_int64(stmt, 0) }
            sqlite3_finalize(stmt)
            if pages == 0 { try Self.exec(opened, "PRAGMA auto_vacuum = FULL; PRAGMA user_version = \(Self.schemaVersion)") }
            var version: Int32 = 0
            if sqlite3_prepare_v2(opened, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW { version = sqlite3_column_int(stmt, 0) }
            sqlite3_finalize(stmt)
            guard version <= Self.schemaVersion else { throw DatabaseError.sqlite("the database is of a newer layout (\(version)) than this build reads (\(Self.schemaVersion))") }
            sqlite3_busy_timeout(opened, 5000)          // the household and the preferences share the file: wait for each other instead of failing
            try Self.exec(opened, "PRAGMA secure_delete = ON; PRAGMA synchronous = FULL;")
            try Self.exec(opened, "CREATE TABLE IF NOT EXISTS sealed (kind TEXT NOT NULL, key TEXT NOT NULL, body BLOB NOT NULL, saved REAL NOT NULL, PRIMARY KEY (kind, key)) WITHOUT ROWID")
        } catch {
            sqlite3_close(opened)
            throw error
        }
        db = opened
        return opened
    }

    /// What a failed call was: the phone being locked (the file's data protection refused it: permission denied), or a fault.
    private static func error(_ db: OpaquePointer?, _ rc: Int32) -> Error {
        let errno = db.map { sqlite3_system_errno($0) } ?? 0
        if errno == EPERM || errno == EACCES || rc == SQLITE_PERM || rc == SQLITE_AUTH { return StorageError.locked }
        return DatabaseError.sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error \(rc)")
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        if rc != SQLITE_OK { throw error(db, rc) }
    }

    /// Runs one statement with the given values bound, calling `row` for each row it returns.
    private func run(_ sql: String, _ values: [Any] = [], row: ((OpaquePointer) -> Void)? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let db = try connection()
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK else { throw Self.error(db, rc) }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, v) in values.enumerated() {
            let at = Int32(i + 1)
            switch v {
            case let n as Int: sqlite3_bind_int64(stmt, at, Int64(n))
            case let t as String: sqlite3_bind_text(stmt, at, t, -1, transient)
            case let d as Data: _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, at, $0.baseAddress, Int32(d.count), transient) }
            case let x as Double: sqlite3_bind_double(stmt, at, x)
            default: throw DatabaseError.sqlite("cannot bind \(type(of: v))")
            }
        }
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW { row?(stmt!); continue }
            if step == SQLITE_DONE { break }
            throw Self.error(db, step)
        }
    }

    // MARK: Rows

    /// Stores (or replaces) one sealed blob, as one transaction.
    public func put(_ kind: Kind, key: String = "", _ body: Data, saved: Date = Date()) throws {
        try run("INSERT OR REPLACE INTO sealed (kind, key, body, saved) VALUES (?, ?, ?, ?)", [kind.rawValue, key, body, saved.timeIntervalSince1970])
    }

    /// The sealed blob, or nil when there is none. Throws when the database cannot be opened (locked or damaged), so callers never take that for "nothing saved".
    public func get(_ kind: Kind, key: String = "") throws -> Data? {
        var out: Data?
        try run("SELECT body FROM sealed WHERE kind = ? AND key = ?", [kind.rawValue, key]) { stmt in
            let n = Int(sqlite3_column_bytes(stmt, 0))
            out = n == 0 ? Data() : sqlite3_column_blob(stmt, 0).map { Data(bytes: $0, count: n) }
        }
        return out
    }

    /// Every blob of a kind, with its key.
    public func all(_ kind: Kind) throws -> [(key: String, body: Data)] {
        var out: [(String, Data)] = []
        try run("SELECT key, body FROM sealed WHERE kind = ?", [kind.rawValue]) { stmt in
            let key = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let n = Int(sqlite3_column_bytes(stmt, 1))
            out.append((key, n == 0 ? Data() : sqlite3_column_blob(stmt, 1).map { Data(bytes: $0, count: n) } ?? Data()))
        }
        return out
    }

    /// When the blob was stored.
    public func saved(_ kind: Kind, key: String = "") throws -> Date? {
        var out: Date?
        try run("SELECT saved FROM sealed WHERE kind = ? AND key = ?", [kind.rawValue, key]) { out = Date(timeIntervalSince1970: sqlite3_column_double($0, 0)) }
        return out
    }

    public func exists(_ kind: Kind, key: String = "") -> Bool { ((try? saved(kind, key: key)) ?? nil) != nil }

    public func delete(_ kind: Kind, key: String = "") throws { try run("DELETE FROM sealed WHERE kind = ? AND key = ?", [kind.rawValue, key]) }

    /// Deletes every blob of a kind whose key starts with `prefix` (all of them for an empty prefix).
    public func deleteAll(_ kind: Kind, keyPrefix prefix: String = "") throws {
        try run("DELETE FROM sealed WHERE kind = ? AND substr(key, 1, ?) = ?", [kind.rawValue, prefix.count, prefix])
    }

    /// Deletes the blobs of a kind stored before `date`.
    public func delete(_ kind: Kind, savedBefore date: Date) throws {
        try run("DELETE FROM sealed WHERE kind = ? AND saved < ?", [kind.rawValue, date.timeIntervalSince1970])
    }

    // MARK: The move from the separate files (build 51 and earlier)

    /// Where the household, its screenshots and the profile draft were kept as separate files until build 52.
    public struct LegacyFiles: Sendable {
        public var household: URL
        public var evidence: URL
        public var draft: URL
        public init(household: URL, evidence: URL, draft: URL) { self.household = household; self.evidence = evidence; self.draft = draft }
    }

    /// Moves what the old files hold into the database, once per run: each file's sealed bytes are stored as they are (nothing is decrypted or re-encoded),
    /// read back and compared, and only then is the file deleted. A file that cannot be read yet (the phone is locked) stays where it is and throws
    /// `StorageError.locked`, so nothing is saved over a household that was not read; the move is tried again at the next unlock. When both the file and a row
    /// exist (an earlier move stopped half way, or an older build was run in between) the newer one is kept.
    public func importLegacy(_ legacy: LegacyFiles, evidenceKey: (_ person: String, _ site: String) throws -> String) throws {
        lock.lock()
        if legacyImported { lock.unlock(); return }
        lock.unlock()
        let fm = FileManager.default
        func move(_ file: URL, kind: Kind, key: String) throws {
            guard fm.fileExists(atPath: file.path) else { return }
            let bytes: Data
            do { bytes = try Data(contentsOf: file) }
            catch { throw StorageError.isLocked(error) ? StorageError.locked : error }
            let fileDate = (try? fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? Date()
            if let rowDate = try saved(kind, key: key), rowDate >= fileDate, try get(kind, key: key) != nil {
                try fm.removeItem(at: file)          // the database already holds this, newer: the file is what an earlier move left behind
                return
            }
            try put(kind, key: key, bytes, saved: fileDate)
            guard try get(kind, key: key) == bytes else { throw DatabaseError.sqlite("the moved \(kind.rawValue) did not read back the same") }
            try fm.removeItem(at: file)
        }
        try move(legacy.household, kind: .household, key: "")
        try move(legacy.draft, kind: .draft, key: "")
        if let people = try? fm.contentsOfDirectory(at: legacy.evidence, includingPropertiesForKeys: nil) {
            for person in people {
                for file in (try? fm.contentsOfDirectory(at: person, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasSuffix(".jpg.sealed") {
                    let site = String(file.lastPathComponent.dropLast(".jpg.sealed".count))
                    try move(file, kind: .evidence, key: try evidenceKey(person.lastPathComponent, site))
                }
                if ((try? fm.contentsOfDirectory(atPath: person.path)) ?? ["x"]).isEmpty { try? fm.removeItem(at: person) }
            }
            if ((try? fm.contentsOfDirectory(atPath: legacy.evidence.path)) ?? ["x"]).isEmpty { try? fm.removeItem(at: legacy.evidence) }
        }
        lock.lock(); legacyImported = true; lock.unlock()
    }
}
