import XCTest
import OptOutKitCore
@testable import OptOutKit

/// Looks, never sends. Opens real opt-out pages with the live form path, fills them with a MADE-UP profile, takes a screenshot of the
/// filled form and reports what it found. Runs only when asked: TEST_RUNNER_OPTOUT_LIVE=1 TEST_RUNNER_OPTOUT_URLS=url1,url2
@MainActor
final class LiveFormPreviewTests: XCTestCase {
    func testFillRealPagesWithTheLivePathAndSendNothing() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["OPTOUT_LIVE"] == "1", "set TEST_RUNNER_OPTOUT_LIVE=1 to run")
        let urls = (env["OPTOUT_URLS"] ?? "").split(separator: ",").compactMap { URL(string: String($0)) }
        let pat = Person(displayName: "Pat", relationship: .me, names: [NameEntry(kind: .legal, name: "Pat Example")],
                         addresses: [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")], emails: ["pat@example.com"], phones: ["555-010-0199"])
        let dir = URL(fileURLWithPath: "/private/tmp/ook-live-shots"); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for url in urls {
            let report = await FormRun.runLive(url: url, html: nil, person: pat, dryRun: true, maxWait: 12, capture: true)
            print("LIVEFORM \(url.host ?? "") \(url.path): \(report.outcome)")
            if let shot = report.screenshot { try? shot.write(to: dir.appendingPathComponent((url.host ?? "site") + ".jpg")) }
        }
    }
}
