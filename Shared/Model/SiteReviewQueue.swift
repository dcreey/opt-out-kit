#if DEBUG
import Foundation
import OptOutKitCore

/// The admin review of sites with no readable form (`SiteReviewView`, DEBUG only): which sites to go through, and how tags from the web review page merge in.
enum SiteReviewQueue {
    struct Row: Identifiable, Equatable {
        let id: String
        let domain: String
        let name: String
        let url: URL?
        let email: String?
        let why: String
    }
    struct Tag: Codable, Equatable {
        var d: String
        var tag: String            // ok | other-page | search-first | email | account | none | dead | skip
        var url: String?
        var email: String?
        var note: String?
        var at: String
    }

    /// The sites to go through: no readable form (or one that asks for business details), most important first.
    static func rows(from entries: [DirectoryEntry]) -> [Row] {
        entries.filter { e in
            guard e.excluded == nil, e.closed == nil, e.optOutForm == nil else { return false }
            if let live = e.liveForm, live.found, !live.blockers.contains("business") { return false }
            return true
        }
        .sorted { ($0.priority ?? 0) > ($1.priority ?? 0) }
        .map { e in
            let business = e.liveForm?.blockers.contains("business") ?? false
            let why = business ? "A form on its page asks for business details" : (e.optOutURL != nil ? "Its page has no form the app can read" : "No opt-out page on file")
            return Row(id: e.id, domain: e.domain, name: e.name, url: e.optOutURL, email: e.contactEmail, why: why)
        }
    }

    /// Merges tags in; of two tags for one site the newer one wins. Returns how many were taken.
    @discardableResult static func merge(_ tags: inout [String: Tag], _ incoming: [Tag]) -> Int {
        var n = 0
        for t in incoming where tags[t.d] == nil || (tags[t.d]?.at ?? "") < t.at { tags[t.d] = t; n += 1 }
        return n
    }
}
#endif
