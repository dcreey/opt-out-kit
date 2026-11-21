import XCTest
import OptOutKitCore
@testable import OptOutKit

/// What the built app contains: its bundle holds the compiled catalog and no data files. The catalog's contents are tested on the Mac (`Model/CatalogAppTests`).
final class CatalogBundleTests: XCTestCase {
    func testTheAppShipsTheCompiledCatalogAndNoDataFiles() throws {
        let bundle = try XCTUnwrap(Bundle.main.resourceURL)
        XCTAssertNotNil(Bundle.main.url(forResource: "Catalog", withExtension: "sqlite"), "the build step put the catalog in the app")
        for folder in ["directory", "brokers", "platforms", "jurisdictions", "terms", "PageScripts", "data"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.appendingPathComponent(folder).path), "\(folder)/ is compiled into the catalog, not shipped")
        }
        let files = (FileManager.default.enumerator(atPath: bundle.path)?.allObjects as? [String] ?? []).filter { ["yml", "yaml", "js", "tsv"].contains(($0 as NSString).pathExtension) }
        XCTAssertEqual(files, [], "no YAML, script or table file anywhere in the app")
    }
}
