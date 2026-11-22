import Foundation
import OptOutKitCore

/// A small, repeatable sample of the sites that have a form, spread over every kind of site rather than the first few in the list: what the integration tests run
/// the automatic run over for a release (`-uitest-sites N`); the weekly job runs every site. The kinds are what decides how a site is handled: its group, its
/// tier, how it is automated, and whether it is a search-first site, a stored form or a form found on the live page.
enum SiteSample {
    /// The kind a site belongs to: sites of one kind are handled by the same code, so the sample takes some of each.
    static func kind(_ e: DirectoryEntry) -> String {
        let how = e.searchCheck != nil ? "search" : (e.optOutForm != nil ? "form" : "live")
        return [e.bucket, e.tier.map { "\($0)" } ?? "-", "\(e.automation)", how, e.contactEmail != nil ? "email" : "-"].joined(separator: "|")
    }

    /// Up to `count` of the sites with a form: one from each kind in turn (kinds with the most sites last), then a second from each, and so on, so every kind is in
    /// the sample before any is in it twice. Within a kind the sites are spread evenly over its id order. The same directory always gives the same sample.
    static func pick(_ entries: [DirectoryEntry], count: Int) -> [DirectoryEntry] {
        let withForm = entries.filter { $0.optOutForm != nil || $0.liveForm?.found == true }.sorted { $0.id < $1.id }
        guard count > 0, withForm.count > count else { return Array(withForm.prefix(max(count, 0))) }
        var groups: [String: [DirectoryEntry]] = [:]
        for e in withForm { groups[kind(e), default: []].append(e) }
        // Each kind's sites in the order they are taken: by the bit-reversed position, which visits the middle first and then fills the gaps evenly.
        func spread(_ list: [DirectoryEntry]) -> [DirectoryEntry] {
            let bits = max(1, Int(ceil(log2(Double(max(list.count, 2))))))
            func reversed(_ i: Int) -> Int { (0..<bits).reduce(0) { $0 | (((i >> $1) & 1) << (bits - 1 - $1)) } }
            return list.indices.sorted { (reversed($0), $0) < (reversed($1), $1) }.map { list[$0] }
        }
        let ordered = groups.keys.sorted { (groups[$0]!.count, $0) < (groups[$1]!.count, $1) }.map { spread(groups[$0]!) }
        var out: [DirectoryEntry] = []
        var round = 0
        while out.count < count {
            var took = false
            for g in ordered where round < g.count && out.count < count { out.append(g[round]); took = true }
            if !took { break }
            round += 1
        }
        return out
    }
}
