import XCTest
import SQLite3
@testable import OptOutKitCore

/// The compiled catalog the app ships (`Catalog`, Catalog.sqlite): built from the repository's YAML at build time, read by the app instead of the YAML.
final class CatalogTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func temporaryFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ook-catalog-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path); try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// What the app reads from the catalog is exactly what the YAML loaders return for the repository's real data, every site, flow, platform,
    /// place, the registry counts and the terms library; and the excluded sites are left out by the query, as the app used to filter them.
    func testTheCatalogHoldsExactlyWhatTheYAMLLoadersReturnForTheRealData() throws {
        let loaded = try Catalog.load(repository: Self.repository)
        XCTAssertGreaterThan(loaded.sites.count, 800); XCTAssertFalse(loaded.brokers.isEmpty); XCTAssertFalse(loaded.platforms.isEmpty)
        XCTAssertGreaterThan(loaded.jurisdictions.count, 100); XCTAssertNotNil(loaded.registrySummary); XCTAssertNotNil(loaded.termsLibrary)
        let file = try temporaryFolder().appendingPathComponent(Catalog.fileName)
        try Catalog.write(loaded, to: file)
        XCTAssertEqual(try Catalog.contents(of: file, includeExcluded: true), loaded, "every value survives the catalog unchanged, in the same order")
        let shown = try Catalog.contents(of: file)
        XCTAssertEqual(shown.sites, loaded.sites.filter { $0.excluded == nil })
        XCTAssertLessThan(shown.sites.count, loaded.sites.count, "some sites are excluded, and the app never gets them")
    }

    func testASiteIsFoundByItsDomainThroughTheIndexAndAnExcludedOneIsNot() throws {
        let loaded = try Catalog.load(repository: Self.repository)
        let file = try temporaryFolder().appendingPathComponent(Catalog.fileName)
        try Catalog.write(loaded, to: file)
        let some = try XCTUnwrap(loaded.sites.first { $0.excluded == nil })
        XCTAssertEqual(try Catalog.site(domain: some.domain.uppercased(), in: file), some)
        if let gone = loaded.sites.first(where: { $0.excluded != nil }) { XCTAssertNil(try Catalog.site(domain: gone.domain, in: file)) }
        XCTAssertNil(try Catalog.site(domain: "no-such-site.example", in: file))
    }

    /// The app's bundle is read-only and signed: the catalog is one self-contained file, and reading it writes nothing beside it (no journal, WAL or
    /// lock file), so it opens in a folder nobody may write to.
    func testTheCatalogIsOneFileAndReadsInAFolderNobodyMayWriteTo() throws {
        let dir = try temporaryFolder()
        let file = dir.appendingPathComponent(Catalog.fileName)
        try Catalog.write(Catalog.Contents(sites: [], brokers: [], platforms: [], jurisdictions: [], registrySummary: nil, termsLibrary: nil), to: file)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [Catalog.fileName], "no journal or WAL file left behind")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        XCTAssertNoThrow(try Catalog.contents(of: file))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [Catalog.fileName], "reading created nothing")
    }

    /// A catalog of another layout is refused (the app and its catalog are built together, so this only guards against a stale file).
    func testACatalogOfAnotherVersionIsRefused() throws {
        let file = try temporaryFolder().appendingPathComponent(Catalog.fileName)
        try Catalog.write(Catalog.Contents(sites: [], brokers: [], platforms: [], jurisdictions: [], registrySummary: nil, termsLibrary: nil), to: file)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA user_version = 999", nil, nil, nil); sqlite3_close(db)
        XCTAssertThrowsError(try Catalog.contents(of: file)) { error in
            guard case Catalog.CatalogError.wrongVersion(999) = error else { return XCTFail("refused for its version, not \(error)") }
        }
    }

    /// The Sites search reads the catalog's full-text index: the start of a word finds a name ("spok"), every word must match in any order, what a
    /// company holds is found in any of the app's languages, the best match comes first, and an excluded site is never found.
    func testTheSearchFindsSitesByNameStartWhatTheyHoldInAnyLanguageBestFirst() throws {
        let loaded = try Catalog.load(repository: Self.repository)
        let file = try temporaryFolder().appendingPathComponent(Catalog.fileName)
        try Catalog.write(loaded, to: file)
        XCTAssertEqual(try Catalog.search("spok", in: file).first, "spokeo_com", "the start of a name")
        XCTAssertEqual(try Catalog.search("Spokeo.com", in: file).first, "spokeo_com", "a web address as typed")
        let phone = Set(try Catalog.search("phone numbers", in: file))
        XCTAssertGreaterThan(phone.count, 100)
        XCTAssertEqual(Set(try Catalog.search("numéros de téléphone", in: file)), phone, "the same sites, searched in French")
        XCTAssertEqual(Set(try Catalog.search("telephone", in: file)), Set(try Catalog.search("téléphone", in: file)), "accents do not matter")
        let both = Set(try Catalog.search("court records", in: file))
        XCTAssertTrue(both.isSubset(of: Set(try Catalog.search("court", in: file))), "every word must match")
        XCTAssertEqual(try Catalog.search("   ", in: file), [])
        for gone in loaded.sites where gone.excluded != nil { XCTAssertFalse(try Catalog.search(gone.domain, in: file).contains(gone.id), gone.domain) }
        XCTAssertEqual(Catalog.searchQuery("Spokeo's \"site\""), "\"spokeo\"* \"s\"* \"site\"*", "typed quotes and punctuation cannot break the query")
    }

    /// Reading the whole catalog is quick: the app does it on the main thread at launch. (Parsing the same sites from YAML took 0.14 to 0.23 s in a
    /// release build on a Mac; this test builds in debug, so the bound is loose.)
    func testReadingTheWholeCatalogIsQuick() throws {
        let file = try temporaryFolder().appendingPathComponent(Catalog.fileName)
        try Catalog.write(try Catalog.load(repository: Self.repository), to: file)
        let start = Date()
        let c = try Catalog.contents(of: file)
        let seconds = Date().timeIntervalSince(start)
        print("catalog read: \(c.sites.count) sites in \(String(format: "%.3f", seconds)) s")
        XCTAssertLessThan(seconds, 1.0)
    }
}
