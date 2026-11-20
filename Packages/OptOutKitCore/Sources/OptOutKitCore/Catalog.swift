import Foundation
import SQLite3

/// Everything the app knows that ships with it (the sites, the hand-written flows, the official removal services, the laws by place, the registry counts,
/// the reviewed terms), compiled at build time from the YAML in the repository into one read-only SQLite file, `Catalog.sqlite`, in the app's bundle.
/// The app never parses YAML on the phone: it reads this file (`AppModel`). Parsing the 855 site files with YAML took 0.14 to 0.23 s on a Mac, on the main
/// thread at every launch; decoding the same entries from here takes a few hundredths. The build step (`catalog-builder`, run by the `CatalogPlugin` build
/// tool) loads the YAML with the same loaders the tests use, so the catalog holds exactly what they return, and a bad file fails the build. docs/DIRECTORY.md.
public enum Catalog {
    /// The layout of the file. Raised when the tables change; the app reads only a catalog of its own version (they ship together).
    public static let schemaVersion: Int32 = 2          // 2: the site_search full-text index
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

    // MARK: Building (at build time, on the Mac)

    /// Loads the repository's data folders with the app's own loaders: `directory/`, `brokers/`, `platforms/`, `jurisdictions/`,
    /// `registries/summary.json`, `terms/library.yml`. Any file that does not decode, or a repeated id, is an error.
    public static func load(repository root: URL) throws -> Contents {
        let summaryURL = root.appendingPathComponent("registries/summary.json")
        let termsURL = root.appendingPathComponent("terms/library.yml")
        return Contents(sites: try Registry.loadDirectory(root.appendingPathComponent("directory")),
                        brokers: try Registry.load(directory: root.appendingPathComponent("brokers")),
                        platforms: try PlatformLoader.load(directory: root.appendingPathComponent("platforms")),
                        jurisdictions: try JurisdictionLoader.load(directory: root.appendingPathComponent("jurisdictions")),
                        registrySummary: FileManager.default.fileExists(atPath: summaryURL.path) ? JurisdictionLoader.loadSummary(summaryURL) : nil,
                        termsLibrary: FileManager.default.fileExists(atPath: termsURL.path) ? try TermsLibrary.load(termsURL) : nil)
    }

    /// Writes the contents to a new catalog file at `url` (replacing one that is there). Each row keeps the entry as JSON with the columns the app looks up
    /// by beside it, and its position, so the app gets the entries back in the order the loaders gave them.
    public static func write(_ c: Contents, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else {
            throw CatalogError.sqlite("could not create \(url.path)")
        }
        defer { sqlite3_close(db) }
        func exec(_ sql: String) throws {
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { throw CatalogError.sqlite(String(cString: sqlite3_errmsg(db))) }
        }
        // A plain rollback journal (not WAL), so the finished file is one self-contained file the app can open read-only inside its signed bundle.
        try exec("PRAGMA journal_mode = DELETE; PRAGMA user_version = \(schemaVersion);")
        try exec("""
            CREATE TABLE sites (seq INTEGER NOT NULL, id TEXT PRIMARY KEY, domain TEXT NOT NULL, name TEXT NOT NULL, excluded INTEGER NOT NULL, body BLOB NOT NULL);
            CREATE INDEX sites_domain ON sites (domain);
            CREATE TABLE brokers (seq INTEGER NOT NULL, id TEXT PRIMARY KEY, body BLOB NOT NULL);
            CREATE TABLE platforms (seq INTEGER NOT NULL, id TEXT PRIMARY KEY, body BLOB NOT NULL);
            CREATE TABLE jurisdictions (seq INTEGER NOT NULL, id TEXT PRIMARY KEY, code TEXT NOT NULL, body BLOB NOT NULL);
            CREATE TABLE documents (name TEXT PRIMARY KEY, body BLOB NOT NULL);
            CREATE VIRTUAL TABLE site_search USING fts5 (id UNINDEXED, name, domain, kind, about, tokenize = 'unicode61 remove_diacritics 2', detail = column);
            """)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try exec("BEGIN")
        func insert(_ sql: String, _ values: [Any]) throws {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw CatalogError.sqlite(String(cString: sqlite3_errmsg(db))) }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, v) in values.enumerated() {
                let at = Int32(i + 1)
                switch v {
                case let n as Int: sqlite3_bind_int64(stmt, at, Int64(n))
                case let t as String: sqlite3_bind_text(stmt, at, t, -1, transient)
                case let d as Data: _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, at, $0.baseAddress, Int32(d.count), transient) }
                default: throw CatalogError.sqlite("cannot store \(type(of: v))")
                }
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw CatalogError.sqlite(String(cString: sqlite3_errmsg(db))) }
        }
        for (i, e) in c.sites.enumerated() {
            try insert("INSERT INTO sites VALUES (?, ?, ?, ?, ?, ?)", [i, e.id, e.domain, e.name, e.excluded == nil ? 0 : 1, try encoder.encode(e)])
        }
        for e in c.sites where e.excluded == nil {
            let words = searchWords(e)
            try insert("INSERT INTO site_search VALUES (?, ?, ?, ?, ?)", [e.id, e.name, words.domain, words.kind, words.about])
        }
        for (i, b) in c.brokers.enumerated() { try insert("INSERT INTO brokers VALUES (?, ?, ?)", [i, b.id, try encoder.encode(b)]) }
        for (i, p) in c.platforms.enumerated() { try insert("INSERT INTO platforms VALUES (?, ?, ?)", [i, p.id, try encoder.encode(p)]) }
        for (i, j) in c.jurisdictions.enumerated() { try insert("INSERT INTO jurisdictions VALUES (?, ?, ?, ?)", [i, j.id, j.code, try encoder.encode(j)]) }
        if let s = c.registrySummary { try insert("INSERT INTO documents VALUES (?, ?)", ["registry_summary", try encoder.encode(s)]) }
        if let t = c.termsLibrary { try insert("INSERT INTO documents VALUES (?, ?)", ["terms_library", try encoder.encode(t)]) }
        try exec("COMMIT")
    }

    /// What a site is found by in the search (`search`): its web address split into words (spokeo.com as "spokeo com spokeo.com"), what kind of company it
    /// is and what it holds and sells (in every language the app speaks, so "téléphone" finds the same sites as "phone"), and its description.
    static func searchWords(_ e: DirectoryEntry) -> (domain: String, kind: String, about: String) {
        let domain = e.domain.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "-", with: " ") + " " + e.domain
        var kinds: [String] = []
        let was = L10n.language
        defer { L10n.language = was }
        for lang in ["en", "fr", "es", "de"] {
            L10n.language = lang
            if let c = e.about.flatMap({ BrokerCategory(rawValue: $0.category) }) { kinds.append(c.title) }
            kinds += (e.about?.tracks ?? []).compactMap { DataKind(rawValue: $0)?.title }
            kinds += (e.about?.sellsTo ?? []).compactMap { BuyerKind(rawValue: $0)?.title }
        }
        return (domain, Array(NSOrderedSet(array: kinds)).compactMap { $0 as? String }.joined(separator: " "), e.about?.summary ?? "")
    }

    /// The full-text query for what a person typed: every word must match, each as the start of a word ("spok" finds Spokeo), in any order.
    /// Nil when nothing searchable was typed.
    public static func searchQuery(_ text: String) -> String? {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // MARK: Reading (in the app)

    /// Opens the catalog read-only and immutable: SQLite then creates no journal or lock file beside it, which it could not do inside the app's
    /// signed, read-only bundle.
    static func withDatabase<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        var parts = URLComponents(); parts.scheme = "file"; parts.path = url.path; parts.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        let uri = parts.string ?? "file:\(url.path)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw CatalogError.sqlite("could not open \(url.lastPathComponent)")
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        var version: Int32 = 0
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW { version = sqlite3_column_int(stmt, 0) }
        sqlite3_finalize(stmt)
        guard version == schemaVersion else { throw CatalogError.wrongVersion(found: version) }
        return try body(db)
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
