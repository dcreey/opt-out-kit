import XCTest
import OptOutKitCore
@testable import OptOutKit

/// The app ships its data compiled into Catalog.sqlite (built by the CatalogPlugin build step) and reads only that: no YAML, no script file, no table file in
/// the bundle, and the model, the page scripts and the ZIP lookup get their data from it. (That the catalog holds exactly what the repository's YAML holds is
/// `CatalogTests` in the core package, on every real file.) docs/DIRECTORY.md, "The compiled catalog".
@MainActor
final class CatalogAppTests: XCTestCase {
    private func model() -> AppModel {
        AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sqlite"), keys: FixedKey()),
                 defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
    }

    func testTheAppShipsTheCompiledCatalogAndNoDataFiles() throws {
        let bundle = try XCTUnwrap(Bundle.main.resourceURL)
        XCTAssertNotNil(Bundle.main.url(forResource: "Catalog", withExtension: "sqlite"), "the build step put the catalog in the app")
        for folder in ["directory", "brokers", "platforms", "jurisdictions", "terms", "PageScripts", "data"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.appendingPathComponent(folder).path), "\(folder)/ is compiled into the catalog, not shipped")
        }
        let files = (FileManager.default.enumerator(atPath: bundle.path)?.allObjects as? [String] ?? []).filter { ["yml", "yaml", "js", "tsv"].contains(($0 as NSString).pathExtension) }
        XCTAssertEqual(files, [], "no YAML, script or table file anywhere in the app")
    }

    func testTheModelLoadsItsDataFromTheCatalog() throws {
        let m = model()
        XCTAssertNil(m.loadError)
        let c = try Catalog.contents(of: try XCTUnwrap(AppCatalog.url))
        XCTAssertGreaterThan(c.sites.count, 800)
        XCTAssertEqual(m.directory, c.sites)
        XCTAssertEqual(m.brokers, c.brokers)
        XCTAssertEqual(m.platforms, c.platforms)
        XCTAssertEqual(m.jurisdictions, c.jurisdictions)
        XCTAssertEqual(m.registrySummary, c.registrySummary)
        XCTAssertEqual(m.termsLibrary, c.termsLibrary)
        XCTAssertTrue(m.directory.allSatisfy { $0.excluded == nil }, "excluded sites are left out by the catalog's own query")
    }

    /// Every page script comes from the catalog (the same ones the repository holds), includes resolve, and a ZIP code is found by key.
    func testThePageScriptsAndTheZIPTableComeFromTheCatalog() {
        _ = model()
        let names = PageScript.names
        XCTAssertGreaterThan(names.count, 50)
        for name in names { XCTAssertFalse(PageScript.source(name).contains("//#include"), "\(name): includes are resolved") }
        XCTAssertEqual(ZipLookup.place(for: "62701"), ZipLookup.Place(city: "Springfield", state: "IL"))
    }

    /// The Sites search uses the bundled catalog's full-text index (SQLite's FTS5, part of iOS): by the start of a name, and by what a company holds.
    func testTheSitesSearchFindsSitesInTheBundledCatalog() throws {
        let m = model()
        XCTAssertEqual(m.siteSearch("spok").first, "spokeo_com")
        let phone = m.siteSearch("phone numbers")
        XCTAssertGreaterThan(phone.count, 100)
        XCTAssertTrue(phone.allSatisfy { m.sites[id: $0] != nil }, "every hit is a site the app shows")
        XCTAssertEqual(m.siteSearch("phone numbers"), phone, "asked again (every redraw), the same answer")
    }
}
