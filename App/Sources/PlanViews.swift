import SwiftUI
import OptOutKitCore

extension PlanTask: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// What a step is worth, in one sentence: how many sites finishing it handles, and how many separate things that takes.
func stepSummary(_ step: PlanStep) -> String {
    step.siteCount == step.tasks.count
        ? Loc.f("%lld sites, one at a time", step.siteCount)
        : Loc.f("%lld sites in %lld tasks", step.siteCount, step.tasks.count)
}

struct PlanStepHeader: View {
    @EnvironmentObject var model: AppModel
    let number: Int
    let step: PlanStep

    var body: some View {
        let done = step.tasks.filter { model.isDone($0) }.count
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.headline).frame(width: 28, height: 28)
                .background(done == step.tasks.count ? Color.green : Color.accentColor, in: Circle()).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).font(.headline)
                Text(stepSummary(step)).font(.subheadline).foregroundStyle(.secondary)
                Text(step.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if done > 0 { Text(Loc.f("%lld of %lld done", done, step.tasks.count)).font(.caption).foregroundStyle(.green) }
            }
        }
    }
}

struct PlanTaskRow: View {
    @EnvironmentObject var model: AppModel
    let task: PlanTask

    var body: some View {
        let places = model.placeCodes(for: model.placeScope)
        HStack(alignment: .top) {
            Image(systemName: model.isDone(task) ? "checkmark.circle.fill" : "circle").foregroundStyle(model.isDone(task) ? .green : .secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.headline)
                if task.kind == .automatic { Text(Loc.f("%lld sites in one run", task.siteCount)).font(.caption.bold()).foregroundStyle(.blue) }
                else if task.isShared { Text(Loc.f("One request handles %lld sites", task.siteCount)).font(.caption.bold()).foregroundStyle(.blue) }
                Text(task.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if !places.isEmpty, task.isRegistered(in: places) {
                    Label(Loc.f("Registered in %@", task.registeredIn.intersection(places).sorted().joined(separator: ", ")), systemImage: "mappin.circle.fill")
                        .font(.caption).foregroundStyle(.teal)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The page for one step: its tasks, in order.
struct StepDetailView: View {
    @EnvironmentObject var model: AppModel
    let stepID: String

    var body: some View {
        let steps = model.plan
        if let index = steps.firstIndex(where: { $0.id == stepID }) {
            let step = steps[index]
            List {
                Section { PlanStepHeader(number: index + 1, step: step) }
                Section {
                    ForEach(PlaceSort.ordered(step.tasks, places: model.placeCodes(for: model.placeScope))) { task in
                        NavigationLink(value: task) { PlanTaskRow(task: task) }.accessibilityIdentifier("task-\(task.id)")
                    }
                }
            }
            .navigationTitle(step.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

enum PlaceSort {
    /// Tasks registered in the chosen places first, then the rest in their usual order. Nothing is removed.
    static func ordered(_ tasks: [PlanTask], places: Set<String>) -> [PlanTask] {
        guard !places.isEmpty else { return tasks }
        return tasks.filter { $0.isRegistered(in: places) } + tasks.filter { !$0.isRegistered(in: places) }
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
            .navigationDestination(for: String.self) { StepDetailView(stepID: $0) }
    }
}

extension View { func planDestinations() -> some View { modifier(PlanDestinations()) } }

/// Which places' brokers come first. All is the default; the others only reorder and mark.
struct PlaceScopePicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Picker("Show first", selection: Binding(get: { model.placeScope }, set: { model.placeScope = $0 })) {
            Text("Everywhere").tag(AppModel.PlaceScope.all)
            Text("Where I live").tag(AppModel.PlaceScope.mine)
            Text("Places I've lived").tag(AppModel.PlaceScope.visited)
        }
        .pickerStyle(.segmented).accessibilityIdentifier("place-scope")
        Text("Every site stays on the list. This only moves brokers registered where you live, or have lived, to the top and marks them, because a broker anywhere may still list you.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
