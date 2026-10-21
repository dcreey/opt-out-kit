import Foundation

/// Read-only dry run of every broker definition against the live web. Never submits or enters anything:
/// it loads each step's page, and for brokers with a `recheck:` block runs two calibration searches.
public enum PipelineStatus: Equatable, Sendable {
    case pass                  // pages load and the check tells a made-up name from a known listed one
    case fail(String)          // the check gave a wrong answer or the page changed: fix the definition
    case blocked               // the site refused the request, so it cannot be checked automatically from here
    case needsResearch         // no `recheck:` block yet
}

public struct StepProbe: Equatable, Sendable {
    public var url: URL
    public var status: Int?       // nil when the request failed
    public var blocked: Bool
}

public struct PipelineRow: Sendable {
    public var broker: Broker
    public var steps: [StepProbe]
    public var absentName: CheckOutcome?     // made-up name, expected: removed
    public var listedName: CheckOutcome?     // known listed name, expected: stillListed
    public var yourScan: CheckOutcome?       // optional real person (local runs only)
    public var status: PipelineStatus
}

public struct BrokerPipeline: Sendable {
    private let fetcher: PageFetcher
    private let spacing: TimeInterval
    static let madeUpName = "Zzyzx Qwertyuiop"

    public init(fetcher: PageFetcher, spacing: TimeInterval = 2) {
        self.fetcher = fetcher; self.spacing = spacing
    }

    public func run(_ brokers: [Broker], person: Person? = nil) async -> [PipelineRow] {
        var rows: [PipelineRow] = []
        for broker in brokers.sorted(by: { $0.id < $1.id }) {
            rows.append(await runOne(broker, person: person))
        }
        return rows
    }

    private func pause() async { if spacing > 0 { try? await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000)) } }

    private func runOne(_ broker: Broker, person: Person?) async -> PipelineRow {
        var probes: [StepProbe] = []
        for url in broker.steps.compactMap(\.open) {
            let page = try? await fetcher.fetch(url)
            let text = page?.text.lowercased() ?? ""
            let blocked = page.map { [403, 429, 503].contains($0.status) || Rechecker.hardChallengeMarkers.contains(where: text.contains) } ?? false
            probes.append(StepProbe(url: url, status: page?.status, blocked: blocked))
            await pause()
        }
        var row = PipelineRow(broker: broker, steps: probes, status: .needsResearch)
        guard let spec = broker.recheck else { return row }

        let checker = Rechecker(fetcher: fetcher)
        let place = Address(city: spec.calibration?.city ?? "Springfield", state: spec.calibration?.state ?? "IL")
        let absent = Person(displayName: "absent", names: [NameEntry(kind: .legal, name: Self.madeUpName)], addresses: [place])
        row.absentName = await checker.check(broker, for: absent); await pause()
        if let cal = spec.calibration {
            let listed = Person(displayName: "listed", names: [NameEntry(kind: .legal, name: cal.listedName)], addresses: [place])
            row.listedName = await checker.check(broker, for: listed); await pause()
        }
        if let person { row.yourScan = await checker.check(broker, for: person); await pause() }
        row.status = Self.judge(row)
        return row
    }

    static func judge(_ row: PipelineRow) -> PipelineStatus {
        let outcomes = [row.absentName, row.listedName].compactMap { $0 }
        if outcomes.contains(where: { $0 == .inconclusive(.blocked) }) { return .blocked }
        if let a = row.absentName, a != .removed { return .fail("made-up name read as \(describe(a)), expected removed") }
        if row.broker.recheck?.calibration != nil {
            if let l = row.listedName, l != .stillListed { return .fail("known listed name read as \(describe(l)), expected still listed") }
        }
        return .pass
    }

    static func describe(_ o: CheckOutcome) -> String {
        o.result == .inconclusive ? "inconclusive (\(o.reason?.rawValue ?? "?"))" : o.result.rawValue
    }

    // MARK: Report

    public static func markdown(_ rows: [PipelineRow], date: Date = Date()) -> String {
        func cell(_ o: CheckOutcome?) -> String { o.map(describe) ?? "–" }
        func icon(_ s: PipelineStatus) -> String {
            switch s {
            case .pass: return "PASS"
            case .fail(let why): return "FAIL: \(why)"
            case .blocked: return "BLOCKED"
            case .needsResearch: return "NEEDS RESEARCH"
            }
        }
        var out = "# Broker pipeline report\n\nRun \(ISO8601DateFormatter().string(from: date)). Read-only: nothing was submitted.\n\n"
        let pass = rows.filter { $0.status == .pass }.count
        let fail = rows.filter { if case .fail = $0.status { return true } else { return false } }.count
        let blocked = rows.filter { $0.status == .blocked }.count
        let todo = rows.filter { $0.status == .needsResearch }.count
        out += "**\(rows.count) brokers: \(pass) pass, \(fail) fail, \(blocked) blocked, \(todo) need research.**\n\n"
        out += "| Broker | Status | Made-up name (expect removed) | Known name (expect listed) | Step pages |\n|---|---|---|---|---|\n"
        for r in rows {
            let pages = r.steps.map { p in
                "\(p.status.map(String.init) ?? "no reply")\(p.blocked ? " blocked" : "")"
            }.joined(separator: ", ")
            out += "| \(r.broker.id) | \(icon(r.status)) | \(cell(r.absentName)) | \(cell(r.listedName)) | \(pages.isEmpty ? "–" : pages) |\n"
        }
        if rows.contains(where: { $0.yourScan != nil }) {
            out += "\n## Your scan (local run only, not for CI)\n\n| Broker | Result |\n|---|---|\n"
            for r in rows where r.yourScan != nil { out += "| \(r.broker.id) | \(cell(r.yourScan)) |\n" }
        }
        return out
    }
}

/// Counts how many sites a plain request can reach, to size the automation opportunity.
public enum Census {
    public enum Class: String, CaseIterable, Sendable { case reachable, captchaMarker = "captcha marker", blocked, unreachable }

    public static func classify(_ page: FetchedPage?) -> Class {
        guard let page else { return .unreachable }
        let t = page.text.lowercased()
        if [403, 429, 503].contains(page.status) || Rechecker.hardChallengeMarkers.contains(where: t.contains) { return .blocked }
        if ["turnstile", "recaptcha", "hcaptcha", "px-captcha", "datadome"].contains(where: t.contains) { return .captchaMarker }
        return (200..<400).contains(page.status) ? .reachable : .unreachable
    }

    public static func run(domains: [String], fetcher: PageFetcher, spacing: TimeInterval = 0.5) async -> [String: Class] {
        var out: [String: Class] = [:]
        for d in domains {
            out[d] = classify(try? await fetcher.fetch(URL(string: "https://\(d)/")!))
            if spacing > 0 { try? await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000)) }
        }
        return out
    }
}
