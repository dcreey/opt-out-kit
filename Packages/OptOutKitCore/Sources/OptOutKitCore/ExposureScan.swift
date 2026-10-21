import Foundation

public struct ScanResult: Equatable, Sendable, Identifiable {
    public var entry: DirectoryEntry
    public var outcome: CheckOutcome
    public var id: String { entry.id }
}

/// "Where am I listed right now?" Runs the learned name search against every directory site that can be checked
/// automatically. Read-only: nothing is submitted and nothing is stored.
public struct ExposureScan: Sendable {
    private let fetcher: PageFetcher
    private let browserFetcher: PageFetcher?
    private let perHostSpacing: TimeInterval

    public init(fetcher: PageFetcher, browserFetcher: PageFetcher? = nil, perHostSpacing: TimeInterval = 1) {
        self.fetcher = fetcher; self.browserFetcher = browserFetcher; self.perHostSpacing = perHostSpacing
    }

    /// The sites a scan can cover, and why the rest cannot be checked.
    public static func scannable(_ entries: [DirectoryEntry]) -> [DirectoryEntry] {
        entries.filter { $0.searchCheck?.recheck != nil }
    }

    /// Runs up to `concurrency` sites at a time (each site is hit once, so no host is hammered). `progress` is called
    /// after every site with (done, total).
    public func run(_ entries: [DirectoryEntry], for person: Person, concurrency: Int = 4,
                    progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [ScanResult] {
        let targets = Self.scannable(entries)
        let rechecker = Rechecker(fetcher: fetcher, browserFetcher: browserFetcher)
        var results: [ScanResult] = []
        var index = 0
        await withTaskGroup(of: ScanResult.self) { group in
            func next() {
                guard index < targets.count, let spec = targets[index].searchCheck?.recheck else { return }
                let entry = targets[index]; index += 1
                group.addTask {
                    let outcome = await rechecker.check(spec: spec, for: person)
                    if perHostSpacingNanos > 0 { try? await Task.sleep(nanoseconds: perHostSpacingNanos) }
                    return ScanResult(entry: entry, outcome: outcome)
                }
            }
            for _ in 0..<min(concurrency, targets.count) { next() }
            for await r in group {
                results.append(r)
                progress?(results.count, targets.count)
                next()
            }
        }
        return results.sorted { $0.entry.domain < $1.entry.domain }
    }

    private var perHostSpacingNanos: UInt64 { UInt64(perHostSpacing * 1_000_000_000) }
}
