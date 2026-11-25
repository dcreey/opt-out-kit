import SwiftUI
import OptOutKitCore

struct SiteRowView: View {
    @EnvironmentObject var model: AppModel
    let row: SiteRow

    var body: some View {
        // The shared row, so the site's name starts where the words of the page's other rows do (docs/UX.md, "Alignment").
        IconRow(icon: symbol, tint: color, spacing: 2) {
            Text(row.domain).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch row.status { case .done: return "checkmark.circle.fill"; case .skipped: return "arrow.uturn.right.circle"; case .todo: return "circle" }
    }
    private var color: Color {
        switch row.status { case .done: return .green; case .skipped: return .orange; case .todo: return .secondary }
    }
    private var detail: String {
        switch row.status {
        case .done: return row.date.map { Loc.f("Sent %@", Loc.date($0)) } ?? Loc.t("Done")
        case .skipped:
            guard let e = row.entry else { return Loc.t("Skipped") }
            if model.isSkippedForever(e.id) { return Loc.t("Skipped for good") }
            return model.progress.skipReturns(e.id).map { Loc.f("Skipped until %@", Loc.date($0)) } ?? Loc.t("Skipped")
        case .todo:
            if let e = row.entry, e.lastSent(in: model.progress.optOutAttempts) != nil { return Loc.t("Due again") }
            return row.task.map { $0.method?.title ?? $0.title } ?? ""
        }
    }
}

/// The rows of a list of sites. The first row of each task carries the task's id (`task-…`), so a shared task is found once.
struct SiteRowsList: View {
    let rows: [SiteRow]
    var body: some View {
        var seen = Set<String>()
        ForEach(rows) { row in
            if let task = row.task {
                let lead = seen.insert(task.id).inserted
                NavigationLink(value: task) { SiteRowView(row: row) }
                    .accessibilityIdentifier(lead ? "task-\(task.id)" : "site-\(row.domain)")
            } else { SiteRowView(row: row) }
        }
    }
}

/// The few sites the Sites tab shows by default: the ten most recent done, the ten most recently skipped and the ten next to do,
/// each with a way into the search screen with that status already chosen.
struct SiteOverviewSections: View {
    @EnvironmentObject var model: AppModel
    let rows: SiteRows
    /// Opens the search screen with this status chosen.
    let seeAll: (SiteStatus) -> Void
    var body: some View {
        group(.done, empty: Loc.t("Nothing sent yet. Sites you finish show up here, newest first."))
        group(.skipped, empty: Loc.t("Nothing skipped. Sites you set aside show up here."))
        group(.todo, empty: Loc.t("Everything is done. Check back later: listings come back."))
    }

    @ViewBuilder
    private func group(_ status: SiteStatus, empty: String) -> some View {
        let list = rows.rows(status)
        Section {
            if list.isEmpty { Text(empty).font(.footnote).foregroundStyle(.secondary) }
            SiteRowsList(rows: Array(list.prefix(10)))
            if list.count > 10 {
                Button { seeAll(status) } label: {
                    HStack {
                        Label(Loc.f("See all %lld", list.count), systemImage: "line.3.horizontal.decrease.circle")
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.accessibilityIdentifier("all-\(status.rawValue)-sites")
            }
        } header: {
            Text("\(status.title) (\(list.count))").font(.subheadline.bold()).textCase(nil)
        }
    }
}

/// Every site, searched and filtered: by where it stands (chosen already when opened from one of the Sites tab's groups), whether the
/// company reaches the person, what kind of company it is, what it tracks, who it sells to and how its opt-out is done.
/// The search screen, as a place on the Sites tab's navigation path.
struct SiteSearchRoute: Hashable {}

/// What the search screen is showing. The Sites tab owns it, so the choices survive SwiftUI rebuilding the pushed screen.
@MainActor
final class SiteSearchState: ObservableObject {
    @Published var filter = SiteFilter()
    @Published var rows = SiteRows()
    /// Set when the screen is opened from the tab's search field: the field takes focus once the push has finished.
    var focusPending = false

    func open(status: SiteStatus?, focus: Bool) {
        filter = SiteFilter(status: status)
        focusPending = focus
    }
}

struct SiteSearchView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var state: SiteSearchState
    @FocusState private var focused: Bool
    private var filter: SiteFilter { state.filter }
    private var rows: SiteRows { state.rows }

    var body: some View {
        let shown = SiteStatus.allCases.filter { filter.status == nil || filter.status == $0 }
        // What the catalog's search finds, best first; with text typed, sites whose name or address matches come first, then the others by that rank.
        let ranked = filter.text.isEmpty ? [] : model.siteSearch(filter.text)
        let rank = Dictionary(ranked.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let hits = Set(ranked)
        let results = Dictionary(uniqueKeysWithValues: shown.map { s in
            let found = rows.rows(s).filter { filter.accepts(domain: $0.domain, entry: $0.entry, status: $0.status, inRegion: $0.inRegion, method: $0.task?.method, alsoNamed: $0.handlerName, searchHits: hits) }
            guard !filter.text.isEmpty else { return (s, found) }
            let ordered = found.enumerated().sorted { a, b in
                let ka = (filter.namesMatch(domain: a.element.domain, entry: a.element.entry, alsoNamed: a.element.handlerName) ? 0 : 1, a.element.entry.flatMap { rank[$0.id] } ?? Int.max, a.offset)
                let kb = (filter.namesMatch(domain: b.element.domain, entry: b.element.entry, alsoNamed: b.element.handlerName) ? 0 : 1, b.element.entry.flatMap { rank[$0.id] } ?? Int.max, b.offset)
                return ka < kb
            }.map(\.element)
            return (s, ordered)
        })
        let total = results.values.reduce(0) { $0 + $1.count }
        List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search by name, web address or what they do", text: $state.filter.text)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focused)
                        .accessibilityIdentifier("site-search-field")
                    if !filter.text.isEmpty { Button { state.filter.text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }
                filterChips.listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            } footer: {
                Text(Loc.f("Showing %lld of %lld sites.", total, rows.count)).accessibilityIdentifier("site-search-count")
            }
            ForEach(shown, id: \.self) { s in
                if let list = results[s], !list.isEmpty {
                    Section {
                        SiteRowsList(rows: list)
                    } header: {
                        Text("\(s.title) (\(list.count))").font(.subheadline.bold()).textCase(nil)
                    }
                }
            }
            if total == 0, rows.count > 0 {
                Section { Text("No site matches that search.").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(Loc.t("Search sites"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { state.rows = model.siteRows() }
        .task {
            guard state.focusPending else { return }
            state.focusPending = false
            // Focus set during the push animation is dropped, so wait for it to finish.
            try? await Task.sleep(nanoseconds: 450_000_000)
            focused = true
        }
    }

    private var filterChips: some View {
        // Every chip in view at once: they wrap onto a second line instead of scrolling sideways.
        ChipFlow(spacing: 8) {
            Group {
                if filter.narrowed {
                    Button { state.filter.clear() } label: { Image(systemName: "xmark").font(.footnote.bold()).padding(7).background(Circle().fill(Color(.secondarySystemFill))) }
                        .buttonStyle(.plain).accessibilityLabel(Loc.t("Clear filters")).accessibilityIdentifier("filter-clear")
                }
                chip(Loc.t("Status"), $state.filter.status, SiteStatus.allCases, { $0.title }, any: Loc.t("Any status"), id: "filter-status")
                chip(Loc.t("Region"), $state.filter.inRegion, [true, false], { $0 ? Loc.t("In your area") : Loc.t("Not in your area") }, any: Loc.t("Anywhere"), id: "filter-region")
                chip(Loc.t("Type"), $state.filter.category, BrokerCategory.allCases, { $0.title }, any: Loc.t("Any type"), id: "filter-type")
                chip(Loc.t("Tracks"), $state.filter.data, DataKind.allCases, { $0.title }, any: Loc.t("Any data"), id: "filter-tracks")
                chip(Loc.t("Sells to"), $state.filter.buyer, BuyerKind.allCases, { $0.title }, any: Loc.t("Anyone"), id: "filter-sells")
                chip(Loc.t("Method"), $state.filter.method, [.automatic, .semiAutomatic, .emailOnly], { $0.shortTitle }, any: Loc.t("Any method"), id: "filter-method")
            }
        }
        .padding(.horizontal, 16)
    }

    private func chip<T: Hashable>(_ name: String, _ value: Binding<T?>, _ options: [T], _ title: @escaping (T) -> String, any: String, id: String) -> some View {
        let set = value.wrappedValue != nil
        return Menu {
            option(any, chosen: !set) { value.wrappedValue = nil }
            ForEach(options, id: \.self) { o in option(title(o), chosen: value.wrappedValue == o) { value.wrappedValue = o } }
        } label: {
            HStack(spacing: 4) {
                Text(value.wrappedValue.map(title) ?? name).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.caption2.bold())
            }
            .font(.footnote.weight(.medium))
            .frame(maxWidth: 220)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .foregroundStyle(set ? Color.white : Color.primary)
            .background(Capsule().fill(set ? Color.accentColor : Color(.secondarySystemFill)))
        }
        .accessibilityIdentifier(id)
    }

    @ViewBuilder private func option(_ text: String, chosen: Bool, _ pick: @escaping () -> Void) -> some View {
        Button(action: pick) { if chosen { Label(text, systemImage: "checkmark") } else { Text(text) } }
    }
}

/// Lays its views out left to right and starts a new line when the next one does not fit.
struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].items.isEmpty { rows.append(Row()) }
            var row = rows[rows.count - 1]
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
