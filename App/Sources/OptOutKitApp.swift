import SwiftUI
import OptOutKitCore

@main
struct OptOutKitApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {}

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
                .task { CheckScheduler.register(model: model) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !ProcessInfo.processInfo.arguments.contains("-uitest-reset") else { return }
            Task { await model.runDueChecks() }
            CheckScheduler.schedule()
        }
    }
}

/// Holds the broker queue and everyone the app runs opt-outs for.
/// The household is one encrypted file on the device; the key lives in the Keychain (KeychainKey.swift).
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var brokers: [Broker] = []
    /// Every profiled site, including those with no hand-written flow yet.
    @Published private(set) var directory: [DirectoryEntry] = []
    /// Paragraphs of terms text a person has (or has not yet) reviewed. Ships with none reviewed, so nothing is ever accepted
    /// for anyone until a reviewer marks paragraphs and the person turns this on. See docs/TERMS.md.
    @Published private(set) var termsLibrary: TermsLibrary?
    @Published private(set) var household = Household()
    @Published private(set) var selectedID: UUID
    @Published var loadError: String?
    /// Set when saved data exists but cannot be opened. Saving is paused so it is never overwritten by accident.
    @Published private(set) var storageProblem: String?

    @Published private(set) var pending: Pending = .nothing
    @Published private(set) var isChecking = false
    /// Latest "where am I listed" scan per person. Kept in memory only: it is a snapshot, not a record.
    @Published private(set) var exposure: [UUID: [ScanResult]] = [:]
    @Published private(set) var scanProgress: (done: Int, total: Int)?

    private let store: HouseholdStore
    private let defaults: UserDefaults
    private let catalog: [Announcement]
    private static let seenKey = "announcement.lastSeen"

    /// Progress for whoever is selected, so the broker views stay person-agnostic.
    var progress: OptOutKitCore.Progress { household.progress(for: selectedID) }
    var people: [Person] { household.people }
    var selectedPerson: Person? { household.people.first { $0.id == selectedID } }

    nonisolated static func defaultStore() -> HouseholdStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return HouseholdStore(url: dir.appendingPathComponent("household.sealed"), keys: KeychainKey())
    }

    init(store: HouseholdStore = AppModel.defaultStore(),
         brokersDirectory: URL? = Bundle.main.url(forResource: "brokers", withExtension: nil),
         directoryURL: URL? = Bundle.main.url(forResource: "directory", withExtension: nil),
         termsLibraryURL: URL? = Bundle.main.url(forResource: "terms", withExtension: nil)?.appendingPathComponent("library.yml"),
         defaults: UserDefaults = .standard,
         catalog: [Announcement] = AnnouncementCatalog.all) {
        self.store = store
        self.defaults = defaults
        self.catalog = catalog
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-uitest-reset") {
            try? store.erase()
            // UI tests skip the walkthrough unless a test asks for it.
            if args.contains("-uitest-onboarding") { defaults.removeObject(forKey: Self.seenKey) }
            else { defaults.set(Announcements.newestID(catalog), forKey: Self.seenKey) }
        }
        pending = Announcements.pending(lastSeen: defaults.object(forKey: Self.seenKey) as? Int, catalog: catalog)
        var loaded = Household()
        var problem: String?
        do {
            if let saved = try store.load() { loaded = saved }
        } catch {
            problem = "Your saved profiles could not be opened on this device (\(error)). They are untouched."
        }
        if loaded.people.isEmpty { loaded.add(Person(displayName: "Me", relationship: .me)) }
        household = loaded
        selectedID = loaded.people[0].id
        storageProblem = problem
        if let directoryURL { directory = (try? Registry.loadDirectory(directoryURL)) ?? [] }
        if let termsLibraryURL { termsLibrary = try? TermsLibrary.load(termsLibraryURL) }
        do {
            guard let brokersDirectory else { throw CocoaError(.fileNoSuchFile) }
            brokers = try Registry.load(directory: brokersDirectory)
        } catch {
            loadError = "Could not load the broker registry: \(error)"
        }
    }

    func complete(_ broker: Broker, step: Int) {
        let wasDone = progress.isDone(broker.id)
        household.mutateProgress(for: selectedID) { $0.complete(broker, step: step) }
        save()
        if !wasDone, progress.isDone(broker.id), broker.recheck != nil,
           !ProcessInfo.processInfo.arguments.contains("-uitest-reset") {
            CheckScheduler.requestNotificationPermission()   // first submitted opt-out: now there is a reason to ask
        }
    }

    var score: Score { Score.compute(progress, brokers: brokers) }

    /// Why searching is off for the selected person, or nil when it is allowed. Minors and public figures are never searched.
    var searchBlockedReason: String? {
        guard let p = selectedPerson, !p.canBeSearched() else { return nil }
        let why = p.isPublicFigure ? "a public figure" : "under 18"
        return "Searches are off for \(p.displayName) (\(why)). Several sites' terms don't allow searching for minors, public officials or celebrities. Opt-out requests still work."
    }

    // MARK: Terms on the person's behalf (off unless reviewed paragraphs exist AND the person approved this list version)

    var termsApproval: TermsApproval? { household.termsApproval }
    var consentLog: [ConsentLogEntry] { household.consentLog }
    var termsReviewedCount: Int { termsLibrary?.reviewedCount ?? 0 }
    var termsActive: Bool {
        guard let lib = termsLibrary, lib.reviewedCount > 0, let a = termsApproval else { return false }
        return a.libraryVersion == lib.version
    }

    func approveTerms() {
        guard let lib = termsLibrary, lib.reviewedCount > 0 else { return }
        household.approveTerms(libraryVersion: lib.version)
        save()
    }

    func revokeTerms() { household.revokeTermsApproval(); save() }

    /// The policy handed to the web view, or nil when nothing may be accepted.
    func makeTermsPolicy() -> TermsPolicy? {
        guard termsActive, let lib = termsLibrary else { return nil }
        return LibraryTermsPolicy(library: lib, approval: termsApproval) { [weak self] entry in
            Task { @MainActor in self?.household.logConsent(entry); self?.save() }
        }
    }

    /// Directory sites the person can look at themselves, skipping any they looked at in the last 30 days.
    var quickCheckQueue: [DirectoryEntry] {
        guard searchBlockedReason == nil else { return [] }
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        return unguidedSites
            .filter { $0.needsManualCheck && $0.automation != .unreachable }
            .filter { (progress.latestSiteCheck($0.id)?.date ?? .distantPast) < cutoff }
            .sorted { ($0.optOutForm != nil ? 0 : 1, $0.domain) < ($1.optOutForm != nil ? 0 : 1, $1.domain) }
    }

    /// The person looked for themselves. Points are paid for looking, whatever they found.
    func recordSelfCheck(_ result: CheckResult, site: DirectoryEntry) {
        household.mutateProgress(for: selectedID) { $0.recordSiteCheck(result, site: site.id, source: .selfReported) }
        save()
    }

    /// Searches every directory site that can be checked automatically for one person. Read-only.
    func scanExposure(for person: Person, fetcher: PageFetcher? = nil) async {
        guard scanProgress == nil, person.canBeSearched() else { return }
        let total = ExposureScan.scannable(directory).count
        scanProgress = (0, total)
        defer { scanProgress = nil }
        #if DEBUG
        let useFetcher: PageFetcher = fetcher ?? (ProcessInfo.processInfo.arguments.contains("-uitest-fake-scan") ? FakeScanFetcher() : URLSessionFetcher())
        #else
        let useFetcher: PageFetcher = fetcher ?? URLSessionFetcher()
        #endif
        // Sites whose results are built by JavaScript are read through the hidden web view; everything else through plain requests.
        let browser: PageFetcher? = ProcessInfo.processInfo.arguments.contains("-uitest-fake-scan") ? nil : WebViewFetcher(termsPolicy: makeTermsPolicy())
        let results = await ExposureScan(fetcher: useFetcher, browserFetcher: browser).run(directory, for: person) { [weak self] done, total in
            Task { @MainActor in self?.scanProgress = (done, total) }
        }
        exposure[person.id] = results
        household.mutateProgress(for: person.id) { p in
            for r in results where r.outcome.result != .inconclusive { p.recordSiteCheck(r.outcome.result, site: r.entry.id, source: .automatic) }
        }
        save()
    }

    /// One-off "does this site have my data?" scan. It searches the broker the same way a re-check does,
    /// records nothing and submits nothing.
    func scan(_ broker: Broker, for person: Person, fetcher: PageFetcher = URLSessionFetcher()) async -> CheckOutcome {
        await Rechecker(fetcher: fetcher).check(broker, for: person)
    }

    /// Runs any automatic checks that are due, records the results and tells the user what changed.
    func runDueChecks(fetcher: PageFetcher = URLSessionFetcher(), now: Date = Date()) async {
        guard storageProblem == nil, !isChecking else { return }
        let due = CheckRunner.due(in: household, brokers: brokers, now: now)
        guard !due.isEmpty else { return }
        isChecking = true
        defer { isChecking = false }
        let outcomes = await CheckRunner(fetcher: fetcher).run(due)
        let events = household.apply(outcomes, now: now)
        save()
        CheckScheduler.notify(events)
    }

    func reset(_ broker: Broker) {
        household.mutateProgress(for: selectedID) { $0.reset(broker.id) }
        save()
    }

    @discardableResult
    func addPerson(named name: String, relationship: Relationship = .otherFamily) -> Person? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let person = Person(displayName: trimmed, relationship: relationship,
                            names: [NameEntry(kind: .legal, name: trimmed)])
        household.add(person)
        selectedID = person.id
        save()
        return person
    }

    func update(_ person: Person) {
        household.update(person)
        save()
    }

    /// Deletes the person's profile and progress. The last remaining person cannot be removed.
    func remove(_ id: UUID) {
        guard household.people.count > 1 else { return }
        household.remove(id)
        if selectedID == id { selectedID = household.people[0].id }
        save()
    }

    /// Marks everything shown so far as seen. A fresh install and an update both end up here.
    func finishAnnouncements() {
        defaults.set(Announcements.newestID(catalog), forKey: Self.seenKey)
        pending = .nothing
    }

    func showWalkthrough() { pending = .walkthrough }

    /// Sites we know about but have no step-by-step flow for yet.
    var unguidedSites: [DirectoryEntry] { Directory.unguided(directory, brokers: brokers) }

    var sharedEmails: Set<String> { household.sharedEmails }

    func select(_ id: UUID) { if household.people.contains(where: { $0.id == id }) { selectedID = id } }

    /// The user chose to discard unreadable data and start over.
    func eraseAndStartOver() {
        try? store.erase()
        household = Household()
        household.add(Person(displayName: "Me", relationship: .me))
        selectedID = household.people[0].id
        storageProblem = nil
        save()
    }

    private func save() {
        guard storageProblem == nil else { return }
        do { try store.save(household) } catch { storageProblem = "Could not save: \(error)" }
    }
}


#if DEBUG
/// UI tests use this so they never touch the real internet: every site "lists" anyone whose name contains Pat.
struct FakeScanFetcher: PageFetcher {
    func fetch(_ url: URL) async throws -> FetchedPage {
        FetchedPage(status: 200, text: "directory search results Pat Example no result sorry")
    }
}
#endif
