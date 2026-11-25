import SwiftUI
import OptOutKitCore

/// One site in the Sites tab's lists: which task finishes it, where it stands, and the date that goes with that (sent, or set aside).
struct SiteRow: Identifiable {
    let domain: String
    let entry: DirectoryEntry?
    let task: PlanTask?
    let status: SiteStatus
    let date: Date?
    /// Whether the company reaches the person (`RegionSummary.inRegion`), worked out once with the row.
    let inRegion: Bool
    var id: String { domain }
    /// The name of the hand-written flow or official service that handles this site, which search also matches.
    var handlerName: String? {
        switch task?.kind { case .flow?, .platform?: return task?.title; default: return nil }
    }
}

/// Every site once, split by where it stands: up next in queue order (what comes next on the home page first), skipped and done newest first.
struct SiteRows {
    var todo: [SiteRow] = []
    var skipped: [SiteRow] = []
    var done: [SiteRow] = []
    func rows(_ s: SiteStatus) -> [SiteRow] { switch s { case .todo: return todo; case .skipped: return skipped; case .done: return done } }
    var count: Int { todo.count + skipped.count + done.count }
    /// The first site still up next that has a page of its own and is not in `walked`: what "Open the next site?" offers after a guide is finished.
    func nextToOffer(excluding walked: Set<String>) -> DirectoryEntry? { todo.compactMap(\.entry).first { !walked.contains($0.domain) } }
}

extension AppModel {
    /// Every site once, in queue order, with where it stands (`SiteStatus.of`): the one rule for "done" on the Sites tab and on the home page.
    private func eachSiteStatus(_ body: (String, DirectoryEntry?, PlanTask, SiteStatus) -> Void) {
        let byDomain = entryByDomain, p = progress
        var seen = Set<String>()
        for band in queue {
            for task in band.tasks {
                let taskDone = isDone(task)
                for d in task.domains where seen.insert(d).inserted {
                    let e = byDomain[d]
                    body(d, e, task, SiteStatus.of(e, progress: p, taskDone: taskDone))
                }
            }
        }
    }

    /// How many sites are done: the Sites tab's "Done" count, without building its rows (the home page shows it, and it is drawn after every site of a run).
    var doneSiteCount: Int { var n = 0; eachSiteStatus { _, _, _, s in if s == .done { n += 1 } }; return n }

    func siteRows() -> SiteRows {
        let p = progress, country = ownerCountry, local = localStates
        var out = SiteRows()
        eachSiteStatus { d, e, task, status in
            let reach = e.map { Regions.summary(for: $0, country: country, localStates: local).inRegion } ?? ((country ?? "US") == "US")
            switch status {
            case .todo: out.todo.append(SiteRow(domain: d, entry: e, task: task, status: status, date: nil, inRegion: reach))
            case .skipped: out.skipped.append(SiteRow(domain: d, entry: e, task: task, status: status, date: e.flatMap { p.lastSkip($0.id)?.date }, inRegion: reach))
            case .done: out.done.append(SiteRow(domain: d, entry: e, task: task, status: status, date: e?.lastSent(in: p.optOutAttempts), inRegion: reach))
            }
        }
        // Done sites with no date of their own (covered by an official service, or emailed) come last.
        out.done.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        out.skipped.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return out
    }
}

extension SiteStatus {
    var title: String {
        switch self { case .todo: return Loc.t("Up next"); case .skipped: return Loc.t("Skipped"); case .done: return Loc.t("Done") }
    }
}

extension OptOutMethod {
    /// A word or two for a filter chip.
    var shortTitle: String {
        switch self {
        case .automatic: return Loc.t("Automatic")
        case .semiAutomatic: return Loc.t("Semi-automatic")
        case .emailOnly: return Loc.t("Email")
        case .manual: return Loc.t("No route yet")
        }
    }
}
