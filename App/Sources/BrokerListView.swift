import SwiftUI
import OptOutKitCore

struct BrokerListView: View {
    @EnvironmentObject var model: AppModel
    @State private var addingPerson = false
    @State private var newName = ""
    @State private var editing: Person?

    /// The editor can close only when the profile has its required details (and, for the owner, the household email).
    private func editorComplete(_ person: Person) -> Bool {
        guard let current = model.people.first(where: { $0.id == person.id }) else { return true }
        return current.isComplete && (current.relationship != .me || model.formEmail != nil)
    }
    @State private var showAuto = false

    var body: some View {
        NavigationStack {
            List {
                if let error = model.loadError { Text(error).foregroundStyle(.red) }
                if !model.autoSettings.hasDecided {
                    Section {
                        Button { showAuto = true } label: {
                            Label("Turn on automatic protection", systemImage: "bolt.shield")
                        }.accessibilityIdentifier("auto-banner")
                    } footer: { Text("A daily scan and weekly opt-out requests, run for you in the background.") }
                }
                if let problem = model.storageProblem {
                    Section {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                        Button("Erase saved data and start over", role: .destructive) { model.eraseAndStartOver() }
                    }
                }
                let steps = model.plan
                let tasks = steps.flatMap(\.tasks)
                let done = tasks.filter { model.isDone($0) }.count
                Section {
                    ProgressView(value: tasks.isEmpty ? 0 : Double(done) / Double(tasks.count)) {
                        Text("Finished \(tasks.isEmpty ? 0 : done * 100 / tasks.count)%")
                    }
                    .accessibilityIdentifier("completion")
                } footer: {
                    Text("\(steps.reduce(0) { $0 + $1.siteCount }) sites, handled in \(steps.count) steps and \(tasks.count) tasks. Work from the top: each step is the quickest way to cover the most sites.")
                }
                Section {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        NavigationLink(value: step.id) { PlanStepHeader(number: index + 1, step: step) }
                            .accessibilityIdentifier(step.id)
                    }
                } header: {
                    Text("Your plan")
                }
            }
            .accessibilityIdentifier("broker-list")
            .navigationTitle("Opt-Out Kit")
            .sheet(item: $editing) { person in
                NavigationStack {
                    PersonEditorView(person: person)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                // A profile needs its legal name and current address before the editor can be closed.
                                Button("Done") { editing = nil }
                                    .disabled(!(editorComplete(person)))
                                    .accessibilityIdentifier("editor-done")
                            }
                        }
                        .interactiveDismissDisabled(!(editorComplete(person)))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { editing = model.selectedPerson } label: {
                        Label("Profile", systemImage: "person.crop.circle")
                    }
                    .accessibilityIdentifier("profile-button")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(model.people) { person in
                            Button { model.select(person.id) } label: {
                                Label(person.displayName,
                                      systemImage: person.id == model.selectedPerson?.id ? "checkmark" : "person")
                            }
                        }
                        Divider()
                        Button("Add person…", systemImage: "person.badge.plus") { addingPerson = true }
                    } label: {
                        Label(model.selectedPerson?.displayName ?? "Me", systemImage: "person.2")
                    }
                    .accessibilityIdentifier("account-switcher")
                }
            }
            .alert(Loc.t("Add a person"), isPresented: $addingPerson) {
                TextField("Name", text: $newName)
                Button("Add") { editing = model.addPerson(named: newName); newName = "" }
                Button("Cancel", role: .cancel) { newName = "" }
            } message: {
                Text("Family members only: someone who asked you to, or a child you are the parent or guardian of. Their details stay on this phone. Mark children as under 18 so the app never searches for them.")
            }
            .sheet(isPresented: $showAuto) { AutoProtectionView() }
            .navigationDestination(for: Broker.self) { BrokerDetailView(broker: $0) }
            .planDestinations()
        }
    }

    private func platformRow(_ broker: Broker) -> some View {
        let platform = model.platform(forWalkthrough: broker.id)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(platform?.shortName ?? broker.name).font(.headline)
                Text("Reaches \(platform?.registered ?? 0) registered brokers, \(broker.covers?.count ?? 0) of the sites in this app")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.progress.isDone(broker.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        }
    }

    private func row(_ broker: Broker) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(broker.name).font(.headline)
                Text(broker.isVerified ? "Guided" : Loc.t("Guided · unverified"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.progress.isDone(broker.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        }
    }
}

extension Broker: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
