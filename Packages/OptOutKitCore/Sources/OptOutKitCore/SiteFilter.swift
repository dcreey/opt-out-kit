import Foundation

/// Where a site stands for the person, as the Sites tab groups it.
public enum SiteStatus: String, CaseIterable, Sendable {
    case todo, skipped, done

    /// Set aside wins over done (a site skipped after a send that has since run out is skipped, not due); a send that still holds is done, and so is a site
    /// a recent look found no listing on (`Progress.notListedRecently`).
    /// `taskDone` is the task's own answer, for sites finished through a shared task (an official service, an email) with no send of their own.
    public static func of(_ entry: DirectoryEntry?, progress: Progress, taskDone: Bool, now: Date = Date()) -> SiteStatus {
        if let e = entry, progress.isParked(e.id, now: now) { return .skipped }
        if let e = entry, e.isHandled(progress, now: now) { return .done }          // sent and still holding, or nothing there to opt out of until it is searched again
        if taskDone, entry?.lastSent(in: progress.optOutAttempts) == nil { return .done }
        return .todo
    }
}

/// The search screen's filters. A nil field accepts everything; a site we know nothing about fails a filter on what it is.
public struct SiteFilter: Equatable, Sendable {
    public var text = ""
    public var status: SiteStatus?
    /// true: only sites that reach the person (`RegionSummary.inRegion`); false: only those that do not.
    public var inRegion: Bool?
    public var category: BrokerCategory?
    public var data: DataKind?
    public var buyer: BuyerKind?
    public var method: OptOutMethod?

    public init(status: SiteStatus? = nil) { self.status = status }

    /// Whether any filter other than the search text is set.
    public var narrowed: Bool { status != nil || inRegion != nil || category != nil || data != nil || buyer != nil || method != nil }

    public mutating func clear() { let t = text; self = SiteFilter(); text = t }

    /// Whether a site fits. The text matches the web address, the company's name, or `alsoNamed` (the name of the hand-written flow or
    /// official service that handles it, so "peopleconnect" finds TruthFinder), ignoring case and spaces around it; or the site is among
    /// `searchHits`, what the catalog's full-text search found (`Catalog.search`: what the company is, holds and sells, its description).
    public func accepts(domain: String, entry: DirectoryEntry?, status: SiteStatus, inRegion: Bool, method: OptOutMethod?, alsoNamed: String? = nil,
                        searchHits: Set<String>? = nil) -> Bool {
        if let s = self.status, s != status { return false }
        if let r = self.inRegion, r != inRegion { return false }
        if let m = self.method, m != method { return false }
        if category != nil || data != nil || buyer != nil {
            guard let entry, entry.matches(category: category, data: data, buyer: buyer) else { return false }
        }
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return namesMatch(domain: domain, entry: entry, alsoNamed: alsoNamed) || (entry.map { searchHits?.contains($0.id) ?? false } ?? false)
    }

    /// Whether the text appears in the web address, the company's name or `alsoNamed`: such a site is listed before the other search hits.
    public func namesMatch(domain: String, entry: DirectoryEntry?, alsoNamed: String? = nil) -> Bool {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return false }
        return domain.lowercased().contains(q) || (entry?.name.lowercased().contains(q) ?? false) || (alsoNamed?.lowercased().contains(q) ?? false)
    }
}
