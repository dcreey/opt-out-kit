import Foundation
import SQLite3

/// Everything the app knows that ships with it (the sites, the hand-written flows, the official removal services, the laws by place, the registry counts,
/// the reviewed terms), compiled at build time from the YAML in the repository into one read-only SQLite file, `Catalog.sqlite`, in the app's bundle.
/// The app never parses YAML on the phone: it reads this file (`AppModel`). Parsing the 855 site files with YAML took 0.14 to 0.23 s on a Mac, on the main
/// thread at every launch; decoding the same entries from here takes a few hundredths. The build step (`catalog-builder`, run by the `CatalogPlugin` build
/// tool) loads the YAML with the same loaders the tests use, so the catalog holds exactly what they return, and a bad file fails the build. docs/DIRECTORY.md.
public enum Catalog {
    /// The layout of the file. Raised when the tables change; the app reads only a catalog of its own version (they ship together).
    public static let schemaVersion: Int32 = 3          // 2: the site_search full-text index; 3: scripts and zips
    public static let fileName = "Catalog.sqlite"

    /// What the catalog holds, as the app uses it.
    public struct Contents: Equatable, Sendable {
        public var sites: [DirectoryEntry]
        public var brokers: [Broker]
        public var platforms: [Platform]
        public var jurisdictions: [Jurisdiction]
        public var registrySummary: RegistrySummary?
        public var termsLibrary: TermsLibrary?
        public init(sites: [DirectoryEntry], brokers: [Broker], platforms: [Platform], jurisdictions: [Jurisdiction],
                    registrySummary: RegistrySummary?, termsLibrary: TermsLibrary?) {
            self.sites = sites; self.brokers = brokers; self.platforms = platforms; self.jurisdictions = jurisdictions
            self.registrySummary = registrySummary; self.termsLibrary = termsLibrary
        }
    }

    public enum CatalogError: Error, CustomStringConvertible {
        case sqlite(String)
        case wrongVersion(found: Int32)
        public var description: String {
            switch self {
            case .sqlite(let m): return "catalog: \(m)"
            case .wrongVersion(let v): return "catalog: schema version \(v), the app reads \(Catalog.schemaVersion)"
            }
        }
    }

    /// The full-text query for what a person typed: every word must match, each as the start of a word ("spok" finds Spokeo), in any order.
    /// Nil when nothing searchable was typed.
    public static func searchQuery(_ text: String) -> String? {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }


    // MARK: The process-wide handle (page scripts and the ZIP table)

    /// The catalog the app is running with, opened read-only once: what is looked up one row at a time (a page script, a ZIP code) goes through it instead
    /// of being loaded into memory or read from a file. Nil until `use` is called (the app does at launch).
    private final class Handle: @unchecked Sendable {
        let db: OpaquePointer
        let lock = NSLock()
        init(db: OpaquePointer) { self.db = db }
        deinit { sqlite3_close(db) }
    }
    nonisolated(unsafe) private static var shared: Handle?
    private static let sharedLock = NSLock()

    /// Opens the catalog at `url` read-only for the rest of the run (replacing a catalog opened before: tests do).
    public static func use(_ url: URL) throws {
        let handle = try withDatabase(url, keepOpen: true) { Handle(db: $0) }
        sharedLock.lock(); shared = handle; sharedLock.unlock()
    }

    private static var handle: Handle? { sharedLock.lock(); defer { sharedLock.unlock() }; return shared }

    /// One text column of the first row the query returns (bound to `key`), through the shared handle; nil when there is no row or no catalog.
    private static func lookup(_ sql: String, _ key: String) -> [String]? {
        guard let h = handle else { return nil }
        h.lock.lock(); defer { h.lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h.db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (0..<sqlite3_column_count(stmt)).map { sqlite3_column_text(stmt, $0).map { String(cString: $0) } ?? "" }
    }

    /// The source text of a page script (App/PageScripts/<name>.js, compiled into the catalog), nil when there is none.
    public static func script(named name: String) -> String? { lookup("SELECT body FROM scripts WHERE name = ?", name)?.first }

    /// The names of every page script the catalog holds, sorted.
    public static func scriptNames() -> [String] {
        guard let h = handle else { return [] }
        h.lock.lock(); defer { h.lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h.db, "SELECT name FROM scripts ORDER BY name", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let c = sqlite3_column_text(stmt, 0) { names.append(String(cString: c)) } }
        return names
    }

    /// The city and state of a five-digit ZIP code, through the catalog's `zips` table (41,000 rows, found by key: none is held in memory).
    public static func zip(_ zip: String) -> (city: String, state: String)? {
        guard let row = lookup("SELECT city, state FROM zips WHERE zip = ?", zip), row.count == 2 else { return nil }
        return (row[0], row[1])
    }

    /// How many page scripts and ZIP codes the catalog at `url` holds (the build checks what it wrote).
    public static func counts(in url: URL) throws -> (scripts: Int, zips: Int) {
        try withDatabase(url) { db in
            func count(_ table: String) -> Int {
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_prepare_v2(db, "SELECT count(*) FROM \(table)", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
                return Int(sqlite3_column_int64(stmt, 0))
            }
            return (count("scripts"), count("zips"))
        }
    }

    // MARK: Reading (in the app)

    /// Opens the catalog read-only and immutable: SQLite then creates no journal or lock file beside it, which it could not do inside the app's
    /// signed, read-only bundle.
    static func withDatabase<T>(_ url: URL, keepOpen: Bool = false, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        var parts = URLComponents(); parts.scheme = "file"; parts.path = url.path; parts.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        let uri = parts.string ?? "file:\(url.path)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw CatalogError.sqlite("could not open \(url.lastPathComponent)")
        }
        var closeIt = !keepOpen
        defer { if closeIt { sqlite3_close(db) } }
        var stmt: OpaquePointer?
        var version: Int32 = 0
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW { version = sqlite3_column_int(stmt, 0) }
        sqlite3_finalize(stmt)
        guard version == schemaVersion else { closeIt = true; throw CatalogError.wrongVersion(found: version) }
        do { return try body(db) } catch { closeIt = true; throw error }
    }

    /// Every `body` the query returns, decoded, in the order the query gives.
    static func rows<T: Decodable>(_ db: OpaquePointer, _ sql: String, _ type: T.Type, binding: String? = nil) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw CatalogError.sqlite(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        if let binding { sqlite3_bind_text(stmt, 1, binding, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        let decoder = JSONDecoder()
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw CatalogError.sqlite(String(cString: sqlite3_errmsg(db))) }
            let n = Int(sqlite3_column_bytes(stmt, 0))
            guard let p = sqlite3_column_blob(stmt, 0) else { continue }
            out.append(try decoder.decode(T.self, from: Data(bytes: p, count: n)))
        }
        return out
    }

    /// Everything in the catalog. `includeExcluded`: also the sites kept out of the app (`excluded`), which the app never shows; the build's own check reads them.
    public static func contents(of url: URL, includeExcluded: Bool = false) throws -> Contents {
        try withDatabase(url) { db in
            Contents(sites: try rows(db, "SELECT body FROM sites \(includeExcluded ? "" : "WHERE excluded = 0 ")ORDER BY seq", DirectoryEntry.self),
                     brokers: try rows(db, "SELECT body FROM brokers ORDER BY seq", Broker.self),
                     platforms: try rows(db, "SELECT body FROM platforms ORDER BY seq", Platform.self),
                     jurisdictions: try rows(db, "SELECT body FROM jurisdictions ORDER BY seq", Jurisdiction.self),
                     registrySummary: try rows(db, "SELECT body FROM documents WHERE name = 'registry_summary'", RegistrySummary.self).first,
                     termsLibrary: try rows(db, "SELECT body FROM documents WHERE name = 'terms_library'", TermsLibrary.self).first)
        }
    }

    /// The sites a search finds, best first: their ids, ranked so a match in the name counts most, then the web address, then what the company is
    /// and holds, then its description (BM25). Excluded sites are not in the index. Empty when nothing searchable was typed.
    public static func search(_ text: String, in url: URL, limit: Int = 500) throws -> [String] {
        guard let query = searchQuery(text) else { return [] }
        return try withDatabase(url) { db in
            var stmt: OpaquePointer?
            let sql = "SELECT id FROM site_search WHERE site_search MATCH ? ORDER BY bm25(site_search, 0, 10, 8, 3, 1) LIMIT \(limit)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw CatalogError.sqlite(String(cString: sqlite3_errmsg(db))) }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, query, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            var ids: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW { if let c = sqlite3_column_text(stmt, 0) { ids.append(String(cString: c)) } }
            return ids
        }
    }

    /// One site by its domain, looked up through the index (nil when the catalog has no such site, or it is excluded).
    public static func site(domain: String, in url: URL) throws -> DirectoryEntry? {
        try withDatabase(url) { db in try rows(db, "SELECT body FROM sites WHERE domain = ? AND excluded = 0", DirectoryEntry.self, binding: domain.lowercased()).first }
    }
}
