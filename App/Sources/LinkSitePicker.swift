import SwiftUI
import OptOutKitCore

/// A link that could belong to more than one site (a privacy-portal provider many sites share) or to none we recognize: the person says which site it is.
struct PendingLink: Identifiable {
    let id = UUID()
    /// The page to open once a site is chosen; nil when the page is already open and "Mark completed" asked which site to finish.
    let url: URL?
    let check: LinkCheck
}

/// "Which site is this for?": the sites that share the link's address first (those waiting on an email on top), then a search through every site in the list.
struct LinkSitePicker: View {
    let pending: PendingLink
    let sites: SiteIndex
    private var directory: [DirectoryEntry] { sites.entries }
    /// Entry ids of the sites waiting on an email.
    let waiting: Set<String>
    var choose: (DirectoryEntry) -> Void
    /// Open the page without naming a site: nothing is filled in or marked for it. Nil when the page is already open.
    var openAnyway: (() -> Void)?
    var cancel: () -> Void
    @State private var query = ""

    private var host: String {
        switch pending.check {
        case .shared(let h, _), .unknown(let h): return h
        case .known: return ""
        }
    }
    private var suggested: [DirectoryEntry] {
        guard case .shared(_, let ids) = pending.check else { return [] }
        return ids.compactMap { sites[id: $0] }
    }
    private var waitingElsewhere: [DirectoryEntry] {
        let shown = Set(suggested.map(\.id))
        return directory.filter { waiting.contains($0.id) && !shown.contains($0.id) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(intro).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    if !suggested.isEmpty {
                        Section { ForEach(suggested) { row($0) } } header: { Text(Loc.f("Sites that use %@", host)) }
                    }
                    if !waitingElsewhere.isEmpty {
                        Section { ForEach(waitingElsewhere) { row($0) } } header: { Text("Waiting on an email") }
                    }
                } else {
                    let found = LinkCheck.find(query, in: directory)
                    Section {
                        if found.isEmpty { Text("No site matches that. Try part of its name or its web address.").foregroundStyle(.secondary) }
                        ForEach(found) { row($0) }
                    } header: { Text("All sites") }
                }
                if let openAnyway {
                    Section { Button { openAnyway() } label: { Label("It is none of these: open the link anyway", systemImage: "exclamationmark.triangle") }
                        .accessibilityIdentifier("link-pick-anyway") } footer: { Text("Nothing is filled in or marked finished for a link we cannot match to a site. Only open it if you trust where it came from.") }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search all sites"))
            .navigationTitle("Which site is this for?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel).accessibilityIdentifier("link-pick-cancel") } }
        }
        .presentationDetents([.large])
    }

    private var intro: String {
        if case .shared = pending.check { return Loc.f("This link is from %@, an address that more than one site uses, so we cannot tell which request it belongs to. Choose the site, so the right one is filled in and marked finished.", host) }
        return Loc.f("%@ is not an address we know for any site in your list. If the link is from one of your requests, search for that site and choose it.", host)
    }

    private func row(_ e: DirectoryEntry) -> some View {
        Button { choose(e) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.name).foregroundStyle(.primary)
                    Text(e.domain).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if waiting.contains(e.id) { Text("Waiting on an email").font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 3).background(.tint.opacity(0.15), in: Capsule()) }
            }
        }.accessibilityIdentifier("link-pick-\(e.domain)")
    }
}
