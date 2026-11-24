import Foundation
import OptOutKitCore

/// The automatic run as one file the person can hand to whoever is helping them (Activity page, "Export this run"): every site the run deals with, its
/// group and the reason shown on the page, its recent attempts with what the page said, its latest search, and the screenshot kept for it. Built in memory
/// and given to the system share sheet; the app sends it nowhere and writes no file (docs/PRINCIPLES.md 2, docs/STORAGE.md). It holds the person's details
/// as the sites showed them, which the page says before it is shared.
struct RunExport: Codable, Equatable {
    struct Attempt: Codable, Equatable {
        let date: Date
        let outcome: String
        let detail: String?
        let pageSaid: String?
    }
    struct Search: Codable, Equatable {
        let date: Date
        let result: String
        let source: String
    }
    struct Site: Codable, Equatable {
        /// Its place in the export, which starts its screenshot's file name.
        let n: Int
        let id: String
        let domain: String
        /// The Activity page's group (`ActivityGroup`: needsYou, notListed, sent, notTried) and its line under the site.
        let group: String
        let status: String
        let optOutURL: String?
        let formPage: String?
        /// The latest attempts, oldest first (at most `attemptsKept`).
        let attempts: [Attempt]
        let lastSearch: Search?
        /// The screenshot's file name in the archive, or nil when none was kept.
        let screenshot: String?
    }

    let app: String
    let build: String
    let exported: Date
    let runStarted: Date?
    let lastRun: Date?
    let periodStart: Date?
    let periodEnd: Date?
    /// How many sites are in each group.
    let counts: [String: Int]
    let sites: [Site]

    static let attemptsKept = 10
    /// The page's order: what needs the person first, then not listed, sent, and not tried; by domain within each.
    static let groupOrder: [ActivityGroup] = [.needsYou, .notListed, .sent, .notTried]

    static let readme = """
    Exnay run export

    run.json lists every site the automatic run deals with, in the order of the Activity page: the sites moved to semi-automatic first, then not listed,
    sent, and not tried. For each: its group and the line the page shows, its opt-out page, its latest attempts (outcome, detail, and what the page said),
    its latest search, and "screenshot", the picture in this archive of what the site showed at the end of its latest attempt (null when none was kept).

    This file holds your details as the sites showed them. The app made it only because you asked, and sent it nowhere: it goes only where you share it.
    """
}

extension AppModel {
    /// The export of `person`'s run as a zip (`StoredZip`): run.json, README.txt and one JPEG per site with a screenshot. The groups are worked out and the
    /// archive built away from the main thread; the sealed screenshots are read here.
    func runExport(for person: Person, now: Date = Date()) async -> Data {
        let inputs = activityInputs(for: person, now: now)
        let rows = await Task.detached(priority: .userInitiated) { AppModel.activityPage(inputs).rows }.value
        let files = runExportFiles(for: person, rows: rows, now: now)
        return await Task.detached(priority: .userInitiated) { StoredZip.make(files, date: now) }.value
    }

    /// The files of the export, in the archive's order: run.json, README.txt, then the screenshots.
    func runExportFiles(for person: Person, rows: [ActivityRow], now: Date = Date()) -> [(name: String, data: Data)] {
        let progress = household.progress(for: person.id)
        let order = Dictionary(uniqueKeysWithValues: RunExport.groupOrder.enumerated().map { ($1, $0) })
        let sorted = rows.sorted { (order[$0.group] ?? 9, $0.domain) < (order[$1.group] ?? 9, $1.domain) }
        var pictures: [(name: String, data: Data)] = []
        var listed: [RunExport.Site] = []
        for (i, row) in sorted.enumerated() {
            let n = i + 1
            var shot: String?
            if let jpeg = evidence.load(person: person.id, site: row.id) {
                shot = StoredZip.safeName(String(format: "%03d-%@.jpg", n, row.domain))
                pictures.append((shot!, jpeg))
            }
            let entry = sites[id: row.id]
            let attempts = (progress.optOutAttempts[row.id] ?? []).sorted { $0.date < $1.date }.suffix(RunExport.attemptsKept)
                .map { RunExport.Attempt(date: $0.date, outcome: $0.outcome, detail: $0.detail, pageSaid: $0.pageSaid) }
            let search = progress.latestSiteCheck(row.id).map { RunExport.Search(date: $0.date, result: $0.result.rawValue, source: $0.source.rawValue) }
            listed.append(RunExport.Site(n: n, id: row.id, domain: row.domain, group: row.group.rawValue, status: row.line,
                                         optOutURL: entry?.optOutURL?.absoluteString, formPage: entry?.optOutForm?.page.absoluteString,
                                         attempts: Array(attempts), lastSearch: search, screenshot: shot))
        }
        let period = runPeriod(now: now)
        let counts = Dictionary(grouping: rows, by: \.group.rawValue).mapValues(\.count)
        let export = RunExport(app: "Exnay", build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "", exported: now,
                               runStarted: autoSettings.runStarted, lastRun: autoSettings.lastOptOut, periodStart: period?.start, periodEnd: period?.end,
                               counts: counts, sites: listed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let json = (try? encoder.encode(export)) ?? Data()
        return [("run.json", json), ("README.txt", Data(RunExport.readme.utf8))] + pictures
    }
}
