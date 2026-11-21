import Foundation
import OptOutKitCore
import SQLite3

/// Compiling the app's data into Catalog.sqlite (docs/DIRECTORY.md, "The compiled catalog"). Build time and tests only: the app reads the result (`Catalog`).
public extension Catalog {
    /// Everything that goes into the file: the data the app loads at launch, the page scripts, and the ZIP table (looked up by key, never loaded whole).
    struct Source: Equatable {
        public var contents: Contents
        public var scripts: [String: String]
        public var zips: [String: ZipLookup.Place]
        public init(contents: Contents, scripts: [String: String] = [:], zips: [String: ZipLookup.Place] = [:]) {
            self.contents = contents; self.scripts = scripts; self.zips = zips
        }
    }

    /// Loads the repository's data with the app's own loaders: `directory/`, `brokers/`, `platforms/`, `jurisdictions/`, `registries/summary.json`,
    /// `terms/library.yml`, the page scripts in `App/PageScripts/*.js` and the ZIP table `data/zips-us.tsv`. A file that does not decode, or a repeated id,
    /// is an error.
    static func load(repository root: URL) throws -> Source {
        let summaryURL = root.appendingPathComponent("registries/summary.json")
        let termsURL = root.appendingPathComponent("terms/library.yml")
        let fm = FileManager.default
        let contents = Contents(sites: try Registry.loadDirectory(root.appendingPathComponent("directory")),
                                brokers: try Registry.load(directory: root.appendingPathComponent("brokers")),
                                platforms: try PlatformLoader.load(directory: root.appendingPathComponent("platforms")),
                                jurisdictions: try JurisdictionLoader.load(directory: root.appendingPathComponent("jurisdictions")),
                                registrySummary: fm.fileExists(atPath: summaryURL.path) ? JurisdictionLoader.loadSummary(summaryURL) : nil,
                                termsLibrary: fm.fileExists(atPath: termsURL.path) ? try TermsLibrary.load(termsURL) : nil)
        var scripts: [String: String] = [:]
        let scriptDir = root.appendingPathComponent("App/PageScripts")
        for file in (try? fm.contentsOfDirectory(at: scriptDir, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "js" {
            scripts[file.deletingPathExtension().lastPathComponent] = try String(contentsOf: file, encoding: .utf8)
        }
        var zips: [String: ZipLookup.Place] = [:]
        if let tsv = try? String(contentsOf: root.appendingPathComponent("data/zips-us.tsv"), encoding: .utf8) {
            for line in tsv.split(separator: "\n") {
                let c = line.split(separator: "\t", omittingEmptySubsequences: false)
                if c.count == 3 { zips[String(c[0])] = ZipLookup.Place(city: String(c[1]), state: String(c[2])) }
            }
        }
        return Source(contents: contents, scripts: scripts, zips: zips)
    }

    /// Writes the source to a new catalog file at `url` (replacing one that is there). Each row keeps the entry as JSON with the columns the app looks up
    /// by beside it, and its position, so the app gets the entries back in the order the loaders gave them.
    static func write(_ source: Source, to url: URL) throws {
        let c = source.contents
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
            CREATE TABLE scripts (name TEXT PRIMARY KEY, body TEXT NOT NULL);
            CREATE TABLE zips (zip TEXT PRIMARY KEY, city TEXT NOT NULL, state TEXT NOT NULL) WITHOUT ROWID;
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
        for (name, body) in source.scripts.sorted(by: { $0.key < $1.key }) { try insert("INSERT INTO scripts VALUES (?, ?)", [name, body]) }
        for (zip, place) in source.zips { try insert("INSERT INTO zips VALUES (?, ?, ?)", [zip, place.city, place.state]) }
        try exec("COMMIT")
    }

    /// Reads the catalog at `url` back and checks it holds exactly `source`: the data the app loads at launch (every row), every page script, and the
    /// ZIP table (its size, and every 97th code). Throws what differs, so the build fails instead of shipping a catalog that reads differently.
    static func verify(_ source: Source, at url: URL) throws {
        guard try contents(of: url, includeExcluded: true) == source.contents else { throw CatalogError.sqlite("the catalog read back differs from the data it was built from") }
        try use(url)
        let counts = try counts(in: url)
        guard counts.scripts == source.scripts.count, counts.zips == source.zips.count else {
            throw CatalogError.sqlite("the catalog holds \(counts.scripts) scripts and \(counts.zips) ZIP codes, expected \(source.scripts.count) and \(source.zips.count)")
        }
        guard scriptNames() == source.scripts.keys.sorted() else { throw CatalogError.sqlite("the catalog's page script names differ") }
        for (name, body) in source.scripts where script(named: name) != body { throw CatalogError.sqlite("page script \(name) reads back differently") }
        for (i, zip) in source.zips.keys.sorted().enumerated() where i % 97 == 0 {
            guard let found = Catalog.zip(zip), found.city == source.zips[zip]?.city, found.state == source.zips[zip]?.state else { throw CatalogError.sqlite("ZIP \(zip) reads back differently") }
        }
    }

    /// What a site is found by in the search (`search`): its web address split into words (spokeo.com as "spokeo com spokeo.com"), what kind of company it
    /// is and what it holds and sells (in every language the app speaks, so "téléphone" finds the same sites as "phone"), and its description.
    private static func searchWords(_ e: DirectoryEntry) -> (domain: String, kind: String, about: String) {
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
}
