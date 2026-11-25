import XCTest
import OptOutKitCore
@testable import AssistedRunLogic

/// The app ships its data compiled into Catalog.sqlite (built by the CatalogPlugin build step) and reads only that: no YAML, no script file, no table file in
/// the bundle, and the model, the page scripts and the ZIP lookup get their data from it. (That the catalog holds exactly what the repository's YAML holds is
/// `CatalogTests` in the core package, on every real file.) docs/DIRECTORY.md, "The compiled catalog".
@MainActor
final class CatalogAppTests: XCTestCase {
    private func model() -> AppModel {
        AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sqlite"), keys: FixedKey()),
                 defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
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

    /// The directory corrections from the 2026-11-24 export reach the catalog the app ships: apollo.io's form needs a work email and a code, so it is never
    /// sent automatically; videoamp.com, socialgist.ai and visitiq.io have no form to fill; rrd.com points at its real request form, behind a reCAPTCHA box.
    func testTheNovember24thDirectoryCorrectionsAreInTheCatalog() throws {
        let m = model()
        func site(_ d: String) throws -> DirectoryEntry { try XCTUnwrap(m.directory.first { $0.domain == d }, d) }
        let apollo = try site("apollo.io")
        XCTAssertEqual(apollo.contactEmail, "privacy@apollo.io")
        XCTAssertEqual(apollo.liveForm?.blockers.sorted(), ["business", "code"])
        for d in ["videoamp.com", "socialgist.ai", "visitiq.io"] { XCTAssertEqual(try site(d).liveForm?.found, false, "\(d) has no form") }
        let rrd = try site("rrd.com")
        XCTAssertTrue(rrd.liveForm?.page?.hasPrefix("https://privacyportal.onetrust.com/webform/") ?? false)
        XCTAssertEqual(rrd.liveForm?.blockers, ["check: a reCAPTCHA checkbox"])
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
