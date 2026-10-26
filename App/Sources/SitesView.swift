import SwiftUI
import OptOutKitCore

extension StatusSummary {
    var symbol: String {
        switch self {
        case .notStarted: return "circle"
        case .inProgress: return "circle.dotted"
        case .partial: return "circle.lefthalf.filled"
        case .submitted: return "clock.badge.checkmark"
        case .complete: return "checkmark.circle.fill"
        case .relisted: return "exclamationmark.arrow.circlepath"
        }
    }
    var color: Color {
        switch self {
        case .notStarted: return .secondary
        case .inProgress: return .orange
        case .partial: return .yellow
        case .submitted: return .blue
        case .complete: return .green
        case .relisted: return .red
        }
    }
}

/// Every broker in the registry with its status across all profiles.
struct SitesView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var showScan = false
    @State private var showQuick = false
    @State private var fCategory: BrokerCategory?
    @State private var fData: DataKind?
    @State private var fBuyer: BuyerKind?
    private var filtering: Bool { fCategory != nil || fData != nil || fBuyer != nil }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search all sites by name or web address", text: $search)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("sites-search")
                        if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                    }
                } footer: {
                    Text("Tracking \(model.totalSites) sites. Each is listed once, in ranked order: your official service first, then what the app does for you, then semi-automated and manual tasks, nearest first. A request that handles several sites is one task that names them all.")
                        .accessibilityIdentifier("sites-total")
                }
                let queue = model.queue
                ForEach(queue) { band in
                    let tasks = band.tasks.filter { visible($0) }
                    if !tasks.isEmpty {
                        Section {
                            ForEach(tasks) { task in
                                NavigationLink(value: task) { PlanTaskRow(task: task) }.accessibilityIdentifier("task-\(task.id)")
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(band.rank.rawValue). \(band.rank.title)").font(.subheadline.bold()).textCase(nil)
                                    .accessibilityIdentifier("band-\(band.rank.rawValue)")
                                Text(tasks.count == band.tasks.count ? bandSummary(band) : Loc.f("Showing %lld of %lld tasks", tasks.count, band.tasks.count))
                                    .font(.caption).textCase(nil)
                            }
                        } footer: {
                            Text(band.rank.explanation)
                        }
                    }
                }
                if !search.isEmpty, !queue.contains(where: { $0.tasks.contains { visible($0) } }) {
                    Section { Text("No site matches that search.").foregroundStyle(.secondary) }
                }
                if !filtering, search.isEmpty || !model.lockedSites.filter({ closedVisible($0) }).isEmpty {
                    let locked = model.lockedSites.filter { closedVisible($0) }
                    if !locked.isEmpty {
                        Section {
                            NavigationLink { LockedSitesView(sites: locked) } label: {
                                Label(Loc.f("%lld sites unlock later", locked.count), systemImage: "lock")
                            }.accessibilityIdentifier("locked-sites")
                        } footer: {
                            Text("We have not found a way to opt out of these yet: no form, page or email. They become tasks the day we do.")
                        }
                    }
                }
                if !filtering, search.isEmpty || closedMatches {
                    let closed = model.closedSites.filter { closedVisible($0) }
                    if !closed.isEmpty {
                        Section {
                            NavigationLink { ClosedSitesView(sites: closed) } label: {
                                Label(Loc.f("%lld sites no longer respond", closed.count), systemImage: "wifi.slash")
                            }.accessibilityIdentifier("closed-sites")
                        } footer: {
                            Text("These sites do not answer any more, so there is nothing to opt out of. We keep the proof we collected.")
                        }
                    }
                }
                Section {
                    scoreCard
                    Button { model.requireProfile { showQuick = true } } label: {
                        Label("Quick checks (\(model.quickCheckQueue.count) sites)", systemImage: "bolt.fill")
                    }
                    .disabled(model.searchBlockedReason != nil)
                    .accessibilityIdentifier("quick-checks")
                } footer: {
                    Text("Look a site up yourself in 20 seconds and tell us what you see. Each look earns points.")
                }
                Section {
                    Button { model.requireProfile { showScan = true } } label: {
                        Label("Scan for \(model.selectedPerson?.displayName ?? "my") listings", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .disabled(model.searchBlockedReason != nil)
                    .accessibilityIdentifier("scan-exposure")
                    if let reason = model.searchBlockedReason {
                        Label(reason, systemImage: "hand.raised").font(.footnote).foregroundStyle(.orange)
                            .accessibilityIdentifier("search-blocked")
                    }
                } footer: {
                    Text("Searches \(ExposureScan.scannable(model.directory).count) sites that can be checked automatically. Nothing is submitted.")
                }
            }
            .accessibilityIdentifier("sites-list")
            .navigationTitle("Sites")
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
                    } label: {
                        Image(systemName: filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityIdentifier("sites-filter")
                }
            }
            .planDestinations()
            .coach(.sites)
            .sheet(isPresented: $showScan) { ExposureView() }
            .sheet(isPresented: $showQuick) { QuickCheckView() }
        }
    }

    private var scoreCard: some View {
        let score = model.score
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(score.level.name).font(.headline)
                Spacer()
                Text("\(score.points) pts").font(.headline).foregroundStyle(.tint)
                    .accessibilityIdentifier("score-points")
            }
            if let next = score.nextLevelAt {
                ProgressView(value: Double(score.points - score.level.from), total: Double(next - score.level.from))
                Text("\(next - score.points) points to the next level").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Top level").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Whether a task passes the search and the to-do filter. A shared task matches on any site it handles.
    private func visible(_ task: PlanTask) -> Bool {
        if filtering {
            // A shared task passes when any site it handles fits.
            let byDomain = model.entryByDomain
            guard task.domains.contains(where: { byDomain[$0]?.matches(category: fCategory, data: fData, buyer: fBuyer) ?? false }) else { return false }
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return task.title.lowercased().contains(q) || task.domains.contains { $0.lowercased().contains(q) }
    }

    private var closedMatches: Bool { model.closedSites.contains { closedVisible($0) } }

    private func closedVisible(_ e: DirectoryEntry) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || e.domain.lowercased().contains(q) || e.name.lowercased().contains(q)
    }

    private func directoryRow(_ e: DirectoryEntry) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.domain).font(.headline)
                Text(model.method(for: e).reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                let n = Directory.familySize(of: e, in: model.directory)
                if n > 1 { Text("Shares one opt-out with \(n - 1) other sites").font(.caption).foregroundStyle(.blue) }
                if let note = platformNote(for: e) { Text(note).font(.caption).foregroundStyle(.teal) }
                if model.activeIssue(for: e.id) != nil { Text("Reported not working").font(.caption).foregroundStyle(.red) }
            }
            Spacer()
        }
    }

    /// "Covered by California DROP until Jan 20" once the person has submitted it, else a hint that one request would cover this site.
    private func platformNote(for entry: DirectoryEntry) -> String? {
        guard let cover = model.platformCover(for: entry) else { return nil }
        let likely = cover.coverage.match == .name
        if let until = cover.until, until > Date() {
            return likely ? Loc.f("Probably covered by %@ until %@", cover.platform.shortName, Loc.date(until))
                          : Loc.f("Covered by %@ until %@", cover.platform.shortName, Loc.date(until))
        }
        guard cover.until == nil else { return nil }
        return likely ? Loc.f("Probably also covered by %@: one request reaches this site", cover.platform.shortName)
                      : Loc.f("Also covered by %@: one request reaches this site", cover.platform.shortName)
    }

    private func row(_ broker: Broker) -> some View {
        let summary = model.household.summary(for: broker)
        return HStack(alignment: .top) {
            Image(systemName: summary.symbol).foregroundStyle(summary.color).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(broker.name).font(.headline)
                Text(summary.label).font(.caption).foregroundStyle(summary.color)
                if let covers = broker.covers, !covers.isEmpty {
                    Text("Clears \(covers.count) sites").font(.caption).foregroundStyle(.secondary)
                }
                if let e = Directory.entry(for: broker, in: model.directory), let note = platformNote(for: e) {
                    Text(note).font(.caption).foregroundStyle(.teal)
                }
            }
            Spacer()
        }
    }
}

/// Details about one site: what it is, what it needs, and where each person stands.
struct BrokerInfoView: View {
    @EnvironmentObject var model: AppModel
    let broker: Broker
    @State private var openFlow = false
    @State private var scans: [UUID: ScanState] = [:]
    @State private var guide: GuidedRunner?
    @State private var siteLink: URL?
    @State private var healing = false

    enum ScanState: Equatable { case running, done(CheckOutcome) }

    var body: some View {
        let summary = model.household.summary(for: broker)
        List {
            Section {
                GuideButton(title: Loc.t("Guide me through it"), subtitle: OptOutMethods.classify(broker, in: model.directory).method == .semiAutomatic
                            ? Loc.t("We search for you; you tap your listing and clear the check") : "\(broker.steps.count) steps, in a full-screen browser") {
                    model.requireProfile { guide = model.guidedRunner(for: broker) }
                }
            }
            if let issue = model.activeIssue(for: broker.id) {
                Label("You reported this site as not working: \(issue.kind.label.lowercased()).", systemImage: "exclamationmark.bubble")
                    .font(.footnote).foregroundStyle(.red).accessibilityIdentifier("reported-issue")
            }
            Section {
                Label(summary.label, systemImage: summary.symbol).foregroundStyle(summary.color)
                    .accessibilityIdentifier("site-summary")
                if broker.isVerified {
                    Text("Verified \(broker.verified ?? "")").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Not yet checked by a real run. Steps may be out of date.")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }

            Section("Each person") {
                ForEach(model.household.statuses(for: broker), id: \.person.id) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.person.displayName)
                            Text(describe(item.status)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(buttonTitle(item.status)) { model.select(item.person.id); openFlow = true }
                            .buttonStyle(.bordered).accessibilityIdentifier("open-flow")
                    }
                    if broker.recheck != nil {
                        scanRow(item.person)
                    }
                }
            }

            Section("What to expect") {
                let verdict = OptOutMethods.classify(broker, in: model.directory)
                Text(verdict.method.title).font(.headline).accessibilityIdentifier("method-title")
                Text(verdict.reason).font(.footnote)
                Text(verdict.method.explanation).font(.footnote).foregroundStyle(.secondary)
                ForEach(broker.signals ?? [], id: \.self) { Label(Describe.signal($0), systemImage: "info.circle") }
            }

            if let covers = broker.covers, !covers.isEmpty {
                Section("One request clears \(covers.count) sites") {
                    ForEach(covers, id: \.self) { Text($0) }
                }
            }

            if let fields = broker.fields, !fields.isEmpty {
                Section {
                    ForEach(fields, id: \.self) { field in
                        let missing = model.household.people.filter { $0.value(for: field) == nil }
                        VStack(alignment: .leading) {
                            Text(Describe.field(field))
                            if !missing.isEmpty {
                                Text("Missing for \(missing.map(\.displayName).joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                } header: {
                    Text("What this site will receive")
                } footer: {
                    Text("Only these details are sent, and only when you submit its form.")
                }
            }

            Section("Steps (\(broker.steps.count))") {
                ForEach(Array(broker.steps.enumerated()), id: \.offset) { i, step in
                    Text("\(i + 1). \(step.title)")
                }
            }

            // The site's own link goes last: the guide above is the way in.
            if let url = model.effectiveURL(for: broker) {
                Section("Site link") {
                    Button("Open in Safari", systemImage: "safari") { siteLink = url }.accessibilityIdentifier("site-link")
                    Text(url.absoluteString).font(.caption).foregroundStyle(.secondary)
                    HealControls(siteID: broker.id, looking: $healing, find: { await model.healLink(for: broker) != nil })
                }
            }
        }
        .navigationTitle(broker.name)
        .coach(CoachGuide.forMethod(OptOutMethods.classify(broker, in: model.directory).method))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $openFlow) { BrokerDetailView(broker: broker) }
        .sheet(item: $siteLink) { SafariView(url: $0).ignoresSafeArea() }
        .fullScreenCover(item: Binding(get: { guide.map(GuideBox.init) }, set: { if $0 == nil { guide = nil } })) { box in
            GuidedFlowView(runner: box.runner)
        }
    }

    /// "Does this site have my data?" Read-only: searches the site and reports, nothing is saved or sent beyond the search.
    private func scanRow(_ person: Person) -> some View {
        HStack {
            Button("Check for \(person.displayName)'s listing", systemImage: "magnifyingglass") {
                scans[person.id] = .running
                Task { scans[person.id] = .done(await model.scan(broker, for: person)) }
            }
            .font(.footnote)
            .disabled(scans[person.id] == .running)
            .accessibilityIdentifier("scan-\(person.id.uuidString)")
            Spacer()
            switch scans[person.id] {
            case .none: EmptyView()
            case .running: ProgressView()
            case .done(let outcome):
                Text(scanText(outcome)).font(.footnote.bold()).foregroundStyle(scanColor(outcome))
                    .accessibilityIdentifier("scan-result")
            }
        }
    }

    private func scanText(_ o: CheckOutcome) -> String {
        switch o.result {
        case .stillListed: return Loc.t("Listing found")
        case .removed: return Loc.t("No listing found")
        case .paywalled: return Loc.t("Results are behind payment")
        case .inconclusive:
            switch o.reason {
            case .blocked: return Loc.t("Can't tell: site blocked the check")
            case .unrecognizedPage: return Loc.t("Can't tell: page looked different")
            case .network: return Loc.t("Can't tell: no connection")
            case .missingProfileData: return Loc.t("Add a full name and city first")
            default: return Loc.t("Can't tell")
            }
        }
    }

    private func scanColor(_ o: CheckOutcome) -> Color {
        switch o.result {
        case .stillListed: return .red
        case .removed: return .green
        case .paywalled, .inconclusive: return .orange
        }
    }

    private func describe(_ status: PersonStatus) -> String {
        switch status {
        case .notStarted: return Loc.t("Not started")
        case .inProgress(let d, let n): return Loc.f("In progress: %@ of %@ steps", d, n)
        case .done(let on, let due):
            return Loc.f("Submitted %@; checking from %@", Loc.date(on), Loc.date(due))
        case .verified(let since): return Loc.f("Verified removed %@", Loc.date(since))
        case .relisted(let on): return Loc.f("Listed again %@", Loc.date(on))
        }
    }

    private func buttonTitle(_ status: PersonStatus) -> String {
        switch status {
        case .notStarted: return "Start"
        case .inProgress: return "Continue"
        case .done, .verified: return "View"
        case .relisted: return "Redo"
        }
    }
}


/// A site we found automatically: what we know, what we are guessing, and a link to its own opt-out page.
extension DirectoryInfoView {
    /// A mail link addressed to the site, with a subject and a body that ask for what the person wants.
    static func mailto(_ to: String, person: Person?, email: String?, site: String) -> URL? {
        let name = person?.legalName ?? ""
        let body = "Hello,\n\nI am writing to opt out of the sale and sharing of my personal information and to ask you to delete the personal information you hold about me.\n\nName: \(name)\nEmail: \(email ?? "")\n\nPlease confirm when this is done.\n\nThank you."
        var c = URLComponents(); c.scheme = "mailto"; c.path = to
        c.queryItems = [URLQueryItem(name: "subject", value: "Opt-out and deletion request"), URLQueryItem(name: "body", value: body)]
        return c.url
    }
}

struct DirectoryInfoView: View {
    @EnvironmentObject var model: AppModel
    let entry: DirectoryEntry
    /// Other sites the same request handles, when this site is the lead of a shared process.
    var alsoHandles: [String] = []
    @State private var browserURL: URL?
    @State private var guide: GuidedRunner?
    @State private var healing = false
    private var resolvedEntry: DirectoryEntry { model.resolved(entry) }
    private var subtitle: String {
        switch model.method(for: entry).method {
        case .automatic: return Loc.t("We fill in the form and send it")
        case .semiAutomatic: return Loc.t("We fill in the form; you clear the check")
        case .guided: return Loc.t("We take you to the page and walk you through it")
        case .manual: return Loc.t("We open the site; you find its opt-out link")
        }
    }

    /// Whether an opt-out here lasts, from the company's own policy, and when we will ask the person to repeat it.
    @ViewBuilder private var persistenceSection: some View {
        let info = entry.persistence
        let months = entry.reupMonths ?? 12
        Section {
            switch info?.result {
            case "permanent": Label("The company says it keeps your opt-out, so you should not need to repeat it.", systemImage: "infinity").foregroundStyle(.green)
            case "temporary": Label(Loc.f("The company says the data can come back. We will ask you to repeat this every %lld months.", months), systemImage: "arrow.clockwise").foregroundStyle(.orange)
            default: Label(Loc.f("The company does not say whether it lasts. Most brokers collect data again, so we will ask you to repeat this after %lld months.", months), systemImage: "questionmark.circle").foregroundStyle(.secondary)
            }
            if let q = info?.quote { Text("\u{201C}\(q)\u{201D}").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let sent = entry.lastSent(in: model.progress.optOutAttempts) {
                if let due = entry.reupDate(after: sent) {
                    Text(Loc.f("Last sent %@. Due to repeat around %@.", sent.formatted(date: .abbreviated, time: .omitted), due.formatted(date: .abbreviated, time: .omitted))).font(.footnote)
                } else { Text(Loc.f("Last sent %@.", sent.formatted(date: .abbreviated, time: .omitted))).font(.footnote) }
            }
        } header: { Text("How long an opt-out lasts") }
    }

    /// Who the company is, what it tracks and who it sells to, as its own pages say.
    @ViewBuilder private func aboutSection(_ about: BrokerAbout) -> some View {
        Section {
            if let cat = entry.brokerCategory { Label(cat.title, systemImage: "building.2").font(.caption.bold()).foregroundStyle(.tint) }
            Text(about.summary).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            if let cat = entry.brokerCategory { Text(cat.whatItMeans).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true); CaseExamples(category: cat) }
            if let score = entry.priority {
                Label(Loc.f("%@ (%lld of 100)", BrokerPriority.tier(score), score), systemImage: "flag.fill")
                    .font(.caption.bold()).foregroundStyle(score >= 60 ? .red : score >= 45 ? .orange : .secondary)
            }
        } header: { Text("Who they are") }
        if !about.tracks.isEmpty {
            Section {
                ForEach(about.tracks, id: \.self) { Text(DataKind(rawValue: $0)?.title ?? $0) }
            } header: { Text("What they track") } footer: { Text("From the company's own privacy policy and pages.") }
        }
        Section {
            if about.sellsTo.isEmpty { Text("Its policy does not name who it sells to.").foregroundStyle(.secondary) }
            ForEach(about.sellsTo, id: \.self) { Text(BuyerKind(rawValue: $0)?.title ?? $0) }
            if let note = about.sellsNote { Text("\u{201C}\(note)\u{201D}").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let src = about.source, let url = URL(string: src) { Link(destination: url) { Label("Read their policy", systemImage: "doc.text") }.font(.caption) }
        } header: { Text("Who they sell to") }
    }

    var body: some View {
        List {
            if let caution = entry.caution {
                Section {
                    Label(caution.title, systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                    Text(caution.summary).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    if let note = caution.note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    ForEach(caution.sources, id: \.self) { src in
                        if let url = URL(string: src) { Link(destination: url) { Text(url.host ?? src).font(.caption) } }
                    }
                }
                .accessibilityIdentifier("caution")
            }
            if let about = entry.about { aboutSection(about) }
            persistenceSection
            let others = (entry.languages?.list ?? []).filter { $0 != "en" }
            let places = (entry.regions?.list ?? ["US"]).filter { $0 != "US" && $0 != "GLOBAL" }
            let worldwide = entry.regions?.list.contains("GLOBAL") == true
            if !others.isEmpty || !places.isEmpty || worldwide {
                Section("Where it operates") {
                    if worldwide { Label("Serves people worldwide", systemImage: "globe") }
                    if !places.isEmpty { Text(Loc.f("Collects data about people in: %@", places.joined(separator: ", "))) }
                    if !others.isEmpty { Text(Loc.f("Its site is offered in: %@", others.map(Regions.languageName).joined(separator: ", "))) }
                    if let note = entry.regions?.evidence, !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            Section {
                GuideButton(title: Loc.t("Opt out with a guide"), subtitle: subtitle) {
                    model.requireProfile { guide = model.guidedRunner(for: entry) }
                }
            }
            if !alsoHandles.isEmpty {
                Section {
                    ForEach(alsoHandles, id: \.self) { Text($0) }
                } header: { Text("This one request also handles \(alsoHandles.count) sites") }
            }
            if let issue = model.activeIssue(for: entry.id) {
                Label("You reported this site as not working: \(issue.kind.label.lowercased()).", systemImage: "exclamationmark.bubble")
                    .font(.footnote).foregroundStyle(.red).accessibilityIdentifier("reported-issue")
            }
            if let mail = entry.contactEmail, let url = Self.mailto(mail, person: model.selectedPerson, email: model.formEmail, site: entry.domain) {
                Section {
                    Link(destination: url) {
                        Label("Write the email to \(mail)", systemImage: "envelope").font(.headline).frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("write-email")
                } footer: { Text("This site takes opt-outs by email, not through a form. The message is filled in with your name and the household email; read it, then send it from your own mail app.") }
            }
            Section {
                let verdict = model.method(for: entry)
                Text(verdict.method.title).font(.headline).accessibilityIdentifier("method-title")
                Text(verdict.reason).font(.footnote)
                Text(verdict.method.explanation).font(.footnote).foregroundStyle(.secondary)
            }
            if let cover = model.platformCover(for: entry) {
                Section("\(cover.platform.shortName)") {
                    Text(cover.coverage.match == .name
                         ? "\(cover.coverage.broker) is probably this site's company on the \(cover.platform.jurisdiction) broker registry."
                         : "\(cover.coverage.broker) is on the \(cover.platform.jurisdiction) broker registry.")
                    if let until = cover.until {
                        Text("You submitted it. We leave this site's own form alone until \(Loc.date(until)), then check whether you are still listed.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("One \(cover.platform.shortName) request reaches this site along with the rest. It is in your queue on the first tab.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("platform-cover")
            }
            let n = Directory.familySize(of: entry, in: model.directory)
            if let parent = entry.familyParent, n > 1 {
                Section("Shared opt-out") {
                    Text("\(n) sites send their opt-outs to \(parent), so one request may clear them all. Not yet confirmed by a real run.")
                }
            }
            if let form = entry.optOutForm {
                Section {
                    ForEach(Array(form.fields.enumerated()), id: \.offset) { _, f in
                        Label(f.display, systemImage: f.type == "email" ? "envelope" : "text.cursor")
                    }
                    if let host = form.action?.host { Text("Submits to \(host)").font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("The opt-out form")
                } footer: {
                    Text("Found automatically by following links from the home page (\(form.hops) hop\(form.hops == 1 ? "" : "s")). Nothing here has been submitted.")
                }
            }
            if let check = entry.searchCheck {
                Section("Checking if you're listed") {
                    Label(check.statusLabel, systemImage: check.status == .calibrated ? "checkmark.seal" : "questionmark.circle")
                }
            }
            if let signals = entry.signals, !signals.isEmpty {
                Section("What we noticed") {
                    ForEach(signals, id: \.self) { Label(Describe.signal($0), systemImage: "info.circle") }
                }
            }
            Section("Source") {
                Text(entry.bucket == "direct" ? Loc.t("Listed as directly supported by an opt-out service.")
                     : entry.bucket == "registry" ? Loc.t("Registered as a data broker in California.")
                     : Loc.t("Listed as a mirror of another site."))
                if let d = entry.profiled { Text("Profiled \(d)").font(.footnote).foregroundStyle(.secondary) }
            }
            // The site's own link goes last: the guide above is the way in.
            if let url = model.effectiveURL(for: entry) {
                Section("Site link") {
                    Button("Open in Safari", systemImage: "safari") { browserURL = url }.accessibilityIdentifier("site-link")
                    Text(url.absoluteString).font(.caption).foregroundStyle(.secondary)
                    HealControls(siteID: entry.id, looking: $healing, find: { await model.healLink(for: entry) != nil })
                }
            }
        }
        .navigationTitle(entry.domain)
        .coach(CoachGuide.forMethod(model.method(for: entry).method))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $browserURL) { SafariView(url: $0).ignoresSafeArea() }
        .fullScreenCover(item: Binding(get: { guide.map(GuideBox.init) }, set: { if $0 == nil { guide = nil } })) { box in
            GuidedFlowView(runner: box.runner)
        }
    }
}


/// "Where am I listed?": runs the scan for the selected person and groups what it found.
struct ExposureView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmed = false

    var body: some View {
        NavigationStack {
            List {
                if let person = model.selectedPerson {
                    let results = model.exposure[person.id]
                    if let progress = model.scanProgress {
                        Section {
                            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                            Text("Checked \(progress.done) of \(progress.total) sites").font(.footnote)
                        }
                    } else if let results = results.map(rolledUp) {
                        summary(results)
                        group("Listed", .stillListed, results, color: .red)
                        group(Loc.t("Not found"), .removed, results, color: .green)
                        group(Loc.t("Could not tell"), .inconclusive, results, color: .orange)
                    } else {
                        Section {
                            Text("This searches each site for \(person.displayName) the way you would by typing the name into its website. Each site sees that search. Nothing is submitted and nothing is saved.")
                            Button("Scan \(ExposureScan.scannable(model.directory).count) sites", systemImage: "play.fill") {
                                Task { await model.scanExposure(for: person) }
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("start-scan")
                        }
                    }
                }
            }
            .navigationTitle("Where you're listed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    /// One row per site as the person knows it: a hand-written flow and the sites it clears (Spokeo and FreePeopleDirectory) are
    /// one row, listed if any of them is.
    private func rolledUp(_ results: [ScanResult]) -> [ScanResult] {
        var out: [ScanResult] = []
        var index: [String: Int] = [:]
        let rank: [CheckResult: Int] = [.stillListed: 0, .inconclusive: 1, .removed: 2]
        for r in results {
            let key = Directory.owner(of: r.entry, brokers: model.brokers)?.id ?? r.entry.id
            if let i = index[key] {
                if rank[r.outcome.result, default: 3] < rank[out[i].outcome.result, default: 3] { out[i] = r }
            } else { index[key] = out.count; out.append(r) }
        }
        return out
    }

    private func summary(_ results: [ScanResult]) -> some View {
        let listed = results.filter { $0.outcome.result == .stillListed }.count
        return Section {
            Text("Found a listing on \(listed) of \(results.count) sites checked.").font(.headline)
                .accessibilityIdentifier("scan-summary")
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ result: CheckResult, _ all: [ScanResult], color: Color) -> some View {
        let rows = all.filter { $0.outcome.result == result }
        if !rows.isEmpty {
            Section("\(title) (\(rows.count))") {
                ForEach(rows) { r in
                    NavigationLink {
                        if let owner = Directory.owner(of: r.entry, brokers: model.brokers) { BrokerInfoView(broker: owner) }
                        else { DirectoryInfoView(entry: r.entry) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(Directory.owner(of: r.entry, brokers: model.brokers)?.name ?? r.entry.domain)
                            if result == .inconclusive {
                                Text(reason(r.outcome.reason)).font(.caption).foregroundStyle(color)
                            }
                        }
                    }
                }
            }
        }
    }

    private func reason(_ r: InconclusiveReason?) -> String {
        switch r {
        case .blocked: return Loc.t("The site blocked the check")
        case .unrecognizedPage: return Loc.t("The page looked different than expected")
        case .network: return Loc.t("No connection")
        case .missingProfileData: return Loc.t("Add a full name (and city) to this profile")
        case .needsBrowser: return Loc.t("Needs a browser check")
        case .termsGate: return Loc.t("Behind terms you must accept yourself")
        default: return Loc.t("Could not tell")
        }
    }
}


/// One site at a time: open its search, look for yourself, tell us. Points come from looking, not from the answer.
struct QuickCheckView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var skipped = Set<String>()
    @State private var browserURL: URL?
    @State private var lastEarned: Int?

    private var current: DirectoryEntry? { model.quickCheckQueue.first { !skipped.contains($0.id) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text(model.score.level.name).font(.headline)
                        Spacer()
                        Text("\(model.score.points) pts").bold().accessibilityIdentifier("quick-points")
                    }
                    if let lastEarned {
                        Label("+\(lastEarned) points", systemImage: "sparkles").foregroundStyle(.green)
                            .accessibilityIdentifier("earned")
                    }
                }
                if let site = current, let person = model.selectedPerson {
                    Section {
                        Text(site.domain).font(.title3.bold())
                        Text("Open the site, search for \(person.displayName), and see if a listing comes up.")
                        Button("Open \(site.domain)", systemImage: "safari") { browserURL = site.lookupURL(for: person) }
                            .buttonStyle(.bordered)
                    }
                    Section("What did you see?") {
                        answer(Loc.t("I'm listed here"), .stillListed, +3, site, "exclamationmark.triangle", .red)
                        answer(Loc.t("Not found"), .removed, +5, site, "checkmark.circle", .green)
                        answer(Loc.t("Blocked by payment"), .paywalled, +2, site, "creditcard", .orange)
                        Button("Skip this one") { skipped.insert(site.id); lastEarned = nil }
                            .accessibilityIdentifier("answer-skip")
                    }
                } else {
                    Section { Text("You're all caught up. Check back later: listings come back.") }
                }
            }
            .navigationTitle("Quick checks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $browserURL) { SafariView(url: $0).ignoresSafeArea() }
        }
    }

    private func answer(_ title: String, _ result: CheckResult, _ points: Int, _ site: DirectoryEntry, _ symbol: String, _ color: Color) -> some View {
        Button { model.recordSelfCheck(result, site: site); lastEarned = points } label: {
            Label(title, systemImage: symbol).foregroundStyle(color)
        }
        .accessibilityIdentifier({ switch result { case .removed: return "answer-clean"; case .paywalled: return "answer-paywalled"; default: return "answer-listed" } }())
    }
}

/// The way into any site: big, full width, and always the first thing on the page.
struct GuideButton: View {
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Label(title, systemImage: "rectangle.bottomthird.inset.filled").font(.title3.bold())
                Text(subtitle).font(.footnote)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("guide-me")
    }
}

/// "Find the current opt-out page": the app crawls the site for it and remembers what it finds on this device. Also shows when a
/// link was healed and lets the person go back to the recorded one.
struct HealControls: View {
    @EnvironmentObject var model: AppModel
    let siteID: String
    @Binding var looking: Bool
    let find: () async -> Bool
    @State private var message: String?

    var body: some View {
        if let healed = model.healedLink(for: siteID) {
            Label("This site's opt-out page had moved. We found the new one on \(Loc.date(healed.foundAt)).",
                  systemImage: "wand.and.stars").font(.footnote).foregroundStyle(.green).accessibilityIdentifier("healed-note")
            Button("Go back to the recorded link", role: .destructive) { model.forgetHealedLink(siteID) }
        }
        Button {
            looking = true
            Task {
                let found = await find()
                message = found ? Loc.t("Found it.") : Loc.t("No newer opt-out page was found.")
                looking = false
            }
        } label: {
            Label(looking ? "Looking…" : Loc.t("Find the current opt-out page"), systemImage: "magnifyingglass")
        }
        .disabled(looking)
        .accessibilityIdentifier("find-current-page")
        if let message { Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("heal-message") }
    }
}


/// The sites that no longer respond, each with the checks that showed it.
struct ClosedSitesView: View {
    let sites: [DirectoryEntry]

    var body: some View {
        List {
            Section {
                Text("Each site was tried at its plain and its www address, twice, and failed the same way every time. The same proof is kept in the project's CLOSED_SITES.md file.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(sites) { e in
                Section {
                    ForEach(e.closed?.evidence ?? [], id: \.self) { line in
                        Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text(e.domain).textCase(nil).font(.subheadline.bold())
                } footer: {
                    Text(Loc.f("Checked %@", e.closed?.checked ?? "-"))
                }
            }
        }
        .navigationTitle("No longer respond")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("closed-sites-list")
    }
}


/// Sites with no route to opt out yet: not tasks, listed so every site is accounted for.
struct LockedSitesView: View {
    let sites: [DirectoryEntry]

    var body: some View {
        List {
            Section {
                Text("These sites have no form, page or email we can use. Nothing for you to do; we keep looking, and a site moves into your tasks as soon as we find a route.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                ForEach(sites) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(e.domain, systemImage: "lock").font(.headline)
                        Text(e.name).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Unlock later")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("locked-sites-list")
    }
}
