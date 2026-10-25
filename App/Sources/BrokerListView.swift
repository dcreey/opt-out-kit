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
    @State private var chooser: ChooserMode?

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
                if model.autoBusy == "optout" {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Opting you out in the background", systemImage: "bolt.fill").font(.headline)
                            if let p = model.autoProgress {
                                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                                Text("\(p.done) of \(p.total) sites. We will only ask you about the ones that need you.").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("home-auto-working")
                    }
                }
                if model.autoSettings.lastAttempted != nil { Section { LastRunRow() } }
                let goals = model.dailyGoals
                if !goals.verify.isEmpty {
                    Section {
                        NavigationLink(value: "daily-verify") {
                            GoalRow(title: goalTitle(goals), subtitle: Loc.t("Each is filled in; you tick the human check"),
                                    done: goals.verifyDone, total: goals.verify.count, symbol: "hand.tap")
                        }.accessibilityIdentifier("goal-verify")
                        if let mail = goals.email {
                            NavigationLink(value: "daily-email") {
                                GoalRow(title: Loc.t("Email the same sites"), subtitle: Loc.t("One message, every address in Bcc, as a safety net"),
                                        done: goals.emailDone, total: mail.domains.count, symbol: "envelope")
                            }.accessibilityIdentifier("goal-email")
                        }
                        if goals.verifyDone == 0 {
                            Button { chooser = .start } label: { Label("Choose today's kind of broker", systemImage: "square.grid.2x2") }
                                .accessibilityIdentifier("goal-choose")
                        }
                        if goals.allComplete {
                            Button { chooser = .more } label: { Label("Keep going: take 25 more", systemImage: "forward.fill") }
                                .accessibilityIdentifier("goal-more")
                        }
                    } header: { Text("Today's goals") } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("About \(DailyGoals.daysLeft(remaining: model.verifyRemaining)) days left at 25 a day. Finish both goals each day and every site is covered in about a month. You can always keep going.")
                            Text(FollowUpNote.text)
                        }
                    }
                }
                let queue = model.queue
                let tasks = queue.flatMap(\.tasks)
                let done = tasks.filter { model.isDone($0) }.count
                Section {
                    ProgressView(value: tasks.isEmpty ? 0 : Double(done) / Double(tasks.count)) {
                        Text("Finished \(tasks.isEmpty ? 0 : done * 100 / tasks.count)%")
                    }
                    .accessibilityIdentifier("completion")
                } footer: {
                    Text("\(queue.reduce(0) { $0 + $1.siteCount }) sites in \(tasks.count) tasks, ranked: work from the top and each task is the best use of your time that is left.")
                }
                let next = tasks.filter { !model.isDone($0) }.prefix(5)
                Section {
                    ForEach(Array(next)) { task in
                        NavigationLink(value: task) { PlanTaskRow(task: task) }.accessibilityIdentifier("next-\(task.id)")
                    }
                } header: { Text("Do these next") }
                Section {
                    ForEach(queue) { band in
                        NavigationLink(value: band.rank.rawValue) { QueueBandHeader(band: band) }
                            .accessibilityIdentifier("band-\(band.rank.rawValue)")
                    }
                } header: { Text("The whole queue, in order") }
            }
            .accessibilityIdentifier("broker-list")
            .navigationTitle("Opt-Out Kit")
            .sheet(item: $chooser) { mode in
                KindChooserView(mode: mode) { id in
                    switch mode { case .start: model.chooseFirstKind(id); case .more: model.addBatch(kind: id) }
                }
            }
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
            .navigationDestination(for: String.self) { key in
                switch key {
                case "auto-activity": AutoActivityView()
                case "daily-verify": VerifyQueueView(domains: model.dailyGoals.verify)
                case "daily-email": EmailQueueView(domains: model.dailyGoals.email?.domains ?? [])
                default: EmptyView()
                }
            }
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


extension BrokerListView {
    /// "Today: Advertising technology" when the day's batch is one kind of broker (it always is), else the plain title.
    func goalTitle(_ goals: DailyGoals) -> String {
        let names = goals.themes.compactMap { BrokerCategory(rawValue: $0)?.title }
        var seen = Set<String>(); let unique = names.filter { seen.insert($0).inserted }
        return unique.isEmpty ? Loc.t("Verify today's sites") : Loc.f("Today: %@", unique.joined(separator: ", "))
    }
}


/// Why a day's batch is being chosen: the first of the day, or another 25 after finishing.
enum ChooserMode: String, Identifiable { case start, more; var id: String { rawValue } }

/// The words every opt-out flow repeats: finishing an opt-out sometimes takes a follow-up email.
enum FollowUpNote {
    static let text = Loc.t("Some sites will email you afterwards with a link, a code or one more step to finish the opt-out. Watch your inbox, including spam. We will do our best to complete every opt-out inside the app.")
}

/// Pick which kind of broker to work on: each is described in plain words with how many sites are left.
struct KindChooserView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let mode: ChooserMode
    let onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(mode == .start ? Loc.t("Each day you work through up to 25 brokers of one kind. Pick the kind you want to tackle today.")
                                        : Loc.t("Nice work. Pick the kind of broker for your next 25."))
                        .font(.subheadline)
                    Label(FollowUpNote.text, systemImage: "envelope.badge").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(Array(model.remainingKinds.enumerated()), id: \.element.kind) { index, item in
                        let category = BrokerCategory(rawValue: item.kind) ?? .other
                        Button { onPick(item.kind); dismiss() } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("\(category.rank)").font(.subheadline.bold()).foregroundStyle(.white)
                                        .frame(width: 26, height: 26).background(rankColor(category.rank), in: Circle())
                                    Text(category.title).font(.headline)
                                    Spacer()
                                    if index == 0 { Text("Start here").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Color.accentColor, in: Capsule()).foregroundStyle(.white) }
                                    Text(Loc.f("%lld left", item.count)).font(.caption.bold()).foregroundStyle(.tint)
                                }
                                HarmMeter(harm: category.harm)
                                Text(category.rankReason).font(.footnote).foregroundStyle(.secondary)
                                DisclosureGroup("What they do and what could happen") {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(category.about).font(.footnote)
                                        Label(category.whatItMeans, systemImage: "person.fill.questionmark").font(.footnote).foregroundStyle(.secondary)
                                        CaseExamples(category: category)
                                    }.padding(.top, 4)
                                }.font(.footnote.bold())
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("kind-\(item.kind)")
                    }
                } header: { Text("In the order we suggest") } footer: { Text("Ranked by how bad the worst case can get and how much opting out helps. Start at the top, or pick any.") }
            }
            .navigationTitle(mode == .start ? Loc.t("Today's kind of broker") : Loc.t("Next 25"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}


/// A realistic best and worst outcome of a kind of company holding your data, so the choice is informed.
struct CaseExamples: View {
    let category: BrokerCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(category.bestCase, systemImage: "hand.thumbsup.fill").foregroundStyle(.green)
            Label(category.worstCase, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
    }
}


/// The four ways a kind of broker can hurt, each from none to severe, so the worst cases compare at a glance.
struct HarmMeter: View {
    let harm: Harm

    var body: some View {
        HStack(spacing: 14) {
            cell(Loc.t("Safety"), harm.safety, .red)
            cell(Loc.t("Money"), harm.money, .orange)
            cell(Loc.t("Reputation"), harm.reputation, .purple)
            cell(Loc.t("Annoyance"), harm.annoyance, .gray)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Loc.f("Harm: safety %lld of 3, money %lld of 3, reputation %lld of 3, annoyance %lld of 3", harm.safety, harm.money, harm.reputation, harm.annoyance))
    }

    private func cell(_ title: String, _ level: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { Circle().fill($0 < level ? color : color.opacity(0.18)).frame(width: 9, height: 9) }
            }
        }
    }
}

/// Darker for the kinds that matter most.
func rankColor(_ rank: Int) -> Color { rank <= 4 ? .red : rank <= 9 ? .orange : rank <= 14 ? .blue : .gray }
