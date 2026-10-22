import SwiftUI
import OptOutKitCore

extension PlanTask: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// What a band is worth, in one sentence: how many sites finishing it handles, and how many separate tasks that takes.
func bandSummary(_ band: QueueBand) -> String {
    band.tasks.count == 1 ? Loc.f("%lld sites in one task", band.siteCount)
        : band.siteCount == band.tasks.count ? Loc.f("%lld sites, one at a time", band.siteCount)
        : Loc.f("%lld sites in %lld tasks", band.siteCount, band.tasks.count)
}

struct QueueBandHeader: View {
    @EnvironmentObject var model: AppModel
    let band: QueueBand

    var body: some View {
        let done = band.tasks.filter { model.isDone($0) }.count
        HStack(alignment: .top, spacing: 12) {
            Text("\(band.rank.rawValue)").font(.headline).frame(width: 28, height: 28)
                .background(done == band.tasks.count ? Color.green : Color.accentColor, in: Circle()).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 3) {
                Text(band.rank.title).font(.headline)
                Text(bandSummary(band)).font(.subheadline).foregroundStyle(.secondary)
                Text(band.rank.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if done > 0 { Text(Loc.f("%lld of %lld done", done, band.tasks.count)).font(.caption).foregroundStyle(.green) }
            }
        }
    }
}

struct PlanTaskRow: View {
    @EnvironmentObject var model: AppModel
    let task: PlanTask

    var body: some View {
        let places = model.localStates
        HStack(alignment: .top) {
            Image(systemName: model.isDone(task) ? "checkmark.circle.fill" : "circle").foregroundStyle(model.isDone(task) ? .green : .secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.headline)
                if task.kind == .automatic { Text(Loc.f("%lld sites in one run", task.siteCount)).font(.caption.bold()).foregroundStyle(.blue) }
                else if task.isShared { Text(Loc.f("One request handles %lld sites", task.siteCount)).font(.caption.bold()).foregroundStyle(.blue) }
                Text(task.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !places.isEmpty, task.isRegistered(in: places) {
                    Label(Loc.f("Registered where you live: %@", task.registeredIn.intersection(places).sorted().joined(separator: ", ")), systemImage: "mappin.circle.fill")
                        .font(.caption).foregroundStyle(.teal)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .simultaneousGesture(TapGesture().onEnded { Keyboard.hide() })      // opening a task puts the keyboard away
    }
}

/// The page for one band of the queue: its tasks, nearest and biggest first.
struct BandDetailView: View {
    @EnvironmentObject var model: AppModel
    let rank: Int

    var body: some View {
        if let band = model.queue.first(where: { $0.rank.rawValue == rank }) {
            List {
                Section { QueueBandHeader(band: band) }
                Section {
                    ForEach(band.tasks) { task in
                        NavigationLink(value: task) { PlanTaskRow(task: task) }.accessibilityIdentifier("task-\(task.id)")
                    }
                }
            }
            .navigationTitle(band.rank.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Opens whatever a task or a step points at. Attach once on each navigation stack.
struct PlanDestinations: ViewModifier {
    @EnvironmentObject var model: AppModel

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: PlanTask.self) { task in
                switch task.kind {
                case .platform(let id):
                    if let p = model.platform(forWalkthrough: id) { BrokerDetailView(broker: model.walkthrough(p)) }
                case .flow(let id):
                    if let b = model.brokers.first(where: { $0.id == id }) { BrokerInfoView(broker: b) }
                case .automatic:
                    AutoActivityView(handles: task.domains)
                case .site(let id):
                    if let e = model.directory.first(where: { $0.id == id }) { DirectoryInfoView(entry: e, alsoHandles: task.domains.filter { $0 != e.domain }) }
                }
            }
            .navigationDestination(for: Int.self) { BandDetailView(rank: $0) }
    }
}

extension View { func planDestinations() -> some View { modifier(PlanDestinations()) } }
