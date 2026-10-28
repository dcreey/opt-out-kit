import SwiftUI
import OptOutKitCore

/// One site in the Sites tab's lists: which task finishes it, and when it was sent if it was.
struct SiteRow: Identifiable {
    let domain: String
    let task: PlanTask?
    let date: Date?
    var id: String { domain }
}

extension AppModel {
    /// Every site once, in queue order (what comes next on the home page first), split into the ones already sent and the ones still to do.
    /// Done sites are newest first; those with no date (covered by an official service, or emailed) come last.
    func siteRows() -> (done: [SiteRow], todo: [SiteRow]) {
        let byDomain = entryByDomain
        var seen = Set<String>(), done: [SiteRow] = [], todo: [SiteRow] = []
        func sent(_ entryID: String?) -> Date? { entryID.flatMap { progress.optOutAttempts[$0] }?.filter(\.wasSubmitted).map(\.date).max() }
        for band in queue {
            for task in band.tasks {
                let taskDone = isDone(task)
                var leadDate: Date?
                if case .site(let id) = task.kind { leadDate = sent(id) }
                for d in task.domains where seen.insert(d).inserted {
                    let date = sent(byDomain[d]?.id) ?? (taskDone ? leadDate : nil)
                    if date != nil || taskDone { done.append(SiteRow(domain: d, task: task, date: date)) }
                    else { todo.append(SiteRow(domain: d, task: task, date: nil)) }
                }
            }
        }
        done.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return (done, todo)
    }
}

struct SiteRowView: View {
    @EnvironmentObject var model: AppModel
    let row: SiteRow
    let completed: Bool

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: completed ? "checkmark.circle.fill" : "circle").foregroundStyle(completed ? .green : .secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.domain).font(.headline)
                if completed {
                    Text(row.date.map { Loc.f("Sent %@", Loc.date($0)) } ?? Loc.t("Done")).font(.caption).foregroundStyle(.secondary)
                } else if let task = row.task {
                    Text(task.method?.title ?? task.title).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The few sites the Sites tab shows by default: the ten most recent done, the ten next to do, and a way into the whole list of each.
struct SiteOverviewSections: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let rows = model.siteRows()
        group(title: Loc.t("Done"), rows: rows.done, completed: true, mode: .completed, empty: Loc.t("Nothing sent yet. Sites you finish show up here, newest first."))
        group(title: Loc.t("Up next"), rows: rows.todo, completed: false, mode: .todo, empty: Loc.t("Everything is done. Check back later: listings come back."))
    }

    @ViewBuilder
    private func group(title: String, rows: [SiteRow], completed: Bool, mode: SiteListView.Mode, empty: String) -> some View {
        Section {
            if rows.isEmpty { Text(empty).font(.footnote).foregroundStyle(.secondary) }
            ForEach(rows.prefix(10)) { row in
                if let task = row.task {
                    NavigationLink(value: task) { SiteRowView(row: row, completed: completed) }.accessibilityIdentifier("site-\(row.domain)")
                } else { SiteRowView(row: row, completed: completed) }
            }
            if rows.count > 10 {
                NavigationLink { SiteListView(mode: mode) } label: {
                    Label(completed ? Loc.f("Search all %lld done", rows.count) : Loc.f("Search all %lld to do", rows.count), systemImage: "magnifyingglass")
                }.accessibilityIdentifier(completed ? "all-done-sites" : "all-todo-sites")
            }
        } header: {
            Text("\(title) (\(rows.count))").font(.subheadline.bold()).textCase(nil)
        }
    }
}

/// Every done (or still to do) site, with a search box and the same filters as the Sites tab.
struct SiteListView: View {
    enum Mode { case completed, todo }
    @EnvironmentObject var model: AppModel
    let mode: Mode
    @State private var search = ""
    @State private var fCategory: BrokerCategory?
    @State private var fData: DataKind?
    @State private var fBuyer: BuyerKind?
    private var filtering: Bool { fCategory != nil || fData != nil || fBuyer != nil }

    var body: some View {
        let all = mode == .completed ? model.siteRows().done : model.siteRows().todo
        let byDomain = model.entryByDomain
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = all.filter { row in
            if filtering, !(byDomain[row.domain]?.matches(category: fCategory, data: fData, buyer: fBuyer) ?? false) { return false }
            return q.isEmpty || row.domain.lowercased().contains(q) || (byDomain[row.domain]?.name.lowercased().contains(q) ?? false)
        }
        List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search by name or web address", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("site-list-search")
                }
            } footer: {
                Text(Loc.f("Showing %lld of %lld sites.", rows.count, all.count))
            }
            Section {
                ForEach(rows) { row in
                    if let task = row.task {
                        NavigationLink(value: task) { SiteRowView(row: row, completed: mode == .completed) }
                    } else { SiteRowView(row: row, completed: mode == .completed) }
                }
            }
        }
        .navigationTitle(mode == .completed ? Loc.t("Done sites") : Loc.t("Sites to do"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Type of company", selection: $fCategory) {
                        Text("Any type").tag(BrokerCategory?.none)
                        ForEach(BrokerCategory.allCases, id: \.self) { Text($0.title).tag(BrokerCategory?.some($0)) }
                    }
                    Picker("Data they collect", selection: $fData) {
                        Text("Any data").tag(DataKind?.none)
                        ForEach(DataKind.allCases, id: \.self) { Text($0.title).tag(DataKind?.some($0)) }
                    }
                    Picker("Who they sell to", selection: $fBuyer) {
                        Text("Anyone").tag(BuyerKind?.none)
                        ForEach(BuyerKind.allCases, id: \.self) { Text($0.title).tag(BuyerKind?.some($0)) }
                    }
                    if filtering { Button("Clear filters", role: .destructive) { fCategory = nil; fData = nil; fBuyer = nil } }
                } label: { Image(systemName: filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
            }
        }
    }
}
