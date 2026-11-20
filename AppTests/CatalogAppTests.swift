import XCTest
import OptOutKitCore
@testable import OptOutKit

/// The app ships its data compiled into Catalog.sqlite (built by the CatalogPlugin build step) and reads only that: no YAML in the bundle, and the model
/// gets the same data the repository's YAML holds. docs/DIRECTORY.md, "The compiled catalog".
@MainActor
final class CatalogAppTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func testTheAppShipsTheCompiledCatalogAndNoDataYAML() throws {
        let bundle = try XCTUnwrap(Bundle.main.resourceURL)
        XCTAssertNotNil(Bundle.main.url(forResource: "Catalog", withExtension: "sqlite"), "the build step put the catalog in the app")
        for folder in ["directory", "brokers", "platforms", "jurisdictions", "terms"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.appendingPathComponent(folder).path), "\(folder)/ is compiled into the catalog, not shipped")
        }
        let yaml = (FileManager.default.enumerator(atPath: bundle.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
        XCTAssertEqual(yaml, [], "no YAML anywhere in the app")
    }

    func testTheModelLoadsFromTheCatalogWhatTheRepositorysYAMLHolds() throws {
        let model = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                             defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        XCTAssertNil(model.loadError)
        let source = try Catalog.load(repository: Self.repository)
        XCTAssertEqual(model.directory, source.sites.filter { $0.excluded == nil })
        XCTAssertEqual(model.brokers, source.brokers)
        XCTAssertEqual(model.platforms, source.platforms)
        XCTAssertEqual(model.jurisdictions, source.jurisdictions)
        XCTAssertEqual(model.registrySummary, source.registrySummary)
        XCTAssertEqual(model.termsLibrary, source.termsLibrary)
    }

    /// The Sites search uses the bundled catalog's full-text index (SQLite's FTS5, part of iOS): by the start of a name, and by what a company holds.
    func testTheSitesSearchFindsSitesInTheBundledCatalog() throws {
        let model = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                             defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        XCTAssertEqual(model.siteSearch("spok").first, "spokeo_com")
        let phone = model.siteSearch("phone numbers")
        XCTAssertGreaterThan(phone.count, 100)
        XCTAssertTrue(phone.allSatisfy { model.sites[id: $0] != nil }, "every hit is a site the app shows")
        XCTAssertEqual(model.siteSearch("phone numbers"), phone, "asked again (every redraw), the same answer")
    }
}
