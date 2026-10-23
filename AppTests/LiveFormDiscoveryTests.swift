import XCTest
import OptOutKitCore
@testable import OptOutKit

/// Looks, never sends. For every directory site whose crawl found no readable form, opens its page in the real web view (scripts run),
/// follows opt-out links when needed, and reports whether an opt-out form is really there and what blocks it. Sharded so several
/// simulators can split the work: TEST_RUNNER_OPTOUT_LIVE=1 TEST_RUNNER_OPTOUT_SHARD=0/4
@MainActor
final class LiveFormDiscoveryTests: XCTestCase {
    func testFindFormsOnPagesTheCrawlerCouldNotRead() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["OPTOUT_LIVE"] == "1", "set TEST_RUNNER_OPTOUT_LIVE=1 to run")
        let shard = (env["OPTOUT_SHARD"] ?? "0/1").split(separator: "/").compactMap { Int($0) }
        let (index, count) = (shard.first ?? 0, shard.count > 1 ? shard[1] : 1)
        let model = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                             defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        let pat = Person(displayName: "Pat", relationship: .me, names: [NameEntry(kind: .legal, name: "Pat Example")],
                         addresses: [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")], emails: ["pat@example.com"], phones: ["555-010-0199"])
        let targets = model.directory.filter { $0.optOutForm == nil }.sorted { $0.domain < $1.domain }
        let dir = URL(fileURLWithPath: "/private/tmp/ook-live-forms"); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("shard-\(index).tsv"); try? "".write(to: out, atomically: true, encoding: .utf8)
        for (i, e) in targets.enumerated() where i % count == index {
            var line = ""
            // 1. the page we already have, 2. whatever the link finder reaches from the home page
            var starts: [URL] = []
            if let u = e.optOutURL { starts.append(u) }
            var result = "none", page = "", blockers: [String] = []
            for u in starts {
                let r = await FormRun.runLive(url: u, html: nil, person: pat, dryRun: true, maxWait: 8, capture: false)
                if case .filledNotSubmitted = r.outcome { result = "form"; page = u.absoluteString; blockers = FormRun.debugLastBlockers; break }
                result = "page:" + "\(r.outcome)".prefix(70)
            }
            if result != "form", let home = URL(string: "https://\(e.domain)/") {
                let found = await OptOutLinkFinder(inspector: model.makeInspector()).find(from: home)
                if let f = found.form {
                    let r = await FormRun.runLive(url: f.page, html: nil, person: pat, dryRun: true, maxWait: 8, capture: false)
                    if case .filledNotSubmitted = r.outcome { result = "form"; page = f.page.absoluteString; blockers = FormRun.debugLastBlockers }
                    else { result = "found-link:" + "\(r.outcome)".prefix(70); page = f.page.absoluteString }
                }
            }
            line = "\(e.domain)\t\(result)\t\(page)\t\(blockers.joined(separator: ";"))\n"
            if let h = try? FileHandle(forWritingTo: out) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        }
    }
}
