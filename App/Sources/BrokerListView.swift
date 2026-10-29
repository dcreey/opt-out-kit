import SwiftUI
import OptOutKitCore

struct BrokerListView: View {
    @EnvironmentObject var model: AppModel
    @State private var addingPerson = false
    @State private var newName = ""
    @State private var editing: Person?

    /// The editor can close only when the profile has its required details (and, for the owner, the household email).
    /// The profile as typed in the open editor; the model itself is written when a field is left or Done is tapped.
    @State private var editDraft: Person?
    private func editorComplete(_ person: Person) -> Bool {
        guard let current = editDraft ?? model.people.first(where: { $0.id == person.id }) else { return true }
        return current.isComplete && (current.relationship != .me || model.formEmail != nil)
    }
    @State private var showAuto = false
    @State private var chooser: ChooserMode?
    @State private var summary: ActivitySummary?
    @State private var explainFollowUp = false
    @State private var briefing: BrokerCategory?

    var body: some View {
        NavigationStack {
            List {
                if let error = model.loadError { Text(error).foregroundStyle(.red) }
                if !model.autoSettings.hasDecided {
                    Section {
                        Button { showAuto = true } label: {
                            Label("Turn on automatic protection", systemImage: "bolt.shield")
                        }.accessibilityIdentifier("auto-banner")
                    } footer: { Text("Opt-out requests, sent for you every month in the background.") }
                }
                if let problem = model.storageProblem {
                    Section {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                        Button("Erase saved data and start over", role: .destructive) { model.eraseAndStartOver() }
                    }
                }
                if model.autoBusy == "optout" {
                    Section {
                        // Tapping it opens the status of the run: what is done and what needs you.
                        NavigationLink { AutoActivityView() } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Opting you out in the background", systemImage: "bolt.fill").font(.headline)
                                if let p = model.autoProgress {
                                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                                    Text("\(p.done) of \(p.total) sites. We will only ask you about the ones that need you.").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("home-auto-working")
                    }
                } else if model.autoOptOutStarted, let last = model.autoSettings.lastOptOut {
                    Section {
                        NavigationLink { AutoActivityView() } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Automatic opt-out", systemImage: "bolt.fill").font(.headline)
                                Text(Loc.f("Last run %@: %lld sent, %lld need you.", Loc.date(last, time: false), model.autoSettings.lastSent ?? 0, model.autoSettings.lastNeedYou ?? 0))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("home-auto-status")
                    }
                }
                if let place = model.ownerJurisdiction, (model.ownerCountry ?? "US") != "US" {
                    // Outside the US the app has no local opt-outs yet; the person is told, and shown what their country runs that we will add.
                    Section {
                        Label(Loc.f("Opt-outs for %@ are coming later. We are unlocking them country by country.", place.displayName), systemImage: "globe.europe.africa")
                        if !(place.futureWork ?? []).isEmpty { NavigationLink { FutureWorkView(place: place) } label: { Text("What we plan to add for you") } }
                    }
                } else if (model.ownerCountry ?? "US") != "US" {
                    Section { Label("Opt-outs for your country are coming later. We are unlocking them country by country.", systemImage: "globe.europe.africa") }
                } else if let place = model.ownerJurisdiction, !(place.futureWork ?? []).isEmpty {
                    Section { NavigationLink { FutureWorkView(place: place) } label: { Label("Coming later for your state", systemImage: "clock.badge") } }
                }
                if !model.regionSplit.elsewhere.isEmpty {
                    Section {
                        if model.offerOtherRegions {
                            Label(Loc.f("You finished the sites that reach your country. %lld more collect data in other regions.", model.regionSplit.elsewhere.count), systemImage: "checkmark.circle")
                            Button("Do those too") { model.setIncludeOtherRegions(true) }
                        } else {
                            Toggle(isOn: Binding(get: { model.includesOtherRegions() }, set: { model.setIncludeOtherRegions($0) })) {
                                Text(Loc.f("Also show sites from other regions (%lld)", model.regionSplit.elsewhere.count))
                            }
                        }
                    } footer: { Text("These sites collect data about people elsewhere. We start with the ones that reach where you live.") }
                }
                if !model.gpcSetupDone {
                    Section {
                        NavigationLink { GPCSetupView() } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Turn on Global Privacy Control", systemImage: "hand.raised.square").font(.headline)
                                Text("One setting in your browser, about 5 minutes. It tells every site you visit not to sell or share your data.").font(.footnote).foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("gpc-setup-task")
                    } header: { Text("One-time setting") }
                }
                let goals = model.dailyGoals
                if model.needsKindChoice {
                    // Every day opens on one question: which kind of broker to tackle.
                    Section {
                        ForEach(Array(model.remainingKinds.enumerated()), id: \.element.kind) { index, item in
                            Button { model.chooseFirstKind(item.kind); briefing = BrokerCategory(rawValue: item.kind) } label: { KindOption(kind: item.kind, count: item.count, suggested: index == 0) }
                                .buttonStyle(.plain).accessibilityIdentifier("kind-\(item.kind)")
                        }
                    } header: { Text("What do you want to tackle today?").font(.title3.bold()).textCase(nil).foregroundStyle(.primary) }
                      footer: { Text("Ranked by how bad the worst case can get and how much opting out helps. Start at the top, or pick any.") }
                } else if !goals.verify.isEmpty {
                    TodayCard(goals: goals, change: { chooser = .start }, more: { chooser = .more })
                }
                if model.skippedDueCount > 0 {
                    // Sites skipped a week ago or more: a reminder to try them again.
                    Section {
                        NavigationLink(value: "skipped-sites") {
                            Label(model.skippedDueCount == 1 ? "1 skipped site is ready to try again" : "\(model.skippedDueCount) skipped sites are ready to try again", systemImage: "arrow.uturn.forward.circle")
                        }.accessibilityIdentifier("skipped-reminder")
                    }
                }
                if !model.needsKindChoice, model.activitySummary.sites > 0 { ProgressRow(summary: model.activitySummary) }
                let firstTasks = model.queue.flatMap(\.tasks).filter { t in
                    if case .platform = t.kind { return !model.isDone(t) }
                    return t.kind == .automatic && !model.isDone(t) && !model.autoOptOutStarted
                }
                if !firstTasks.isEmpty {
                    Section {
                        ForEach(firstTasks) { task in NavigationLink(value: task) { PlanTaskRow(task: task) }.accessibilityIdentifier("next-\(task.id)") }
                    } header: { Text("One-time, do these first") }
                }
            }
            .accessibilityIdentifier("broker-list")
            .navigationTitle("Exnay: Opt Out Kit")
            .sheet(isPresented: Binding(get: { summary != nil }, set: { if !$0 { summary = nil } })) {
                if let sum = summary { DailySummaryView(summary: sum) }
            }
            .onAppear {
                if model.shouldShowDailySummary { summary = model.activitySummary; model.markDailySummaryShown() }
                else if model.shouldExplainFollowUp { explainFollowUp = true; model.markFollowUpExplained() }
            }
            .sheet(isPresented: $explainFollowUp) { FollowUpExplainerView() }
            .sheet(item: $briefing) { KindBriefingView(category: $0) }
            .sheet(item: $chooser) { mode in
                KindChooserView(mode: mode) { id in
                    switch mode { case .start: model.chooseFirstKind(id); case .more: model.addBatch(kind: id) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { briefing = BrokerCategory(rawValue: id) }
                }
            }
            .sheet(item: $editing) { person in
                NavigationStack {
                    PersonEditorView(person: person, onDraft: { editDraft = $0 })
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                // A profile needs its legal name and current address before the editor can be closed.
                                Button("Done") { if let d = editDraft { model.update(d) }; editing = nil }
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
                    if Features.otherProfiles { Menu {
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
                    .accessibilityIdentifier("account-switcher") }
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
                case "skipped-sites": SkippedSitesView()
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
                }
                Section {
                    ForEach(Array(model.remainingKinds.enumerated()), id: \.element.kind) { index, item in
                        Button { onPick(item.kind); dismiss() } label: { KindOption(kind: item.kind, count: item.count, suggested: index == 0) }
                            .buttonStyle(.plain).accessibilityIdentifier("kind-\(item.kind)")
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


/// Shown the first time the app opens each day: what the person has done so far, led by their most recent work and what it did for them.
struct DailySummaryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let summary: ActivitySummary
    
    private func title(_ kind: String) -> String { (BrokerCategory(rawValue: kind) ?? .other).title }

    private var when: String {
        guard let day = summary.lastDay else { return "" }
        let f = RelativeDateTimeFormatter(); f.dateTimeStyle = .named; f.unitsStyle = .full
        let text = f.localizedString(for: day, relativeTo: Calendar.current.startOfDay(for: Date()))
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(summary.sites == 1 ? Loc.t("You have asked 1 site to remove you") : Loc.f("You have asked %lld sites to remove you", summary.sites)).font(.title3.bold())
                        if summary.emails > 0 { Text(Loc.f("and emailed %lld more as a second route", summary.emails)).font(.subheadline).foregroundStyle(.secondary) }
                        if summary.activeDays > 1 { Text(Loc.f("across %lld days. Every request counts.", summary.activeDays)).font(.footnote).foregroundStyle(.secondary) }
                    }
                    .accessibilityIdentifier("summary-headline")
                }
                if summary.lastDay != nil, summary.lastDaySites > 0 {
                    Section {
                        ForEach(summary.lastDayKinds.prefix(3), id: \.kind) { item in
                            let category = BrokerCategory(rawValue: item.kind) ?? .other
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.count == 1 ? Loc.f("%@: 1 site", category.title) : Loc.f("%@: %lld sites", category.title, item.count)).font(.headline)
                                Label(category.protects, systemImage: "checkmark.shield.fill").font(.footnote).foregroundStyle(.green)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    } header: { Text(summary.lastDaySites == 1 ? Loc.f("%@ you sent 1 request", when) : Loc.f("%@ you sent %lld requests", when, summary.lastDaySites)).textCase(nil).font(.subheadline.bold()) }
                }
                if summary.dueToRenew > 0 {
                    Section {
                        Label(summary.dueToRenew == 1 ? Loc.t("1 earlier opt-out is due to be repeated. It is back in your daily batches.") : Loc.f("%lld earlier opt-outs are due to be repeated. They are back in your daily batches.", summary.dueToRenew), systemImage: "arrow.clockwise")
                            .font(.subheadline).foregroundStyle(.orange)
                    } footer: { Text("Brokers collect data again over time, so a request does not always last. Some companies say theirs does; we show which.") }
                }
                if summary.byKind.count > 1 {
                    Section {
                        ForEach(summary.byKind.prefix(6), id: \.kind) { item in
                            HStack { Text(title(item.kind)); Spacer(); Text("\(item.count)").foregroundStyle(.secondary) }
                        }
                    } header: { Text("So far, by kind of broker") }
                }
            }
            .navigationTitle("Welcome back")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Continue") { dismiss() }.accessibilityIdentifier("summary-continue") } }
        }
        .accessibilityIdentifier("daily-summary")
    }
}


/// One kind of broker as an option: its rank, how bad the worst case is, why it sits here, and what could happen.
struct KindOption: View {
    let kind: String
    let count: Int
    let suggested: Bool

    var body: some View {
        let category = BrokerCategory(rawValue: kind) ?? .other
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(category.rank)").font(.subheadline.bold()).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(rankColor(category.rank), in: Circle())
                Text(category.title).font(.headline)
                Spacer()
                if suggested { Text("Start here").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Color.accentColor, in: Capsule()).foregroundStyle(.white) }
                Text(Loc.f("%lld left", count)).font(.caption.bold()).foregroundStyle(.tint)
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
        .contentShape(Rectangle())
    }
}

/// Today's one goal: a ring for today's progress, the two steps (fill in, then email the same sites) and a single button for what is next.
struct TodayCard: View {
    let goals: DailyGoals
    let change: () -> Void
    let more: () -> Void

    private var verifyTotal: Int { max(goals.verify.count, 1) }
    private var emailTotal: Int { goals.email?.domains.count ?? 0 }
    /// Today's progress across both steps, from 0 to 1.
    private var fraction: Double {
        let total = Double(verifyTotal + emailTotal)
        return min(1, Double(goals.verifyDone + min(goals.emailDone, emailTotal)) / total)
    }
    private var theme: String { goals.themes.compactMap { BrokerCategory(rawValue: $0)?.title }.first ?? "" }

    var body: some View {
        Section {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 9)
                    Circle().trim(from: 0, to: fraction).stroke(goals.allComplete ? Color.green : Color.accentColor, style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(-90))
                    if goals.allComplete { Image(systemName: "checkmark").font(.title2.bold()).foregroundStyle(.green) }
                    else { Text("\(goals.verifyDone)").font(.title2.bold()) + Text(" / \(goals.verify.count)").font(.footnote).foregroundColor(.secondary) }
                }
                .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Loc.f("Today: %@", theme)).font(.headline)
                    stepRow(Loc.t("Fill in the sites"), done: goals.verifyComplete, detail: "\(goals.verifyDone) / \(goals.verify.count)")
                    if emailTotal > 0 { stepRow(Loc.t("Send one email to the same sites"), done: goals.emailComplete, detail: "\(min(goals.emailDone, emailTotal)) / \(emailTotal)") }
                }
            }
            .padding(.vertical, 4)
            .accessibilityIdentifier("today-card")
            if !goals.verifyComplete {
                NavigationLink(value: "daily-verify") { Label(goals.verifyDone == 0 ? Loc.t("Start") : Loc.t("Continue"), systemImage: "play.fill").font(.headline) }
                    .accessibilityIdentifier("today-continue")
            } else if !goals.emailComplete {
                NavigationLink(value: "daily-email") { Label(Loc.t("Send the email"), systemImage: "envelope.fill").font(.headline) }
                    .accessibilityIdentifier("today-email")
            } else {
                Button(action: more) { Label("Keep going: take 25 more", systemImage: "forward.fill").font(.headline) }.accessibilityIdentifier("goal-more")
            }
            if goals.verifyDone == 0 {
                Button(action: change) { Label("Change today's kind of broker", systemImage: "arrow.triangle.2.circlepath").font(.footnote) }
                    .accessibilityIdentifier("goal-choose")
            }
        }
    }

    private func stepRow(_ title: String, done: Bool, detail: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? .green : .secondary).font(.footnote)
            Text(title).font(.footnote)
            Spacer(minLength: 4)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Encouragement that only goes up: a streak of days and the number of requests sent so far, never a share of the whole directory.
struct ProgressRow: View {
    let summary: ActivitySummary

    var body: some View {
        Section {
            HStack {
                if summary.streak > 0 {
                    Label(Loc.f("%lld-day streak", summary.streak), systemImage: "flame.fill").foregroundStyle(.orange)
                    Spacer()
                }
                Label(summary.sites == 1 ? Loc.t("1 request sent so far") : Loc.f("%lld requests sent so far", summary.sites), systemImage: "checkmark.shield.fill").foregroundStyle(.green)
            }
            .font(.subheadline.bold())
            .accessibilityIdentifier("progress-row")
        }
    }
}

/// Shown once, the first time someone has finished tasks: why the day ends with an email, and what to expect in their inbox.
struct FollowUpExplainerView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "envelope.badge").font(.system(size: 48)).foregroundStyle(.tint).padding(.top, 28)
            Text("Why we ask you to send an email").font(.title2.bold()).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 12) {
                Label("Some sites ignore forms but honor an email, so the email is a second route to the same result.", systemImage: "arrow.triangle.branch")
                Label("Some sites will email you afterwards with a link, a code or one more step to finish. Watch your inbox, including spam.", systemImage: "tray.full")
                Label("We will do our best to complete every opt-out inside the app, and we will show you what is left.", systemImage: "checkmark.circle")
            }
            .font(.callout).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 24)
            Spacer()
            Button("Got it") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("followup-done").padding(.bottom, 24)
        }
        .presentationDetents([.medium, .large])
    }
}


extension BrokerCategory: Identifiable { public var id: String { rawValue } }

/// Shown each time a day's kind of broker is chosen: who they are, why they matter today, and the best and worst a person can expect.
struct KindBriefingView: View {
    @Environment(\.dismiss) private var dismiss
    let category: BrokerCategory

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Text("\(category.rank)").font(.headline).foregroundStyle(.white).frame(width: 32, height: 32).background(rankColor(category.rank), in: Circle())
                        Text(category.title).font(.title3.bold())
                    }
                    HarmMeter(harm: category.harm)
                } footer: { Text(category.about) }
                Section("Why this matters") {
                    Text(category.rankReason).font(.subheadline)
                }
                Section("Best and worst case") { CaseExamples(category: category) }
                Section("What opting out does for you") {
                    Label(category.protects, systemImage: "checkmark.shield.fill").font(.subheadline).foregroundStyle(.green)
                }
                // The last thing on the page: reading to the bottom is how the briefing is confirmed.
                Section {
                    Button { dismiss() } label: { Text("Let's go").font(.headline).frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large).listRowBackground(Color.clear)
                        .accessibilityIdentifier("briefing-go")
                }
            }
            .navigationTitle("Today's briefing")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled()
    }
}


/// The lists and mechanisms a place's law or government runs that the app does not use yet.
struct FutureWorkView: View {
    let place: Jurisdiction

    private func title(_ kind: String) -> String {
        switch kind {
        case "broker_registry": return Loc.t("A list of data brokers")
        case "central_register": return Loc.t("A national opt-out register")
        case "one_stop_deletion": return Loc.t("One request to every broker")
        case "opt_out_signal": return Loc.t("An automatic opt-out signal")
        default: return kind
        }
    }

    var body: some View {
        List {
            Section { Text("These are lists your place runs or requires. We are not using them yet, and we will tell you when we do. Your other opt-outs work as usual.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(place.futureWork ?? []) { item in
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title(item.kind)).font(.caption).foregroundStyle(.secondary)
                        Text(item.name).font(.headline)
                        Text(item.note).font(.footnote)
                        if let u = item.url.flatMap({ URL(string: $0) }) { Link(u.host ?? "", destination: u).font(.footnote) }
                    }
                }
            }
        }
        .navigationTitle(place.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
