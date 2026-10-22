import SwiftUI
import WebKit
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
            Task { await model.runDueChecks(); await model.runDueAutomation() }
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
    /// Last automatic opt-out run per person, in memory. What was actually sent is also saved in each person's progress.
    @Published private(set) var optOutRun: [UUID: [AutoOptOutRow]] = [:]
    @Published private(set) var autoBusy: String?
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

    // MARK: Automatic protection: a daily scan and a weekly opt-out, switched on by the person at first use

    struct AutoOptOutRow: Identifiable, Equatable { let id: String; let domain: String; let result: AutoOptOutResult }

    var autoSettings: AutoSettings { household.autoSettings }

    /// The person's answer to the first-run question, or a later change in Settings.
    /// Whether the account owner allowed "I am this person" boxes to be ticked for them. Never applies to family profiles.
    var confirmsOwnIdentity: Bool { household.people.contains { $0.relationship == .me && $0.confirmsOwnIdentity } }
    /// How this site gets opted out for the selected person, including what real page loads and past sends have shown.
    func method(for entry: DirectoryEntry) -> MethodVerdict {
        let challenged = progress.optOutAttempts[entry.id]?.last?.outcome == "challenged"
        return OptOutMethods.classify(resolved(entry), confirmingIdentity: confirmingIdentityForSelected, challengedBefore: challenged)
    }
    var confirmingIdentityForSelected: Bool { selectedPerson?.mayConfirmOwnIdentity() ?? false }

    func setConfirmsOwnIdentity(_ on: Bool) {
        for p in household.people where p.relationship == .me { var q = p; q.confirmsOwnIdentity = on; update(q) }
    }

    func setAuto(scan: Bool, optOut: Bool) {
        household.updateAuto { a in
            if scan || optOut { a.turnOnBoth(now: a.decidedAt ?? Date()) }
            else { a.declineForNow(now: a.decidedAt ?? Date()) }
            a.scanEnabled = scan; a.optOutEnabled = optOut
        }
        save()
        if scan || optOut, !ProcessInfo.processInfo.arguments.contains("-uitest-reset") { CheckScheduler.requestNotificationPermission() }
        CheckScheduler.scheduleAutomation(autoSettings)
    }

    private func makeSubmitter() -> FormSubmitter {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-fake-submit") { return FakeSubmitter() }
        #endif
        return WebFormSubmitter()
    }

    /// Sends opt-out requests for one person to every site whose form we found. `dryRun` fills forms but never sends them.
    func runAutoOptOut(for person: Person, dryRun: Bool = false, submitter: FormSubmitter? = nil, inspector: PageInspector? = nil) async {
        guard storageProblem == nil else { return }
        let engine = AutoOptOut(submitter: submitter ?? makeSubmitter(), spacing: submitter == nil ? 2 : 0)
        let now = Date()
        var results = await engine.run(entries: directory.map(resolved), person: person, progress: household.progress(for: person.id), now: now, dryRun: dryRun)
        // A page that has gone is usually a moved link: look for the new one and try that site again, once.
        if !dryRun {
            let gone = results.filter { if case .failed(let why) = $0.1 { return why == FormRun.pageGone } else { return false } }.prefix(10)
            var retry: [DirectoryEntry] = []
            for (entry, _) in gone {
                if let original = directory.first(where: { $0.id == entry.id }), await healLink(for: original, inspector: inspector) != nil { retry.append(resolved(original)) }
            }
            if !retry.isEmpty {
                let again = await engine.run(entries: retry, person: person, progress: household.progress(for: person.id), now: now, dryRun: false)
                for (entry, result) in again { if let i = results.firstIndex(where: { $0.0.id == entry.id }) { results[i] = (entry, result) } }
            }
        }
        household.mutateProgress(for: person.id) { p in
            for (entry, result) in results {
                if let attempt = AutoOptOut.attempt(for: result, now: now) { p.recordOptOutAttempt(attempt, site: entry.id) }
            }
        }
        optOutRun[person.id] = results.map { AutoOptOutRow(id: $0.0.id, domain: $0.0.domain, result: $0.1) }
        if !dryRun { household.updateAuto { $0.lastOptOut = now } }
        save()
        if !dryRun { CheckScheduler.notifyOptOut(sent: results.filter { if case .submitted = $0.1 { return true } else { return false } }.count,
                                                  needYou: results.filter { if case .needsYou = $0.1 { return true } else { return false } }.count) }
    }

    /// Sites the person can finish with one tap each: their form is found, their details are on the profile, and nothing was sent
    /// in the last week. The app fills and sends each one once the person has solved its check.
    func assistedItems(for person: Person, now: Date = Date()) -> [AssistedRunner.Item] {
        let progress = household.progress(for: person.id)
        return directory.map(resolved).compactMap { entry -> AssistedRunner.Item? in
            guard let form = entry.optOutForm else { return nil }
            let pre = AutoOptOut.precheck(entry: entry, person: person, progress: progress, now: now)
            guard pre.result == nil, let plan = pre.plan else { return nil }
            return AssistedRunner.Item(entry: entry, form: form, plan: plan)
        }
    }

    func makeAssistedDriver() -> AssistedDriver {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-fake-submit") { return FakeAssistedDriver() }
        #endif
        return WebAssistedDriver()
    }

    /// The person reported a problem with a site (broken link, gated by something else, blocked them). Queues leave it alone for a month.
    func reportIssue(_ kind: IssueKind, site: String) {
        household.mutateProgress(for: selectedID) { $0.reportIssue(kind, site: site) }
        save()
    }

    func activeIssue(for site: String) -> SiteIssue? { progress.activeIssue(for: site) }

    // MARK: Healing moved links

    /// The directory entry with any link the app healed on this device swapped in, so every flow uses the working address.
    func resolved(_ entry: DirectoryEntry) -> DirectoryEntry {
        guard let healed = household.healedLink(for: entry.id) else { return entry }
        var e = entry; e.optOutForm = healed.form; e.optOutURL = healed.form.page
        return e
    }

    func healedLink(for siteID: String) -> HealedLink? { household.healedLink(for: siteID) }

    /// The address to use for a site's opt-out page: a link the app healed on this device, else the recorded one.
    func effectiveURL(for entry: DirectoryEntry) -> URL? { household.healedLink(for: entry.id)?.form.page ?? entry.optOutForm?.page ?? entry.optOutURL }
    func effectiveURL(for broker: Broker) -> URL? { household.healedLink(for: broker.id)?.form.page ?? broker.steps.compactMap(\.open).first }

    func makeInspector() -> PageInspector {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-uitest-fake-heal") { return FakeInspector() }
        if args.contains("-uitest-fake-guided") { return NothingInspector() }      // UI tests never crawl real sites
        #endif
        return WebPageInspector()
    }

    /// Looks for a site's current opt-out form by crawling from its home page, and remembers it on this device. Sends nothing
    /// anywhere and uses no personal data. Returns the new link, or nil if none was found.
    @discardableResult
    func healLink(siteID: String, domain: String, inspector: PageInspector? = nil) async -> HealedLink? {
        guard let home = URL(string: "https://\(domain)/") else { return nil }
        let result = await OptOutLinkFinder(inspector: inspector ?? makeInspector()).find(from: home)
        guard let form = result.form else { return nil }
        let link = HealedLink(siteID: siteID, form: form)
        household.saveHealedLink(link)
        save()
        return link
    }

    func healLink(for entry: DirectoryEntry, inspector: PageInspector? = nil) async -> HealedLink? {
        await healLink(siteID: entry.id, domain: entry.domain, inspector: inspector)
    }

    func healLink(for broker: Broker, inspector: PageInspector? = nil) async -> HealedLink? {
        guard let host = broker.steps.compactMap(\.open).first?.host else { return nil }
        return await healLink(siteID: broker.id, domain: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host, inspector: inspector)
    }

    func forgetHealedLink(_ siteID: String) { household.forgetHealedLink(siteID); save() }

    func makeGuidedPageMaker() -> GuidedPageMaker {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-fake-guided") { return FakeGuidedPageMaker() }
        #endif
        return WebGuidedPageMaker()
    }

    /// A guided runner for a hand-written broker flow, resuming at the first step not yet done.
    func guidedRunner(for broker: Broker) -> GuidedRunner? {
        guard let person = selectedPerson else { return nil }
        if let listing = listingRunner(for: broker, person: person) { return listing }
        var plan = GuidedPlanner.plan(for: broker)
        if let healed = household.healedLink(for: broker.id), let first = plan.steps.firstIndex(where: { if case .openPage = $0.action { return true } else { return false } }) {
            plan.steps[first].action = .openPage(healed.form.page)         // the first page moved: use where it went
        }
        let done = (0..<broker.steps.count).first { !progress.isStepDone(broker.id, $0) } ?? 0
        return GuidedRunner(plan: plan, resumeAt: done, person: person, page: makeGuidedPageMaker().make(),
                            onStepCompleted: { [weak self] i in self?.complete(broker, step: i) },
                            onIssue: { [weak self] kind in self?.reportIssue(kind, site: broker.id) },
                            healer: { [weak self] in await self?.healLink(for: broker)?.form.page })
    }

    /// Semi-automated flow for a hand-written broker whose own opt-out form wants the person's listing (Spokeo): the app searches
    /// for them, they pick their listing, the app fills in and sends, they clear the check. Nil when that does not apply.
    private func listingRunner(for broker: Broker, person: Person) -> GuidedRunner? {
        guard let entry = Directory.entry(for: broker, in: directory).map(resolved), let form = entry.optOutForm,
              FormFiller.needsListing(form), let search = entry.listingSearchURL(for: person) else { return nil }
        let plan = GuidedPlanner.listingPlan(for: entry, search: search)
        let values = FormFiller.plan(for: form, signals: entry.signals, person: person).values
        let emailStep = broker.steps.firstIndex { $0.waitForEmail != nil } ?? broker.steps.count
        return GuidedRunner(plan: plan, person: person, fillValues: values, page: makeGuidedPageMaker().make(),
                            onStepCompleted: { [weak self] i in
                                // The plan's last step is sending; the broker steps before its email wait are done then, the rest after the email.
                                guard let self else { return }
                                if plan.steps.indices.contains(i), case .send = plan.steps[i].action { for k in 0..<emailStep { self.complete(broker, step: k) } }
                                else if i >= plan.steps.count { for k in emailStep..<broker.steps.count { self.complete(broker, step: k) } }
                            },
                            onSent: { [weak self] result in self?.recordAssisted(entry, result, for: person) },
                            onIssue: { [weak self] kind in self?.reportIssue(kind, site: broker.id) },
                            healer: { [weak self] in await self?.healLink(for: broker)?.form.page })
    }

    /// A guided runner for a directory site: the app fills and sends the form, the person clears what only they can.
    func guidedRunner(for original: DirectoryEntry) -> GuidedRunner? {
        guard let person = selectedPerson else { return nil }
        let entry = resolved(original)
        let plan: GuidedPlan
        if let form = entry.optOutForm, FormFiller.needsListing(form), let search = entry.listingSearchURL(for: person) {
            plan = GuidedPlanner.listingPlan(for: entry, search: search)
        } else {
            plan = GuidedPlanner.plan(for: entry)
        }
        let values: [FieldValue] = entry.optOutForm.map { FormFiller.plan(for: $0, signals: entry.signals, person: person).values } ?? []
        return GuidedRunner(plan: plan, person: person, fillValues: values, page: makeGuidedPageMaker().make(),
                            onSent: { [weak self] result in self?.recordAssisted(entry, result, for: person) },
                            onIssue: { [weak self] kind in self?.reportIssue(kind, site: entry.id) },
                            healer: { [weak self] in await self?.healLink(for: original)?.form.page })
    }

    /// A result from the Solve-and-send screen: remembered like any other automatic attempt.
    func recordAssisted(_ entry: DirectoryEntry, _ result: AutoOptOutResult, for person: Person) {
        household.mutateProgress(for: person.id) { p in
            if let attempt = AutoOptOut.attempt(for: result, now: Date()) { p.recordOptOutAttempt(attempt, site: entry.id) }
        }
        var rows = optOutRun[person.id] ?? []
        rows.removeAll { $0.id == entry.id }
        rows.append(AutoOptOutRow(id: entry.id, domain: entry.domain, result: result))
        optOutRun[person.id] = rows
        save()
    }

    /// Runs whatever is due: the daily scan and the weekly opt-out, for everyone in the family. Does nothing until the person has said yes.
    func runDueAutomation(now: Date = Date()) async {
        guard storageProblem == nil, autoBusy == nil else { return }
        let settings = household.autoSettings
        if settings.scanDue(now: now) {
            autoBusy = "scan"
            for person in people where person.canBeSearched() { await scanExposure(for: person) }
            household.updateAuto { $0.lastScan = now }
            save()
            autoBusy = nil
        }
        if household.autoSettings.optOutDue(now: now) {
            autoBusy = "optout"
            for person in people { await runAutoOptOut(for: person) }
            autoBusy = nil
        }
        CheckScheduler.scheduleAutomation(autoSettings)
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
            for r in results where r.outcome.result.isConclusive { p.recordSiteCheck(r.outcome.result, site: r.entry.id, source: .automatic) }
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


#if DEBUG
/// UI tests use this so they never contact a real site: every other site "sends", the rest are stopped by a bot check.
struct FakeSubmitter: FormSubmitter {
    func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome {
        if dryRun { return .filledNotSubmitted }
        return form.page.absoluteString.count % 2 == 0 ? .submitted(awaitingEmail: true) : .challenged("a bot check")
    }
}
#endif


#if DEBUG
/// UI tests use this so the Solve-and-send screen never loads a real site: each page shows a check for two polls, then sends.
@MainActor
struct FakeAssistedDriver: AssistedDriver {
    func prepare(_ form: OptOutForm, plan: FillPlan) async -> AssistedPage? { FakeAssistedPage() }
}

@MainActor
final class FakeAssistedPage: AssistedPage {
    private var polls = 0
    var webView: WKWebView? { nil }
    func blockers() async -> [AssistedBlocker] { polls += 1; return polls <= 2 ? [.check("a bot check")] : [] }
    func refill() async {}
    func send() async -> SubmitOutcome { .submitted(awaitingEmail: false) }
    func close() {}
}
#endif


#if DEBUG
/// UI tests use this so guided flows never load a real site: a real web view shows a local page, and the checks are scripted.
@MainActor
struct FakeGuidedPageMaker: GuidedPageMaker { func make() -> GuidedPage { FakeGuidedPage() } }

@MainActor
final class FakeGuidedPage: GuidedPage {
    private let view = WKWebView(frame: .zero)
    private var polls = 0
    var webView: WKWebView? { view }
    func load(_ url: URL) async {
        view.loadHTMLString("<html><body style='font-family:-apple-system;padding:24px'><h1>Fake opt-out page</h1><p>\(url.host ?? "site")</p><form><input placeholder='Email'><br><br><button>Submit</button></form></body></html>", baseURL: nil)
    }
    func currentURL() -> URL? { URL(string: "https://fake.example/page") }
    func visibleText() async -> String { "Fake opt-out page" }
    func fill(_ values: [FieldValue]) async -> Int { values.count }
    func blockers() async -> [AssistedBlocker] { polls += 1; return polls <= 2 ? [.check("a bot check")] : [] }
    func send(_ values: [FieldValue]) async -> SubmitOutcome { .submitted(awaitingEmail: true) }
    func close() {}
}
#endif


#if DEBUG
/// UI tests use this so healing never crawls a real site: the home page links to a privacy page that links to a request portal.
struct NothingInspector: PageInspector { func snapshot(_ url: URL) async -> PageSnapshot? { nil } }

struct FakeInspector: PageInspector {
    func snapshot(_ url: URL) async -> PageSnapshot? {
        let base = "https://\(url.host ?? "fake.example")"
        switch url.path {
        case "", "/": return PageSnapshot(url: url, title: "Fake site", text: "Welcome", links: [LinkSnapshot(href: URL(string: base + "/privacy-rights")!, text: "Your Privacy Rights")])
        case "/privacy-rights": return PageSnapshot(url: url, title: "Privacy Rights", text: "Your privacy rights. Right to opt out.", links: [LinkSnapshot(href: URL(string: base + "/request-portal/")!, text: "Privacy Request Portal")])
        case "/request-portal/":
            return PageSnapshot(url: url, title: "Request Portal", text: "Privacy Request Portal. Right to opt out and delete.",
                                forms: [FormSnapshot(action: url, method: "post", fields: [FormField(type: "text", name: "first", label: "First"), FormField(type: "email", name: "email", label: "Email")], hasSubmit: true)])
        default: return PageSnapshot(url: url, status: 404, title: "Page not found", text: "Nothing here.")
        }
    }
}
#endif
