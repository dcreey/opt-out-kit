import Foundation
import OptOutKitCore

#if DEBUG
/// The integration tests run the app against a catalog whose sites are fixture brokers served by a local web server (fixtures/server.py, built by
/// fixtures/build_catalog.sh): `-uitest-catalog /path/Catalog.sqlite` opens that catalog in place of the bundled one, and nothing else changes: the same loading,
/// the same engine, the same web view and page scripts as for a real broker. Debug builds only; the shipped app opens only its bundled catalog.
/// docs/TESTING.md, "End-to-end tests against fixture pages".
enum Fixtures {
    /// The catalog the test asked for, if any.
    static var catalog: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-uitest-catalog"), args.indices.contains(i + 1) else { return nil }
        return URL(string: "file://" + args[i + 1])
    }

    /// Lets the core fetchers read the fixture brokers' pages too (the exposure scan).
    static func allowFetching() { URLSessionFetcher.allowLoopback = active }

    /// True when the app was launched against the fixture brokers.
    static var active: Bool { catalog != nil }

    /// True for the fixture server's address (a loopback IP address, which App Transport Security does not apply to).
    static func serves(_ url: URL) -> Bool { active && url.scheme == "http" && url.host == "127.0.0.1" }
}
#endif

extension URL {
    /// A page the app may load for a site: an https address (and, in a UI test of the debug build, the local fixture server).
    var isSecureWebPage: Bool {
        if scheme == "https" { return true }
        #if DEBUG
        return Fixtures.serves(self)
        #else
        return false
        #endif
    }
}
