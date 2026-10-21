import XCTest
import WebKit
import OptOutKitCore
@testable import OptOutKit

/// Looks, never sends. Loads real opt-out pages with a MADE-UP profile, fills them, takes a screenshot, reports what is blocking,
/// and closes. Runs only when asked: TEST_RUNNER_OPTOUT_LIVE=1 TEST_RUNNER_OPTOUT_ONLY=dobsearch.com,peoplesmart.com (or "all")
@MainActor
final class LiveAssistedPreviewTests: XCTestCase {
    func testFillRealFormsWithAMadeUpProfileAndShowWhatIsBlocking() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["OPTOUT_LIVE"] == "1", "set TEST_RUNNER_OPTOUT_LIVE=1 to run")
        let only = (env["OPTOUT_ONLY"] ?? "").split(separator: ",").map(String.init)
        let pat = Person(displayName: "Pat", names: [NameEntry(kind: .legal, name: "Pat Example")],
                         addresses: [Address(city: "Springfield", state: "IL")], emails: ["pat@example.com"])
        let model = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                             defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        let items = model.assistedItems(for: pat).filter { only == ["all"] || only.contains($0.entry.domain) }
        XCTAssertFalse(items.isEmpty, "none of \(only) are in the ready queue")
        for item in items {
            guard let page = await WebAssistedDriver().prepare(item.form, plan: item.plan) else { print("LIVEPREVIEW \(item.entry.domain): page would not load"); continue }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            let blockers = await page.blockers()
            print("LIVEPREVIEW \(item.entry.domain): blockers=\(blockers) fieldsToFill=\(item.plan.values.map(\.name))")
            if let web = page.webView {
                web.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
                let image = try? await web.takeSnapshot(configuration: nil)
                if let image { let a = XCTAttachment(image: image); a.name = "live-\(item.entry.domain)"; a.lifetime = .keepAlways; add(a) }
            }
            page.close()        // closed without sending anything
        }
    }
}
