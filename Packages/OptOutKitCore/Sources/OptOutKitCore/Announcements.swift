import Foundation

/// A message worth showing once. Ids only go up; the highest id is the newest.
public struct Announcement: Equatable, Identifiable, Sendable {
    public var id: Int
    public var title: String
    public var body: String
    public init(id: Int, title: String, body: String) { self.id = id; self.title = title; self.body = body }
}

public enum Pending: Equatable, Sendable {
    case walkthrough               // first install: show the full walkthrough
    case whatsNew([Announcement])  // an update that carries new messages
    case nothing
}

public enum Announcements {
    /// `lastSeen` is the newest announcement id the user has already been shown, nil on a fresh install.
    /// Updates that add no new announcement show nothing.
    public static func pending(lastSeen: Int?, catalog: [Announcement]) -> Pending {
        guard let lastSeen else { return .walkthrough }
        let fresh = catalog.filter { $0.id > lastSeen }.sorted { $0.id < $1.id }
        return fresh.isEmpty ? .nothing : .whatsNew(fresh)
    }

    public static func newestID(_ catalog: [Announcement]) -> Int { catalog.map(\.id).max() ?? 0 }
}
