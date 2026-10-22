import Foundation
import OptOutKitCore

enum AppInfo {
    /// Where the source lives. The repo is private until the pre-release checks pass (docs/DESIGN.md).
    static let repoURL = URL(string: "https://github.com/dcreey/opt-out-kit")!
}

/// Messages shown once. Add a new entry with a higher id to show a "What's new" card on update;
/// an update with no new entry shows nothing. A fresh install gets the full walkthrough instead.
enum AnnouncementCatalog {
    static let all: [Announcement] = [
        Announcement(id: 1, title: Loc.t("Welcome to Opt-Out Kit"),
                     body: Loc.t("Walk through each data broker, one step at a time.")),
    ]
}
