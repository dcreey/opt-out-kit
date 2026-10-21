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
    @State private var filter = Filter.all
    @State private var showScan = false
    @State private var showQuick = false

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", todo = "To do", done = "Opted out"
        var id: String { rawValue }
    }

    private var shown: [Broker] {
        model.brokers.filter { broker in
            let s = model.household.summary(for: broker)
            switch filter {
            case .all: break
            case .todo: if s.isFinished { return false }
            case .done: if !s.isFinished { return false }
            }
            guard !search.isEmpty else { return true }
            let q = search.lowercased()
            return broker.name.lowercased().contains(q) || (broker.covers ?? []).contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    scoreCard
                    Button { showQuick = true } label: {
                        Label("Quick checks (\(model.quickCheckQueue.count) sites)", systemImage: "bolt.fill")
                    }
                    .disabled(model.searchBlockedReason != nil)
                    .accessibilityIdentifier("quick-checks")
                } footer: {
                    Text("Look a site up yourself in 20 seconds and tell us what you see. Each look earns points.")
                }
                Section {
                    Button { showScan = true } label: {
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
                Section {
                    Picker("Filter", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("sites-filter")
                }
                ForEach(OptOutMethod.allCases, id: \.self) { method in
                    let entries = shownDirectory(method)
                    let brokers = method == .guided ? shown : []
                    if !entries.isEmpty || !brokers.isEmpty {
                        Section {
                            ForEach(brokers) { broker in
                                NavigationLink(value: broker) { row(broker) }
                                    .accessibilityIdentifier("site-\(broker.id)")
                            }
                            if filter != .done {
                                ForEach(entries.prefix(300)) { entry in
                                    NavigationLink(value: entry) { directoryRow(entry) }
                                        .accessibilityIdentifier("dir-\(entry.id)")
                                }
                            }
                        } header: {
                            Text("\(method.title) (\(brokers.count + (filter == .done ? 0 : entries.count)) sites)")
                                .accessibilityIdentifier("method-\(method.rawValue)")
                        } footer: {
                            Text(method.explanation)
                        }
                    }
                }
            }
            .accessibilityIdentifier("sites-list")
            .navigationTitle("Sites")
            .searchable(text: $search, prompt: "Search by name or web address")
            .navigationDestination(for: Broker.self) { BrokerInfoView(broker: $0) }
            .navigationDestination(for: DirectoryEntry.self) { DirectoryInfoView(entry: $0) }
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

    private func shownDirectory(_ method: OptOutMethod) -> [DirectoryEntry] {
        let q = search.lowercased()
        return model.unguidedSites.filter { (q.isEmpty || $0.domain.lowercased().contains(q)) && model.method(for: $0).method == method }
    }

    private func directoryRow(_ e: DirectoryEntry) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.domain).font(.headline)
                Text(model.method(for: e).reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                let n = Directory.familySize(of: e, in: model.directory)
                if n > 1 { Text("Shares one opt-out with \(n - 1) other sites").font(.caption).foregroundStyle(.blue) }
                if model.activeIssue(for: e.id) != nil { Text("Reported not working").font(.caption).foregroundStyle(.red) }
            }
            Spacer()
        }
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
                GuideButton(title: "Guide me through it", subtitle: "\(broker.steps.count) steps, in a full-screen browser") {
                    guide = model.guidedRunner(for: broker)
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
                            .buttonStyle(.bordered)
                    }
                    if broker.recheck != nil {
                        scanRow(item.person)
                    }
                }
            }

            Section("What to expect") {
                Text(OptOutMethods.classify(broker).method.title).font(.headline)
                Text(OptOutMethods.classify(broker).method.explanation).font(.footnote)
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
        case .stillListed: return "Listing found"
        case .removed: return "No listing found"
        case .paywalled: return "Results are behind payment"
        case .inconclusive:
            switch o.reason {
            case .blocked: return "Can't tell: site blocked the check"
            case .unrecognizedPage: return "Can't tell: page looked different"
            case .network: return "Can't tell: no connection"
            case .missingProfileData: return "Add a full name and city first"
            default: return "Can't tell"
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
        case .notStarted: return "Not started"
        case .inProgress(let d, let n): return "In progress: \(d) of \(n) steps"
        case .done(let on, let due):
            return "Submitted \(on.formatted(date: .abbreviated, time: .omitted)); checking from \(due.formatted(date: .abbreviated, time: .omitted))"
        case .verified(let since): return "Verified removed \(since.formatted(date: .abbreviated, time: .omitted))"
        case .relisted(let on): return "Listed again \(on.formatted(date: .abbreviated, time: .omitted))"
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
struct DirectoryInfoView: View {
    @EnvironmentObject var model: AppModel
    let entry: DirectoryEntry
    @State private var browserURL: URL?
    @State private var guide: GuidedRunner?
    @State private var healing = false
    private var resolvedEntry: DirectoryEntry { model.resolved(entry) }
    private var subtitle: String {
        switch model.method(for: entry).method {
        case .automatic: return "We fill in the form and send it"
        case .semiAutomatic: return "We fill in the form; you clear the check"
        case .guided: return "We take you to the page and walk you through it"
        case .manual: return "We open the site; you find its opt-out link"
        }
    }

    var body: some View {
        List {
            Section {
                GuideButton(title: "Opt out with a guide", subtitle: subtitle) {
                    guide = model.guidedRunner(for: entry)
                }
            }
            if let issue = model.activeIssue(for: entry.id) {
                Label("You reported this site as not working: \(issue.kind.label.lowercased()).", systemImage: "exclamationmark.bubble")
                    .font(.footnote).foregroundStyle(.red).accessibilityIdentifier("reported-issue")
            }
            Section {
                let verdict = model.method(for: entry)
                Text(verdict.method.title).font(.headline).accessibilityIdentifier("method-title")
                Text(verdict.reason).font(.footnote)
                Text(verdict.method.explanation).font(.footnote).foregroundStyle(.secondary)
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
                Text(entry.bucket == "direct" ? "Listed as directly supported by an opt-out service." : "Listed as a mirror of another site.")
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
                    } else if let results {
                        summary(results)
                        group("Listed", .stillListed, results, color: .red)
                        group("Not found", .removed, results, color: .green)
                        group("Could not tell", .inconclusive, results, color: .orange)
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
                        DirectoryInfoView(entry: r.entry)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(r.entry.domain)
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
        case .blocked: return "The site blocked the check"
        case .unrecognizedPage: return "The page looked different than expected"
        case .network: return "No connection"
        case .missingProfileData: return "Add a full name (and city) to this profile"
        case .needsBrowser: return "Needs a browser check"
        case .termsGate: return "Behind terms you must accept yourself"
        default: return "Could not tell"
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
                        answer("I'm listed here", .stillListed, +3, site, "exclamationmark.triangle", .red)
                        answer("Not found", .removed, +5, site, "checkmark.circle", .green)
                        answer("Blocked by payment", .paywalled, +2, site, "creditcard", .orange)
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
            Label("This site's opt-out page had moved. We found the new one on \(healed.foundAt.formatted(date: .abbreviated, time: .omitted)).",
                  systemImage: "wand.and.stars").font(.footnote).foregroundStyle(.green).accessibilityIdentifier("healed-note")
            Button("Go back to the recorded link", role: .destructive) { model.forgetHealedLink(siteID) }
        }
        Button {
            looking = true
            Task {
                let found = await find()
                message = found ? "Found it." : "No newer opt-out page was found."
                looking = false
            }
        } label: {
            Label(looking ? "Looking…" : "Find the current opt-out page", systemImage: "magnifyingglass")
        }
        .disabled(looking)
        .accessibilityIdentifier("find-current-page")
        if let message { Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("heal-message") }
    }
}
