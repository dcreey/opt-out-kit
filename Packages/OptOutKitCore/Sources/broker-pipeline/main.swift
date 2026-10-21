import Foundation
import OptOutKitCore

// Usage: broker-pipeline [--brokers DIR] [--directory DIR] [--report FILE] [--census FILE] [--spacing SECONDS]
//                        [--methods-report FILE (needs --directory)] [--person "First Last|City|ST"]
// Exits 1 when any broker FAILs (a definition is wrong or a page changed). BLOCKED and NEEDS RESEARCH do not fail the run.
var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let brokersDir = URL(fileURLWithPath: option("--brokers") ?? "brokers")
let spacing = Double(option("--spacing") ?? "") ?? 2
let fetcher = URLSessionFetcher()

var person: Person?
if let spec = option("--person") {
    let p = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    if p.count == 3 {
        person = Person(displayName: "You", names: [NameEntry(kind: .legal, name: p[0])], addresses: [Address(city: p[1], state: p[2])])
    }
}

var report = ""
var failed = false
do {
    let brokers = try Registry.load(directory: brokersDir)
    var all = brokers
    // Directory sites whose search check was learned automatically get the same calibration as hand-written brokers.
    if let dir = option("--directory") {
        let entries = try Registry.loadDirectory(URL(fileURLWithPath: dir))
        all += entries.compactMap { e in
            e.searchCheck?.recheck.map {
                Broker(id: e.id, name: e.domain, tier: e.tier ?? .B, covers: nil, signals: nil, fields: nil,
                       steps: [Step(say: "directory entry")], recheckDays: 120, verified: nil, recheck: $0)
            }
        }
    }
    let rows = await BrokerPipeline(fetcher: fetcher, spacing: spacing).run(all, person: person)
    report += BrokerPipeline.markdown(rows)
    failed = rows.contains { if case .fail = $0.status { return true } else { return false } }
} catch {
    report += "Could not load brokers: \(error)\n"
    failed = true
}

if let censusFile = option("--census"), let list = try? String(contentsOfFile: censusFile, encoding: .utf8) {
    let domains = list.split(separator: "\n").map { String($0.split(whereSeparator: { $0 == "\t" || $0 == " " }).first ?? "").trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    let result = await Census.run(domains: domains, fetcher: fetcher)
    report += "\n## Reachability census (\(domains.count) sites, plain request)\n\n| Result | Sites |\n|---|---|\n"
    for c in Census.Class.allCases {
        report += "| \(c.rawValue) | \(result.values.filter { $0 == c }.count) |\n"
    }
}

if let path = option("--methods-report"), let dir = option("--directory") {
    let brokers = (try? Registry.load(directory: brokersDir)) ?? []
    let entries = (try? Registry.loadDirectory(URL(fileURLWithPath: dir))) ?? []
    try? OptOutMethods.markdown(brokers: brokers, entries: entries).write(toFile: path, atomically: true, encoding: .utf8)
}

print(report)
if let path = option("--report") { try? report.write(toFile: path, atomically: true, encoding: .utf8) }
exit(failed ? 1 : 0)
