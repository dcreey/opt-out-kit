import Foundation
import OptOutKitCore

/// The app's compiled catalog (Catalog.sqlite, built into the bundle by the CatalogPlugin build step): the one place that knows where it is. Everything the
/// app ships (sites, flows, laws, page scripts, ZIP codes) is read from it, through SQLite; the app opens no other bundled file.
enum AppCatalog {
    static let url: URL? = {
        #if DEBUG
        Fixtures.allowFetching()
        if let fixtures = Fixtures.catalog { return fixtures }          // an integration test's catalog of fixture brokers (docs/TESTING.md)
        #endif
        return Bundle.main.url(forResource: "Catalog", withExtension: "sqlite")
    }()

    private static let opened: Void = { if let url { try? Catalog.use(url) } }()

    /// Opens the bundled catalog as the process-wide one (page scripts and the ZIP lookup read through it), once. `AppModel` opens the catalog it was
    /// given instead, which is how a test uses another one.
    static func ensureOpen() { _ = opened }
}
