import XCTest
import OptOutKitCore
@testable import OptOutKit

/// Experiment, not a regression test. It asks: for directory sites a plain request could not read, does the same
/// search made through a real browser engine tell a made-up name from a known one?
/// Runs only when asked, and uses no personal data (two fixed example names):
///   TEST_RUNNER_OPTOUT_LIVE=1 [TEST_RUNNER_OPTOUT_LIMIT=24] xcodebuild test -only-testing:OptOutKitTests/LiveWebViewTests ...
@MainActor
final class LiveWebViewTests: XCTestCase {
    func testWebViewReadsSitesAPlainRequestCould_not() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["OPTOUT_LIVE"] == "1", "set TEST_RUNNER_OPTOUT_LIVE=1 to run")
        let limit = Int(env["OPTOUT_LIMIT"] ?? "") ?? 24
        let dir = try XCTUnwrap(Bundle.main.url(forResource: "directory", withExtension: nil))
        let only = (env["OPTOUT_ONLY"] ?? "").split(separator: ",").map(String.init)
        let entries = try Registry.loadDirectory(dir).filter { $0.searchCheck?.candidate != nil && (only.isEmpty || only.contains($0.domain)) }
        // Spread the sample across the list instead of taking the first few, which share one template.
        let stride = max(entries.count / max(limit, 1), 1)
        let sample = Array(entries.enumerated().filter { $0.offset % stride == 0 }.map(\.element).prefix(limit))
        let fetcher = WebViewFetcher(maxWait: TimeInterval(env["OPTOUT_WAIT"] ?? "") ?? 14)

        struct Row { var domain: String; var made: FetchedPage?; var known: FetchedPage?; var method: String }
        func search(_ c: SearchCheck.Candidate, _ name: String) async -> FetchedPage? {
            guard let url = Rechecker.fill(c.url, name: name, city: "Springfield", state: "IL", encoding: .path).flatMap(URL.init(string:)) else { return nil }
            if c.method.uppercased() == "POST" {
                guard let body = c.body.flatMap({ Rechecker.fill($0, name: name, city: "Springfield", state: "IL", encoding: .form) }) else { return nil }
                return try? await fetcher.post(url, body: body)
            }
            return try? await fetcher.fetch(url)
        }

        var rows: [Row] = []
        var index = 0
        await withTaskGroup(of: Row.self) { group in
            func next() {
                guard index < sample.count, let c = sample[index].searchCheck?.candidate else { return }
                let e = sample[index]; index += 1
                group.addTask { @MainActor in
                    Row(domain: e.domain, made: await search(c, "Zzyzx Qwertyuiop"), known: await search(c, "John Smith"), method: c.method)
                }
            }
            for _ in 0..<min(3, sample.count) { next() }
            for await r in group { rows.append(r); next() }
        }

        var readable = 0, distinguishable = 0
        for r in rows.sorted(by: { $0.domain < $1.domain }) {
            guard let m = r.made, let k = r.known else { print("WVLIVE \(r.domain) \(r.method) FAILED to load"); continue }
            readable += 1
            let knownHasName = k.text.lowercased().contains("john") && k.text.lowercased().contains("smith")
            let differ = m.text != k.text
            let blocked = ["just a moment", "attention required", "verify you are human", "security challenge"].contains { m.text.lowercased().contains($0) }
            if knownHasName && differ && !blocked { distinguishable += 1 }
            print("WVLIVE \(r.domain) \(r.method) made=\(m.status)/\(m.text.count) known=\(k.status)/\(k.text.count) differ=\(differ) knownHasName=\(knownHasName) blocked=\(blocked) madeStart=\(m.text.prefix(70).replacingOccurrences(of: "\n", with: " ")) knownEnd=\(k.text.suffix(500).replacingOccurrences(of: "\n", with: " "))")
        }
        print("WVLIVE SUMMARY sample=\(sample.count) loaded=\(readable) distinguishable=\(distinguishable)")
    }
}
