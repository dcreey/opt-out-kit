import SwiftUI
import MessageUI
import WebKit
import OptOutKitCore

@main
struct OptOutKitApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() { Keyboard.install() }

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
                .onOpenURL { if let link = AppModel.sharedLink(in: $0) { model.incomingLink = link } }
                .task { CheckScheduler.register(model: model) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.appDidEnterBackground() }
            if phase == .active { model.appDidBecomeActive() }
            guard phase == .active, !ProcessInfo.processInfo.arguments.contains("-uitest-reset") else { return }
            Task { await model.runDueChecks(); await model.runDueAutomation() }
            CheckScheduler.schedule()
        }
    }
}

/// Holds the broker queue and everyone the app runs opt-outs for.
/// The household is one encrypted file on the device; the key lives in the Keychain (KeychainKey.swift).
/// Features switched off for now. Other people's profiles (family) are hidden until they are ready again.
enum Features { static let otherProfiles = false }

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var brokers: [Broker] = [] { didSet { planCache = nil } }
    /// Every profiled site, including those with no hand-written flow yet.
    @Published private(set) var directory: [DirectoryEntry] = [] { didSet { planCache = nil } }
    /// Government and industry services that send one request to many brokers at once (California DROP). See docs/PLATFORMS.md.
    @Published private(set) var platforms: [Platform] = [] { didSet { planCache = nil } }
    /// What each state requires of data brokers and gives its residents, and the counts from the registries we pull.
    @Published private(set) var jurisdictions: [Jurisdiction] = []
    @Published private(set) var registrySummary: RegistrySummary?
    /// Paragraphs of terms text a person has (or has not yet) reviewed. Ships with none reviewed, so nothing is ever accepted
    /// for anyone until a reviewer marks paragraphs and the person turns this on. See docs/TERMS.md.
    @Published private(set) var termsLibrary: TermsLibrary?
    @Published private(set) var household = Household() {
        // Only a change to the people or their progress changes the plan; the email address and settings do not, and rebuilding the plan for
        // every site is what made typing in the email box slow.
        didSet { if oldValue.people != household.people || oldValue.progress != household.progress { planCache = nil } }
    }
    @Published private(set) var selectedID: UUID { didSet { planCache = nil } }
    @Published private var regionTick = 0 { didSet { planCache = nil } }
    @Published var loadError: String?
    /// Set when saved data exists but cannot be opened. Saving is paused so it is never overwritten by accident.
    @Published private(set) var storageProblem: String?

    @Published private(set) var pending: Pending = .nothing
    @Published private(set) var isChecking = false
    /// Last automatic opt-out run per person, in memory. What was actually sent is also saved in each person's progress.
    @Published private(set) var optOutRun: [UUID: [AutoOptOutRow]] = [:]
    @Published private(set) var autoBusy: String? {
        // A run only goes on while the app is in front, so the screen is kept awake for it.
        didSet { UIApplication.shared.isIdleTimerDisabled = autoBusy != nil }
    }
    /// Set when the app is about to be suspended: the run stops after the site it is on, and carries on the next time the app is open.
    private(set) var autoStopRequested = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// iOS 26+: the system-sanctioned background run for the current opt-out run (a `ContinuedRun`), when iOS accepted it.
    private var continuedRun: Any?
    private var continuedGranted: Bool { if #available(iOS 26.0, *) { return (continuedRun as? ContinuedRun)?.isGranted ?? false } else { return false } }
    /// While the weekly opt-out is running: how many sites it has been through, of how many.
    @Published private(set) var autoProgress: (done: Int, total: Int)?
    /// Set when an opt-out run finishes, so the result is shown right away: all sent, or which sites need the person.
    @Published var runReport: RunReport?
    /// Latest "where am I listed" scan per person. Kept in memory only: it is a snapshot, not a record.
    @Published private(set) var exposure: [UUID: [ScanResult]] = [:]
    @Published private(set) var scanProgress: (done: Int, total: Int)?

    private let store: HouseholdStore
    /// Screenshots of what each site showed when an automatic opt-out finished, sealed with the household key.
    let evidence: EvidenceStore
    private let defaults: UserDefaults
    private let catalog: [Announcement]
    private static let seenKey = "announcement.lastSeen"
    private static let languageKey = "appLanguage"

    /// The languages the app is translated into, each named in itself.
    static let languages: [(code: String, name: String)] = [("en", "English"), ("fr", "Français"), ("es", "Español"), ("de", "Deutsch")]

    /// The language shown. It starts as the device's language when the app has it, else English, and the person can change it.
    @Published private(set) var language = "en"

    var locale: Locale { Locale(identifier: language) }

    func setLanguage(_ code: String) {
        guard Self.languages.contains(where: { $0.code == code }) else { return }
        language = code
        L10n.language = code; Loc.language = code
        planCache = nil
        defaults.set(code, forKey: Self.languageKey)
    }

    private static func initialLanguage(_ defaults: UserDefaults) -> String {
        if let saved = defaults.string(forKey: languageKey), languages.contains(where: { $0.code == saved }) { return saved }
        for preferred in Locale.preferredLanguages {
            let base = String(preferred.split(separator: "-").first ?? "")
            if languages.contains(where: { $0.code == base }) { return base }
        }
        return "en"
    }

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
         platformsURL: URL? = Bundle.main.url(forResource: "platforms", withExtension: nil),
         jurisdictionsURL: URL? = Bundle.main.url(forResource: "jurisdictions", withExtension: nil),
         registrySummaryURL: URL? = Bundle.main.url(forResource: "summary", withExtension: "json"),
         defaults: UserDefaults = .standard,
         catalog: [Announcement] = AnnouncementCatalog.all) {
        self.store = store
        self.evidence = EvidenceStore(directory: store.url.deletingPathExtension().appendingPathExtension("evidence"), keys: store.keyProvider)
        self.defaults = defaults
        self.catalog = catalog
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-uitest-reset") {
            defaults.removeObject(forKey: Self.languageKey)
            for id in CoachGuide.allIDs { defaults.set(!args.contains("-uitest-coach"), forKey: "coach.\(id)") }
        }
        let initial = Self.initialLanguage(defaults)
        language = initial; L10n.language = initial; Loc.language = initial
        if args.contains("-uitest-reset") {
            try? store.erase()
            try? FileManager.default.removeItem(at: evidence.directory)
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
            problem = Loc.f("Your saved profiles could not be opened on this device (%@). They are untouched.", error)
        }
        if loaded.people.isEmpty { loaded.add(Person(displayName: "Me", relationship: .me)) }
        household = loaded
        selectedID = loaded.people[0].id
        storageProblem = problem
        if let directoryURL { directory = ((try? Registry.loadDirectory(directoryURL)) ?? []).filter { $0.excluded == nil } }       // excluded sites are never shown
        if let jurisdictionsURL { jurisdictions = (try? JurisdictionLoader.load(directory: jurisdictionsURL)) ?? [] }
        if let registrySummaryURL { registrySummary = JurisdictionLoader.loadSummary(registrySummaryURL) }
        if let platformsURL { platforms = (try? PlatformLoader.load(directory: platformsURL)) ?? [] }
        if let termsLibraryURL { termsLibrary = try? TermsLibrary.load(termsLibraryURL) }
        do {
            guard let brokersDirectory else { throw CocoaError(.fileNoSuchFile) }
            brokers = try Registry.load(directory: brokersDirectory)
        } catch {
            loadError = Loc.f("Could not load the broker registry: %@", error)
        }
        #if DEBUG
        // Simulator work: `-reset-daily` forgets today's choice and the once-a-day screens, as if it were a new day.
        if args.contains("-reset-daily") { for k in ["daily.themes", "daily.day", "daily.batches", "summary.day", "followup.explained", "emaillinks.explained"] { defaults.removeObject(forKey: k) } }
        // A complete made-up profile, so screens that need one can be looked at without typing.
        if args.contains("-uitest-seed-profile"), var me = household.people.first(where: { $0.relationship == .me }) {
            me.names = [NameEntry(kind: .legal, name: "Pat Example")]
            me.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")]
            me.birthdate = "1985-03-14"          // a complete profile includes the birthdate
            household.update(me)
            household.setContactEmail("pat@example.com")
            household.updateAuto { $0.decidedAt = Date() }
        }
        #endif
    }

    #if DEBUG
    /// Launched with `-export-evidence` (simulator work only): also writes each screenshot, unsealed, to Documents/evidence-export so a
    /// whole run can be reviewed from outside the app. Never present in a release build.
    nonisolated static func exportForReview(_ domain: String, _ jpeg: Data) {
        guard ProcessInfo.processInfo.arguments.contains("-export-evidence"),
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent("evidence-export")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? jpeg.write(to: dir.appendingPathComponent(domain + ".jpg"))
    }
    #else
    nonisolated static func exportForReview(_ domain: String, _ jpeg: Data) {}
    #endif

    #if DEBUG
    nonisolated static func exportResults(_ rows: [(String, String)]) {
        guard ProcessInfo.processInfo.arguments.contains("-export-evidence"),
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent("evidence-export")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = rows.map { "\($0.0)\t\($0.1)" }.joined(separator: "\n")
        try? text.write(to: dir.appendingPathComponent("results.tsv"), atomically: true, encoding: .utf8)
    }
    #else
    nonisolated static func exportResults(_ rows: [(String, String)]) {}
    #endif

    #if DEBUG
    /// For looking at the result screens: runs the automatic opt-out against the fake submitter at launch.
    func runDemoOptOut() async {
        guard let me = people.first(where: { $0.relationship == .me }) else { return }
        // `-continued-demo`: the real run path (so the iOS 26 background run is requested), with the fake submitter, a pause per site.
        if ProcessInfo.processInfo.arguments.contains("-continued-demo") { await runAutoOptOut(for: me); return }
        await runAutoOptOut(for: me, submitter: FakeSubmitter())
    }
    #endif

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

    // MARK: Platforms (California DROP and the like)

    /// Platforms the selected person may use, with the sites each one reaches listed on its walkthrough.
    var platformQueue: [Broker] {
        guard let person = selectedPerson else { return [] }
        return platforms.filter { $0.live && $0.eligible(person, ownerState: household.ownerState) }.map(walkthrough)
    }

    func walkthrough(_ platform: Platform) -> Broker {
        var b = platform.walkthrough
        b.covers = platform.coveredDomains
        return b
    }

    func platform(forWalkthrough id: String) -> Platform? { platforms.first { $0.id == id } }

    /// The state the owner chose in the walkthrough (two-letter code), until their profile has a current address.
    var ownerState: String? { household.ownerState }
    func setOwnerState(_ code: String?) { household.setOwnerState(code); save() }

    /// The state whose rules apply to the owner: their current address if they have one, else what they chose in the walkthrough.
    var ownerStateCode: String? {
        if let me = household.people.first(where: { $0.relationship == .me }), let state = me.currentAddress?.state,
           let name = USStates.name(for: state), let code = USStates.code(for: name) { return code }
        return household.ownerState
    }

    /// Whether the person chose California (or their address is there): only then is the California DROP link shown in Settings.
    var showsCaliforniaDrop: Bool { ownerCountry == "US" && ownerStateCode == "CA" }

    /// A US state's rules, by its two-letter code.
    func jurisdiction(code: String) -> Jurisdiction? { jurisdictions.first { $0.id == "us-" + code.lowercased() } }
    func jurisdiction(id: String) -> Jurisdiction? { jurisdictions.first { $0.id == id } }

    // MARK: Where the owner lives

    /// The country the owner chose, else the device's region when the app knows it.
    var ownerCountry: String? {
        if let chosen = household.ownerCountry { return chosen }
        let region = Locale.current.region?.identifier
        return region.flatMap { r in r == "US" || jurisdictions.contains { $0.kind == "country" && $0.code == r } ? r : nil }
    }

    /// Whether the person picked their place themselves (not just the device's region), so a walkthrough shown again does not ask them to read its rules again.
    var placeChosenExplicitly: Bool { household.ownerCountry != nil && (household.ownerCountry != "US" || household.ownerState != nil) }

    func setOwnerCountry(_ code: String?) { household.setOwnerCountry(code); save() }

    /// Every place the app has rules for as a country, by name in the chosen language, plus the United States.
    var countryOptions: [(code: String, name: String)] {
        var items = jurisdictions.filter { $0.kind == "country" }.map { (code: $0.code, name: $0.displayName) }
        items.append((code: "US", name: Locale(identifier: language).localizedString(forRegionCode: "US") ?? "United States"))
        return items.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// The rules that apply to the owner: their state if they live in the US, else their country, else nothing yet.
    var ownerJurisdiction: Jurisdiction? {
        switch ownerCountry {
        case "US": return ownerStateCode.flatMap { jurisdiction(code: $0) }
        case .some(let c) where c != "OTHER": return jurisdictions.first { $0.kind == "country" && $0.code == c }
        default: return nil
        }
    }

    /// What the owner's state does for them, in plain words, for the walkthrough and About.
    func statements(for jurisdiction: Jurisdiction) -> [JurisdictionStatement] {
        jurisdiction.statements(summary: registrySummary, platforms: platforms, others: jurisdictions)
    }

    /// The platform that already covers this site for the selected person, and until when asking the site directly is held off.
    /// `until` is nil while the person has not submitted that platform's request yet.
    func platformCover(for entry: DirectoryEntry) -> (platform: Platform, coverage: Platform.Coverage, until: Date?)? {
        guard let person = selectedPerson else { return nil }
        for p in platforms where p.live && p.eligible(person, ownerState: household.ownerState) {
            if let c = p.covers(domain: entry.domain) {
                return (p, c, household.progress(for: person.id).doneAt[p.id].map(p.holdUntil))
            }
        }
        return nil
    }

    /// A group of sites one platform request handles for the selected person. They are shown once, together, and are not separate work.
    struct PlatformGroup: Identifiable {
        let platform: Platform
        let brokers: [Broker]
        let entries: [DirectoryEntry]
        var id: String { platform.id }
        var count: Int { brokers.count + entries.count }
    }

    func isHandledByPlatform(_ entry: DirectoryEntry) -> Bool { platformCover(for: entry) != nil }

    /// A hand-written flow is handled when its own site (or any site it clears) is covered.
    func isHandledByPlatform(_ broker: Broker) -> Bool {
        if let e = Directory.entry(for: broker, in: directory), isHandledByPlatform(e) { return true }
        return false
    }

    /// Every site we track, each shown once in the Sites list (some as part of another site's request).
    var totalSites: Int { Set(plan.flatMap { $0.tasks.flatMap(\.domains) }).count + closedSites.count + lockedSites.count }

    /// Sites that no longer respond, with the evidence. They are not tasks: there is nothing left to opt out of.
    /// Sites with no route to opt out yet. They wait here until a form, page or address is found for them.
    var lockedSites: [DirectoryEntry] { OptOutPlan.locked(plan, entries: directory) }

    /// Every directory entry by its domain, for looking a task's sites up.
    var entryByDomain: [String: DirectoryEntry] { Dictionary(directory.map { ($0.domain, $0) }, uniquingKeysWith: { a, _ in a }) }

    var closedSites: [DirectoryEntry] { directory.filter { $0.closed != nil }.sorted { $0.domain < $1.domain } }

    // MARK: First-visit guides

    /// Short "how this works" guides shown once, the first time a person reaches a kind of screen. UI tests start with them already
    /// seen unless they pass `-uitest-coach`.
    func shouldCoach(_ id: String) -> Bool { !defaults.bool(forKey: "coach.\(id)") }
    func didCoach(_ id: String) { defaults.set(true, forKey: "coach.\(id)") }
    func resetCoaching() { for id in CoachGuide.allIDs { defaults.removeObject(forKey: "coach.\(id)") } }

    // MARK: The plan

    /// Two-letter codes of the US states that count as local for the selected person: where they live and where they have lived.
    var localStates: Set<String> {
        var out = Set<String>()
        if let code = ownerStateCode { out.insert(code) }
        for a in selectedPerson?.addresses ?? [] { if let c = USStates.code(for: a.state) ?? (a.state.count == 2 ? a.state.uppercased() : nil) { out.insert(c) } }
        return out
    }

    /// Whether brokers registered in some state count as being in the person's country (only US states publish registries so far).
    var countryHasRegistries: Bool { (ownerCountry ?? "US") == "US" }

    /// The ranked queue: official service, then the app's own automatic run, then semi-automated, then manual, nearest first.
    var queue: [QueueBand] { builtPlan().queue }

    /// The plan and its ranked queue are built from every site, so they are kept until something they depend on changes (the profile,
    /// progress, language or data). Rebuilding them on every redraw made typing in the search box lag.
    private var planCache: (plan: [PlanStep], queue: [QueueBand])?

    private func builtPlan() -> (plan: [PlanStep], queue: [QueueBand]) {
        if let planCache { return planCache }
        let plan = buildPlan(for: selectedPerson)
        let built = (plan, OptOutPlan.queue(plan, local: localStates, countryHasRegistries: countryHasRegistries))
        planCache = built
        return built
    }

    // MARK: Regions

    private func otherRegionsKey(_ id: UUID) -> String { "regions.other.\(id.uuidString)" }

    /// Whether this person asked to see the sites that do not reach their country too (off until they say so).
    func includesOtherRegions(for id: UUID? = nil) -> Bool { _ = regionTick; return defaults.bool(forKey: otherRegionsKey(id ?? selectedID)) }
    func setIncludeOtherRegions(_ on: Bool) { defaults.set(on, forKey: otherRegionsKey(selectedID)); regionTick += 1 }

    /// The sites that collect data about people in the owner's country, and those that do not (the two always add up to every open site).
    var regionSplit: (inRegion: [DirectoryEntry], elsewhere: [DirectoryEntry]) { Regions.partition(directory, country: ownerCountry) }

    /// The sites the plan and every count work from for this person: their own region, plus the others once they ask.
    private func scopedDirectory(for person: Person?) -> [DirectoryEntry] {
        let split = regionSplit
        return split.elsewhere.isEmpty || (person.map { includesOtherRegions(for: $0.id) } ?? false) ? directory : split.inRegion
    }

    /// True when everything in the person's own region is done and sites elsewhere are waiting, so we can ask whether to carry on.
    var offerOtherRegions: Bool {
        !includesOtherRegions() && !regionSplit.elsewhere.isEmpty && remainingKinds.isEmpty && activitySummary.sites > 0
    }

    /// The plan for any one person (the selected one is cached by `plan`).
    func buildPlan(for person: Person?) -> [PlanStep] {
        let eligible: [Platform] = person.map { p in platforms.filter { $0.live && $0.eligible(p, ownerState: household.ownerState) } } ?? []
        return OptOutPlan.build(entries: scopedDirectory(for: person).filter { $0.closed == nil }, brokers: brokers, platforms: eligible,
                                classifyEntry: { method(for: $0, person: person) }, classifyBroker: { OptOutMethods.classify($0, in: directory) })
    }

    /// The sites the app opts a person out of by itself: exactly the ones in the plan's automatic task, so the count the person is
    /// shown is the number the run works through.
    func automaticDomains(for person: Person) -> Set<String> {
        let steps = person.id == selectedID ? plan : buildPlan(for: person)
        return Set(steps.flatMap(\.tasks).filter { $0.kind == .automatic }.flatMap(\.domains))
    }

    /// The ordered steps for the selected person: their official removal service first, then ours, each site once.
    var plan: [PlanStep] { builtPlan().plan }

    /// Whether the selected person has already done what this task asks.
    func isDone(_ task: PlanTask) -> Bool {
        switch task.kind {
        case .platform(let id): return progress.isDone(id)
        case .flow(let id): return brokers.first { $0.id == id }.map { household.summary(for: $0).isFinished } ?? false
        case .site(let id): return directory.first(where: { $0.id == id })?.isCurrent(attempts: progress.optOutAttempts) ?? (progress.optOutAttempts[id]?.contains(where: \.wasSubmitted) ?? false)
        case .verify:
            let ids = Set(directory.filter { task.domains.contains($0.domain) }.map(\.id))
            return !ids.isEmpty && ids.allSatisfy { progress.optOutAttempts[$0]?.contains(where: \.wasSubmitted) ?? false }
        case .emails:
            let ids = Set(directory.filter { task.domains.contains($0.domain) }.map(\.id))
            return !ids.isEmpty && ids.allSatisfy { wasEmailed($0) }
        case .automatic:
            // Done once every site has gone through this period (the next period starts it afresh).
            if let tally = currentPeriodTally, tally.total > 0 { return tally.complete }
            let byDomain = Dictionary(directory.map { ($0.domain, $0.id) }, uniquingKeysWith: { a, _ in a })
            return !task.domains.isEmpty && task.domains.allSatisfy { d in byDomain[d].map { progress.optOutAttempts[$0]?.contains(where: \.wasSubmitted) ?? false } ?? true }
        }
    }

    /// The hand-written flows that are real work for the selected person: not the ones a platform request already handles.
    var queueBrokers: [Broker] { brokers.filter { !isHandledByPlatform($0) } }

    /// Directory sites that are real work: no hand-written flow, and no platform request handling them.
    var workSites: [DirectoryEntry] { unguidedSites.filter { !isHandledByPlatform($0) } }

    /// Official one-request platforms come first (a state or country's own removal service), in the order they are loaded. A site
    /// goes in the first group that handles it and in no later one, so two platforms never list the same site.
    var platformGroups: [PlatformGroup] {
        guard let person = selectedPerson else { return [] }
        var claimed = Set<String>()
        return platforms.filter { $0.live && $0.eligible(person, ownerState: household.ownerState) }.compactMap { p in
            let entries = unguidedSites.filter { !claimed.contains($0.domain) && p.covers(domain: $0.domain) != nil }
            let flows = brokers.filter { b in
                guard let e = Directory.entry(for: b, in: directory) else { return false }
                return !claimed.contains(e.domain) && p.covers(domain: e.domain) != nil
            }
            claimed.formUnion(entries.map(\.domain))
            claimed.formUnion(flows.compactMap { Directory.entry(for: $0, in: directory)?.domain })
            return entries.isEmpty && flows.isEmpty ? nil : PlatformGroup(platform: p, brokers: flows, entries: entries)
        }
    }

    /// The method group a hand-written flow belongs to, by the same measured rules as every other site.
    func method(for broker: Broker) -> OptOutMethod { OptOutMethods.classify(broker, in: directory).method }

    /// Sites to leave alone for this person because a platform request already reaches them, by site id. Before they have submitted it
    /// the hold has no end (`distantFuture`): the one request comes first, and asking each site as well would be the same work twice.
    func holds(for person: Person, now: Date = Date()) -> [String: PlatformHold] {
        var out: [String: PlatformHold] = [:]
        let progress = household.progress(for: person.id)
        for p in platforms where p.live && p.eligible(person, ownerState: household.ownerState) {
            let until: Date
            if let submitted = progress.doneAt[p.id] {
                until = p.holdUntil(submitted: submitted)
                guard now < until else { continue }          // the hold ended: ask the sites directly again
            } else { until = .distantFuture }
            for e in directory where p.covers(domain: e.domain) != nil && out[e.id] == nil { out[e.id] = PlatformHold(name: p.shortName, until: until) }
        }
        return out
    }

    // MARK: One email for every form

    /// The address the person gave, as typed. Empty until they have given one.
    var contactEmail: String { household.contactEmail ?? "" }
    /// What goes into forms (Gmail addresses carry +optoutkit), or nil until a valid address has been given.
    var formEmail: String? { household.formEmail }
    /// What "My data" in the page menu of every flow offers to copy.
    var pageDetails: [DetailGroup] { selectedPerson.map { DetailChoices.groups(for: $0, email: formEmail) } ?? [] }

    func setContactEmail(_ email: String) {
        household.setContactEmail(email)
        save()
    }

    /// The person as forms see them: the household's one email address replaces any per-profile address.
    func formPerson(_ person: Person) -> Person {
        guard let email = household.formEmail else { return person }
        var p = person
        p.emails = [email]
        return p
    }

    /// Whether a profile has everything automatic work needs: legal name, current address and the household's email.
    func isReady(_ person: Person) -> Bool { person.isComplete && household.formEmail != nil }

    var missingForSelected: [String] {
        guard let p = selectedPerson else { return [] }
        return p.missingRequiredDetails + (household.formEmail == nil ? [L10n.noun("Email address")] : [])
    }

    // MARK: Profile gate: nothing runs until the person's current address is in

    /// True while the "finish your profile" sheet is showing.
    @Published var showProfileGate = false
    /// A link shared to Exnay from another app (exnay://link?u=…): the Email links tab loads it.
    @Published var incomingLink: String?

    /// The web address inside an exnay://link?u=… address, https only.
    static func sharedLink(in url: URL) -> String? {
        guard url.scheme == "exnay", url.host == "link",
              let u = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "u" })?.value,
              let link = URL(string: u), ["https", "http"].contains(link.scheme?.lowercased() ?? "") else { return nil }
        return u
    }
    private var afterProfile: (() -> Void)?

    /// Runs `action` if the selected person has their legal name, current address and the household email; otherwise asks for them
    /// first (and prompts for previous addresses) and runs `action` once they are in. Every way of opting someone out goes through this.
    func requireProfile(_ action: @escaping () -> Void) {
        if let p = selectedPerson, isReady(p) { action(); return }
        afterProfile = action
        showProfileGate = true
    }

    /// The gate was finished: close it and carry on with what the person was doing.
    func profileGateFinished(completed: Bool) {
        showProfileGate = false
        let next = afterProfile; afterProfile = nil
        if completed { next?(); Task { await runDueAutomation() } }
    }

    /// Why nothing automatic runs for the selected person yet: a profile without its legal name and current address.
    var incompleteReason: String? {
        let missing = missingForSelected
        guard let p = selectedPerson, !missing.isEmpty else { return nil }
        return Loc.f("Add %@'s %@ to start.", p.displayName, missing.joined(separator: ", "))
    }

    /// Why searching is off for the selected person, or nil when it is allowed. Minors and public figures are never searched.
    var searchBlockedReason: String? {
        if let incomplete = incompleteReason { return incomplete }
        guard let p = selectedPerson, !p.canBeSearched() else { return nil }
        let why = p.isPublicFigure ? "a public figure" : "under 18"
        return Loc.f("Searches are off for %@ (%@). Several sites' terms don't allow searching for minors, public officials or celebrities. Opt-out requests still work.", p.displayName, why)
    }

    // MARK: Automatic protection: a daily scan and a weekly opt-out, switched on by the person at first use

    struct AutoOptOutRow: Identifiable, Equatable { let id: String; let domain: String; let result: AutoOptOutResult }

    var autoSettings: AutoSettings { household.autoSettings }
    /// Whether the automatic opt-out has begun (or run before): the "let the app do these for you" card is then replaced by its status.
    var autoOptOutStarted: Bool { household.autoSettings.lastOptOut != nil || autoBusy == "optout" }

    /// The person's answer to the first-run question, or a later change in Settings.
    /// Whether the account owner allowed "I am this person" boxes to be ticked for them. Never applies to family profiles.
    /// How this site gets opted out for the selected person, including what real page loads and past sends have shown.
    func method(for entry: DirectoryEntry) -> MethodVerdict { method(for: entry, person: selectedPerson) }

    /// How this site gets opted out for one person. What the last automatic try showed counts: a check moves the site to
    /// semi-automated, a failure or refusal to a guide.
    func method(for entry: DirectoryEntry, person: Person?) -> MethodVerdict {
        let last = person.flatMap { household.progress(for: $0.id).optOutAttempts[entry.id]?.last?.outcome }
        let verdict = OptOutMethods.classify(resolved(entry), confirmingIdentity: person?.mayConfirmOwnIdentity() ?? false, challengedBefore: last == "challenged",
                                             failedBefore: last == "failed" || last == "rejected")
        return verdict
    }
    var confirmingIdentityForSelected: Bool { selectedPerson?.mayConfirmOwnIdentity() ?? false }


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

    /// UI tests that fake sending have no site to be polite to, so the pause between sites is skipped.
    private static var usesFakeSubmitter: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uitest-fake-submit")
        #else
        false
        #endif
    }

    private func makeSubmitter(for person: Person? = nil, advertisingID: String? = nil) -> FormSubmitter {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-fake-submit") { return FakeSubmitter() }
        #endif
        return WebFormSubmitter(person: person, advertisingID: advertisingID)
    }

    /// A real opt-out run begins: written down as in progress (so a cut-off run is carried on at the next launch), the screen kept awake, and on iOS 26 the
    /// system asked to keep it going while the person uses another app.
    private func beginOptOutRun(total: Int, useContinued: Bool) {
        autoBusy = "optout"; autoStopRequested = false
        // Periods (months) are counted from the first run; an earlier send by hand counts as the start so nothing already done is lost from the tally.
        let earliest = people.compactMap { household.progress(for: $0.id).optOutAttempts.values.flatMap { $0 }.filter(\.wasSubmitted).map(\.date).min() }.min()
        if household.autoSettings.periodAnchor == nil { household.updateAuto { $0.periodAnchor = min(earliest ?? Date(), Date()) } }
        household.updateAuto { $0.optOutResumePending = true }; save()
        if #available(iOS 26.0, *), useContinued {
            let run = ContinuedRun()
            if run.start(total: max(total, 1), onExpire: { [weak self] in
                // iOS ended the background run: stop after this site (it resumes on reopen), and say so.
                self?.autoStopRequested = true; CheckScheduler.notifyPaused()
            }) { continuedRun = run }
        }
    }

    /// The run is over. One that stopped early (the app went to the background) stays pending; one that went through every site is finished.
    private func endOptOutRun(interrupted: Bool) {
        autoBusy = nil; autoProgress = nil
        if !interrupted { household.updateAuto { $0.optOutResumePending = nil } }
        if #available(iOS 26.0, *) { (continuedRun as? ContinuedRun)?.finish(success: !interrupted) }
        continuedRun = nil
        save(); endBackgroundTime()
    }

    // MARK: Run periods

    /// The current period of the automatic run (a month when it runs monthly), once a first run has set its start.
    func runPeriod(now: Date = Date()) -> RunPeriod? {
        autoSettings.periodAnchor.map { RunPeriod.containing(now, anchor: $0) }
    }

    /// The sites the automatic run handles for a person, in name order.
    /// The sites the automatic run handles for a person this period, in name order: those it handles now, and those it took on earlier in the
    /// period that have since moved to another group because they did not go through (they stay on the list, unchecked).
    func automaticSites(for person: Person, now: Date = Date()) -> [DirectoryEntry] {
        let domains = automaticDomains(for: person)
        let kept = Set(autoSettings.periodTargetIDs(person: person.id.uuidString))
        return directory.filter { domains.contains($0.domain) || kept.contains($0.id) }.sorted { $0.domain < $1.domain }
    }

    /// How many automatic sites went through this period, and every earlier period back to the first run (current first).
    func periodHistory(for person: Person, now: Date = Date()) -> [PeriodTally] {
        guard let anchor = autoSettings.periodAnchor else { return [] }
        return RunPeriods.history(anchor: anchor, now: now, siteIDs: automaticSites(for: person).map(\.id), attempts: household.progress(for: person.id).optOutAttempts)
    }

    /// This period's tally for the selected person, or nil before the first run has set the period's start.
    var currentPeriodTally: PeriodTally? { selectedPerson.flatMap { periodHistory(for: $0).first } }

    /// One automatic site's standing in the current period, for the status page's checklist.
    struct PeriodSiteRow: Identifiable, Equatable {
        let id: String
        let domain: String
        let handledOn: Date?          // when it went through in this period; nil when it has not
        let note: String?             // why not, from the latest attempt that did not go through
        var handled: Bool { handledOn != nil }
    }

    func periodRows(for person: Person, now: Date = Date()) -> [PeriodSiteRow] {
        let attempts = household.progress(for: person.id).optOutAttempts
        let period = runPeriod(now: now)
        return automaticSites(for: person).map { e in
            let list = attempts[e.id] ?? []
            let sentOn = period.flatMap { p in list.filter { $0.wasSubmitted && p.contains($0.date) }.map(\.date).max() }
            var note: String?
            if sentOn == nil, let last = list.filter({ !$0.wasSubmitted && $0.outcome != "emailed" && (period?.contains($0.date) ?? true) }).max(by: { $0.date < $1.date }) {
                note = AppModel.ReviewItem(id: e.id, domain: e.domain, outcome: last.outcome, detail: last.detail, date: last.date, hasScreenshot: false).label
            }
            return PeriodSiteRow(id: e.id, domain: e.domain, handledOn: sentOn, note: note)
        }
    }

    /// One site's result, written down at once (not when the whole run ends), so closing the app never loses a request that was sent.
    func recordAutoResult(_ entry: DirectoryEntry, _ result: AutoOptOutResult, for personID: UUID, dryRun: Bool) {
        guard !dryRun else { return }
        if let attempt = AutoOptOut.attempt(for: result, now: Date()) { household.mutateProgress(for: personID) { $0.recordOptOutAttempt(attempt, site: entry.id) } }
        var rows = optOutRun[personID] ?? []
        rows.removeAll { $0.id == entry.id }
        rows.append(AutoOptOutRow(id: entry.id, domain: entry.domain, result: result))
        optOutRun[personID] = rows
        save()
    }

    /// Lines up the reminders that bring the person back (3 days, a week, a month of no opt-outs, and a streak nudge), aimed at the next kind of broker to go after.
    func refreshReminders() {
        ReminderScheduler.update(summary: activitySummary, target: remainingKinds.first.flatMap { BrokerCategory(rawValue: $0.kind) })
    }

    /// The app left the front: ask iOS for the extra time it gives (about 30 seconds) to finish the site in progress, then stop between sites.
    func appDidEnterBackground() {
        refreshReminders()
        guard autoBusy == "optout", backgroundTask == .invalid else { return }
        // iOS 26 gave the run its own background time (shown as a Live Activity): carry on, the expiry handler stops it if iOS takes the time back.
        if continuedGranted { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "optout-finish-site") { [weak self] in
            Task { @MainActor in self?.autoStopRequested = true; CheckScheduler.notifyPaused(); self?.endBackgroundTime() }
        }
        // Stop after the current site instead of starting another one that iOS would freeze half-way.
        autoStopRequested = true
        NSLog("OptOutRun: background, finishing the current site then stopping")
        CheckScheduler.scheduleResume()
    }

    /// Back in front: if the run was asked to stop, the next due-check (below) carries on with the sites left.
    func appDidBecomeActive() {
        endBackgroundTime()
        refreshReminders()
        // A quick glance away: the run was only asked to stop, so let it go on.
        if autoBusy == "optout" { autoStopRequested = false }
    }

    func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
    }

    /// Sends opt-out requests for one person to every site whose form we found. `dryRun` fills forms but never sends them.
    func runAutoOptOut(for original: Person, dryRun: Bool = false, automaticOnly: Bool = true, submitter: FormSubmitter? = nil, inspector: PageInspector? = nil) async {
        let person = formPerson(original)
        guard storageProblem == nil, isReady(original) else { return }
        // Only the sites in the "done for you" task. Semi-automated and guided sites need the person, so they are never sent in the background.
        var runnable = automaticOnly ? automaticDomains(for: original) : nil
        #if DEBUG
        // Simulator work: `-only-domains a.com,b.com` runs just those sites, whatever group they are in.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-only-domains"), args.indices.contains(i + 1) { runnable = Set(args[i + 1].split(separator: ",").map(String.init)) }
        #endif
        let ownsBusy = autoBusy == nil && !dryRun
        if ownsBusy { beginOptOutRun(total: runnable?.count ?? directory.count, useContinued: submitter == nil) }
        var interrupted = false
        defer { if ownsBusy { endOptOutRun(interrupted: interrupted) } }
        // Only when a form in this run asks for the phone's advertising ID is the person asked (once) for permission to read it.
        var adID: String?
        if submitter == nil, AdvertisingID.isAsked(by: directory.filter { runnable?.contains($0.domain) ?? true }) { adID = await AdvertisingID.current() }
        // The sites this run takes on are remembered for the period, so a site that fails (and so leaves the automatic group) still counts in "of N".
        if !dryRun, let runnable {
            let ids = directory.filter { runnable.contains($0.domain) }.map(\.id)
            household.updateAuto { $0.addPeriodTargets(ids, person: person.id.uuidString) }
        }
        let engine = AutoOptOut(submitter: submitter ?? makeSubmitter(for: person, advertisingID: adID), spacing: submitter == nil && !Self.usesFakeSubmitter ? 2 : 0)
        let now = Date()
        var results = await engine.run(entries: directory.filter { runnable?.contains($0.domain) ?? true }.map(resolved), person: person, progress: household.progress(for: person.id), now: now, dryRun: dryRun, holds: holds(for: person, now: now),
                                   progressCallback: { done, total in Task { @MainActor in self.autoProgress = (done, total); if #available(iOS 26.0, *) { (self.continuedRun as? ContinuedRun)?.report(done: done, total: total) } } },
                                   evidence: { [evidence, personID = original.id] entry, shot in
                                       try? evidence.save(shot, person: personID, site: entry.id)
                                       Self.exportForReview(entry.domain, shot)
                                   },
                                   period: runPeriod(now: now),
                                   onResult: { [weak self] entry, result in await self?.recordAutoResult(entry, result, for: person.id, dryRun: dryRun) },
                                   shouldStop: { [weak self] in await self?.autoStopRequested ?? true })
        interrupted = autoStopRequested && !dryRun
        // A page that has gone is usually a moved link: look for the new one and try that site again, once.
        if !dryRun {
            let gone = results.filter { if case .failed(let why) = $0.1 { return why == FormRun.pageGone } else { return false } }.prefix(10)
            var retry: [DirectoryEntry] = []
            for (entry, _) in gone {
                if let original = directory.first(where: { $0.id == entry.id }), await healLink(for: original, inspector: inspector) != nil { retry.append(resolved(original)) }
            }
            if !retry.isEmpty {
                let again = await engine.run(entries: retry, person: person, progress: household.progress(for: person.id), now: now, dryRun: false, period: runPeriod(now: now),
                                             onResult: { [weak self] entry, result in await self?.recordAutoResult(entry, result, for: person.id, dryRun: false) })
                for (entry, result) in again { if let i = results.firstIndex(where: { $0.0.id == entry.id }) { results[i] = (entry, result) } }
            }
        }
        NSLog("OptOutRun: run returned %d results, interrupted=%d", results.count, interrupted ? 1 : 0)
        optOutRun[person.id] = results.map { AutoOptOutRow(id: $0.0.id, domain: $0.0.domain, result: $0.1) }
        Self.exportResults(results.map { ($0.0.domain, $0.1.label) })
        if !dryRun, !interrupted {
            let report = RunReport(person: original.displayName, rows: optOutRun[person.id] ?? [], personID: original.id)
            household.updateAuto {
                $0.lastOptOut = now
                $0.lastAttempted = report.attempted; $0.lastSent = report.sent; $0.lastNeedYou = report.needYou.count
            }
            if report.attempted > 0 { runReport = report }
        }
        save()
        refreshReminders()
        if !dryRun, !interrupted { CheckScheduler.notifyOptOut(sent: results.filter { if case .submitted = $0.1 { return true } else { return false } }.count,
                                                  needYou: results.filter { if case .needsYou = $0.1 { return true } else { return false } }.count) }
    }

    #if DEBUG
    func resetProgressForTesting() { household.mutateProgress(for: selectedID) { $0.optOutAttempts = [:] } }
    func startPeriodForTesting() { household.updateAuto { $0.periodAnchor = Date().addingTimeInterval(-86_400) } }
        func recordAttemptForTesting(_ attempt: OptOutAttempt, site: String) { household.mutateProgress(for: selectedID) { $0.recordOptOutAttempt(attempt, site: site) } }
    #endif

    // MARK: Today's goals

    private static let batchDayKey = "daily.day", batchCountKey = "daily.batches"

    /// How many batches of 25 the person has taken today (back to 1 each new day).
    var dailyBatches: Int {
        get {
            guard defaults.string(forKey: Self.batchDayKey) == Self.dayString(Date()) else { return 1 }
            return max(1, defaults.integer(forKey: Self.batchCountKey))
        }
        set {
            objectWillChange.send()
            startTodayIfNeeded()
            defaults.set(max(1, newValue), forKey: Self.batchCountKey)
        }
    }

    /// The first change of the day clears what an earlier day left: otherwise setting today's date for one value made the other (the batch count of a
    /// day with several batches) look like it was from today, and a fresh pick brought extra batches of other kinds with it.
    private func startTodayIfNeeded() {
        let today = Self.dayString(Date())
        guard defaults.string(forKey: Self.batchDayKey) != today else { return }
        defaults.set(today, forKey: Self.batchDayKey)
        defaults.set(1, forKey: Self.batchCountKey)
        defaults.set([String](), forKey: Self.themesKey)
    }
    private static let themesKey = "daily.themes"

    /// The kinds of broker the person chose for today's batches, in order. Empty until they choose, and again each new day.
    var dailyThemes: [String] {
        get { defaults.string(forKey: Self.batchDayKey) == Self.dayString(Date()) ? (defaults.stringArray(forKey: Self.themesKey) ?? []) : [] }
        set { objectWillChange.send(); startTodayIfNeeded(); defaults.set(newValue, forKey: Self.themesKey) }
    }

    /// Choose the kind for today's first batch (before anything is finished today).
    func chooseFirstKind(_ id: String) {
        var t = dailyGoals.themes; if t.isEmpty || dailyGoals.verifyDone == 0 { t = [id] } else { t[0] = id }
        dailyThemes = t; dailyBatches = t.count
    }

    /// Take another 25 of a kind the person picks.
    func addBatch(kind id: String) {
        var t = dailyGoals.themes; t.append(id)
        dailyThemes = t; dailyBatches = t.count
    }

    /// How many sites still wait in each kind of broker, for the person to choose from.
    var remainingKinds: [(kind: String, count: Int)] {
        DailyGoals.remainingByKind(queue: OptOutPlan.verifyQueue(plan, entries: directory), entries: directory, attempts: progress.optOutAttempts, parked: progress.parkedSites())
    }

    // MARK: Daily summary

    private static let summaryDayKey = "summary.day"

    /// What the selected person has done so far, for the welcome-back summary.
    var activitySummary: ActivitySummary { ActivitySummary.build(entries: directory, attempts: progress.optOutAttempts) }

    /// True the first time the app is opened each day, once there is something to summarize.
    var shouldShowDailySummary: Bool { defaults.string(forKey: Self.summaryDayKey) != Self.dayString(Date()) && !activitySummary.isEmpty }

    /// True when nothing has been chosen or started today, so the day opens on the question of which kind of broker to tackle.
    var needsKindChoice: Bool { dailyThemes.isEmpty && dailyGoals.verifyDone == 0 && !dailyGoals.verify.isEmpty }

    // MARK: Email follow-ups and pasted links

    /// Sites that were sent but said an email would follow with more to do, oldest first.
    var pendingFollowUps: [(entry: DirectoryEntry, since: Date)] {
        let byID = Dictionary(directory.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return FollowUps.pending(progress.optOutAttempts).compactMap { p in byID[p.id].map { ($0, p.since) } }
    }

    func markFollowUpDone(_ entryID: String) {
        household.mutateProgress(for: selectedID) { $0.recordOptOutAttempt(OptOutAttempt(date: Date(), outcome: "email_done"), site: entryID) }
        save()
    }

    /// A form was sent from a pasted link and the page showed it went through. A site that was waiting on its email just finishes that step; a site that was
    /// not waiting on anything (the person sent it somewhere else, or it was never in the queue) is recorded as sent now, so it counts as done like any other.
    func completeFromLink(_ entryID: String) {
        guard let entry = directory.first(where: { $0.id == entryID }), let me = selectedPerson else { markFollowUpDone(entryID); return }
        if pendingFollowUps.contains(where: { $0.entry.id == entryID }) { markFollowUpDone(entryID) }
        else { recordAssisted(entry, .submitted(awaitingEmail: false), for: me) }
    }

    func checkLink(_ url: URL) -> LinkCheck { LinkCheck.check(url, entries: directory, attempts: progress.optOutAttempts) }

    private static let linkTourKey = "linkfiller.toured"
    var shouldTourLinkFiller: Bool { !defaults.bool(forKey: Self.linkTourKey) }
    func markLinkFillerToured() { defaults.set(true, forKey: Self.linkTourKey) }

    private static let mailAppKey = "mail.app"
    /// The mail app the person chose for every email we prepare. Mail (the system composer) until they pick another.
    var mailApp: MailApp {
        _ = regionTick
        return defaults.string(forKey: Self.mailAppKey).flatMap(MailApp.init(rawValue:)) ?? .mail
    }
    func setMailApp(_ app: MailApp) { defaults.set(app.rawValue, forKey: Self.mailAppKey); regionTick += 1 }
    /// Mail, and each other app on this phone that we know how to open with a message ready.
    var installedMailApps: [MailApp] {
        MailApp.allCases.filter { app in
            if app == .mail { return true }
            guard let scheme = app.probeScheme, let url = URL(string: scheme + "://") else { return false }
            return UIApplication.shared.canOpenURL(url)
        }
    }
    /// True when the message should open in the in-app composer (which tells us whether it was sent) rather than another app.
    var composesInApp: Bool { mailApp == .mail && MFMailComposeViewController.canSendMail() }

    private static let gpcKey = "gpc.setup.done"
    /// Whether the person said they turned on the Global Privacy Control in the browser they use. It is a one-time setting task, not a site: it
    /// is not in the plan, so it never counts toward the day's sites, requests sent or the streak.
    // MARK: Sending for the person

    private static let autoSubmitKey = "autosubmit.default"
    /// Whether the guides press a form's own send button for the person unless they turn that off. On unless the person changes it in Settings.
    var autoSubmitDefault: Bool { _ = regionTick; return defaults.object(forKey: Self.autoSubmitKey) as? Bool ?? true }
    func setAutoSubmitDefault(_ on: Bool) { defaults.set(on, forKey: Self.autoSubmitKey); regionTick += 1 }
    /// The choice made with the checkbox in a guide; it lasts until the app is closed. Nil until the person touches it.
    @Published var autoSubmitSession: Bool?
    var autoSubmit: Bool { autoSubmitSession ?? autoSubmitDefault }

    var gpcSetupDone: Bool { _ = regionTick; return defaults.bool(forKey: Self.gpcKey) }
    func setGPCSetupDone(_ on: Bool) { defaults.set(on, forKey: Self.gpcKey); regionTick += 1 }

    private static let emailLinksKey = "emaillinks.explained"
    /// The first time a request is sent that waits on an email, once: why the email matters and how the Email links tab finishes it.
    var shouldExplainEmailLinks: Bool { !defaults.bool(forKey: Self.emailLinksKey) }
    func markEmailLinksExplained() { defaults.set(true, forKey: Self.emailLinksKey) }
    /// A screen asks for another tab (the explainer's "show me" button).
    @Published var requestedTab: Int?

    private static let followUpKey = "followup.explained"
    /// The first time the person has sent anything, once: why the day ends with an email and what to expect in the inbox.
    var shouldExplainFollowUp: Bool { !defaults.bool(forKey: Self.followUpKey) && activitySummary.sites > 0 }
    func markFollowUpExplained() { defaults.set(true, forKey: Self.followUpKey) }

    /// Requests that have waited on the site's confirmation email longer than sites usually take (45 days), oldest first.
    var overdueFollowUps: [(entry: DirectoryEntry, since: Date)] {
        let byID = Dictionary(directory.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return FollowUps.overdue(progress.optOutAttempts).compactMap { p in byID[p.id].map { ($0, p.since) } }
    }
    var overdueFollowUpCount: Int { FollowUps.overdue(progress.optOutAttempts).count }

    func markDailySummaryShown() { defaults.set(Self.dayString(Date()), forKey: Self.summaryDayKey) }

    private static func dayString(_ d: Date) -> String { let c = Calendar.current.dateComponents([.year, .month, .day], from: d); return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)" }

    /// Today's goals for the selected person: the next 25 semi-automated sites and the email to the same sites.
    var dailyGoals: DailyGoals {
        let queue = OptOutPlan.verifyQueue(plan, entries: directory)
        let attempts = progress.optOutAttempts, parked = progress.parkedSites()
        // Nothing finished today means only the first batch can be real: a second one is taken only after finishing the first. A saved count or list of
        // kinds that says otherwise is left over from a bug (a new day's pick inherited an earlier day's batches) and would fill the day with other kinds.
        let first = DailyGoals.build(queue: queue, entries: directory, attempts: attempts, batches: 1, chosen: Array(dailyThemes.prefix(1)), parked: parked)
        if first.verifyDone == 0 { return first }
        return DailyGoals.build(queue: queue, entries: directory, attempts: attempts, batches: dailyBatches, chosen: dailyThemes, parked: parked)
    }

    /// Sites still waiting for the semi-automated step, and so how many days at 25 a day.
    var verifyRemaining: Int {
        let queued = Set(OptOutPlan.verifyQueue(plan, entries: directory)); let parked = progress.parkedSites(); let ids = Set(directory.filter { queued.contains($0.domain) && !parked.contains($0.id) }.map(\.id))
        let byID = Dictionary(directory.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }); return ids.filter { !(byID[$0]?.isCurrent(attempts: progress.optOutAttempts) ?? false) }.count
    }

    // MARK: Opt-out emails

    func wasEmailed(_ entryID: String) -> Bool {
        progress.optOutAttempts[entryID]?.contains { $0.outcome == "emailed" && Date().timeIntervalSince($0.date) < AutoOptOut.defaultMinInterval * 4 } ?? false
    }

    /// The phone's advertising ID, once read for an email in this run. Never stored.
    private(set) var emailAdID: String?

    /// One company: only the details its form (or its kind of company) needs. Several: the plain request with name, email and address.
    func emailBody(for batch: EmailBatch) -> String {
        guard let p = selectedPerson else { return "" }
        let a = p.currentAddress
        let street = [a?.street, a?.city, [a?.state, a?.zip].compactMap { $0 }.joined(separator: " ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        guard let details = emailDetails(for: batch) else { return batch.body(name: p.legalName, email: formEmail ?? "", address: street, country: p.countryCode) }
        return batch.body(name: p.legalName, email: formEmail ?? "", details: details, address: street, phone: p.phones.first, birthdate: p.birthdate, advertisingID: emailAdID, country: p.countryCode)
    }

    /// What one company's email carries, or nil for a message to several companies.
    func emailDetails(for batch: EmailBatch) -> EmailDetails? {
        guard batch.entryIDs.count == 1, let entry = directory.first(where: { $0.id == batch.entryIDs[0] }) else { return nil }
        return EmailDetails.needs(for: entry)
    }

    /// True when this message wants the advertising ID and the person has not yet been asked, so we explain first.
    func needsAdIDExplained(for batch: EmailBatch) -> Bool {
        emailDetails(for: batch)?.advertisingID == true && AdvertisingID.status == .notDetermined
    }

    /// The person chose to send without the advertising ID.
    func skipAdID() { emailAdID = nil }

    /// Reads the advertising ID for a message that wants it (Apple's prompt shows on the first time). Without permission the message goes without it.
    func loadAdID(for batch: EmailBatch) async {
        emailAdID = nil
        guard emailDetails(for: batch)?.advertisingID == true else { return }
        emailAdID = await AdvertisingID.current()
    }

    /// Who a message goes to. One company: it is the To address and you are in Bcc for a copy. Many: you are To and every company is in Bcc, so none sees another.
    func recipients(for batch: EmailBatch) -> (to: [String], bcc: [String]) {
        if batch.addresses.count == 1 { return (batch.addresses, [formEmail].compactMap { $0 }) }
        return ([formEmail].compactMap { $0 }, batch.addresses)
    }

    /// The link that opens `app`'s compose screen with the message ready (see `recipients(for:)`).
    func composeURL(for batch: EmailBatch, app: MailApp) -> URL? {
        let r = recipients(for: batch)
        return app.composeURL(to: r.to.joined(separator: ","), bcc: r.bcc, subject: batch.subject, body: emailBody(for: batch))
    }

    /// The person tapped Send on the message: every site it covers is recorded as asked.
    func markEmailed(_ batch: EmailBatch) {
        household.mutateProgress(for: selectedID) { p in
            for id in batch.entryIDs { p.recordOptOutAttempt(OptOutAttempt(date: Date(), outcome: "emailed", detail: batch.address), site: id) }
        }
        save()
    }

    // MARK: Reviewing a run

    /// One site's result from the last run, with whether there is a screenshot to look at.
    struct ReviewItem: Identifiable, Equatable {
        let id: String            // directory entry id
        let domain: String
        let outcome: String       // submitted | submitted_email | challenged | rejected | failed
        let detail: String?
        let date: Date
        let hasScreenshot: Bool
        var worked: Bool { outcome.hasPrefix("submitted") }
        var label: String {
            switch outcome {
            case "submitted": return Loc.t("Sent")
            case "submitted_email": return Loc.t("Sent; confirm the email they sent you")
            case "challenged": return Loc.f("Stopped: %@", detail ?? "")
            case "rejected": return Loc.f("The site refused: %@", detail ?? "")
            default: return Loc.f("No confirmation: %@", detail ?? "")
            }
        }
    }

    /// Every site the last run tried for this person, the ones that need them first. Built from the saved history, so it is still there
    /// after the app is closed.
    func reviewItems(for person: Person) -> [ReviewItem] {
        guard let lastRun = household.autoSettings.lastOptOut else { return [] }
        let attempts = household.progress(for: person.id).optOutAttempts
        let byID = Dictionary(directory.map { ($0.id, $0.domain) }, uniquingKeysWith: { a, _ in a })
        let items: [ReviewItem] = attempts.compactMap { id, list in
            guard let last = list.last, abs(last.date.timeIntervalSince(lastRun)) < 3600, let domain = byID[id] else { return nil }
            return ReviewItem(id: id, domain: domain, outcome: last.outcome, detail: last.detail, date: last.date,
                              hasScreenshot: evidence.exists(person: person.id, site: id))
        }
        return items.sorted { ($0.worked ? 1 : 0, $0.domain) < ($1.worked ? 1 : 0, $1.domain) }
    }

    /// The latest attempt that reached a site, as a review item (for its status page), or nil when none was recorded.
    func reviewItem(entryID id: String, for person: Person) -> ReviewItem? {
        guard let last = household.progress(for: person.id).optOutAttempts[id]?.filter({ $0.outcome != "emailed" }).max(by: { $0.date < $1.date }),
              let domain = directory.first(where: { $0.id == id })?.domain else { return nil }
        return ReviewItem(id: id, domain: domain, outcome: last.outcome, detail: last.detail, date: last.date, hasScreenshot: evidence.exists(person: person.id, site: id))
    }

    func screenshot(for item: ReviewItem, person: Person) -> Data? { evidence.load(person: person.id, site: item.id) }

    /// The person looked at the screenshot and it does not show a finished request: the site is not counted as done and moves to a guide.
    func markLooksWrong(_ item: ReviewItem, for person: Person) {
        household.mutateProgress(for: person.id) { p in
            p.optOutAttempts[item.id, default: []].removeAll { $0.wasSubmitted && abs($0.date.timeIntervalSince(item.date)) < 1 }
            p.recordOptOutAttempt(OptOutAttempt(date: item.date.addingTimeInterval(1), outcome: "failed", detail: "you said the confirmation did not look right"), site: item.id)
        }
        save()
    }

    /// The one way to run the automatic opt-out by hand: it works in the background and only reports the sites that need the person.
    func runAutomaticNow() {
        requireProfile { [self] in
            guard autoBusy == nil, let person = selectedPerson else { return }
            Task { await runAutoOptOut(for: person) }
        }
    }

    /// Sites the person can finish with one tap each: their form is found, their details are on the profile, and nothing was sent
    /// in the last week. The app fills and sends each one once the person has solved its check.
    func assistedItems(for original: Person, now: Date = Date()) -> [AssistedRunner.Item] {
        guard isReady(original) else { return [] }
        let person = formPerson(original)
        let progress = household.progress(for: person.id)
        let holdMap = holds(for: original, now: now)
        return directory.map(resolved).compactMap { entry -> AssistedRunner.Item? in
            guard let form = entry.optOutForm else { return nil }
            let pre = AutoOptOut.precheck(entry: entry, person: person, progress: progress, now: now, hold: holdMap[entry.id])
            // A form that wants the person's own listing: the runner searches the site and has them pick it first.
            if case .needsYou? = pre.result, let plan = pre.plan, FormFiller.needsListing(form), let search = entry.listingSearchURL(for: person) {
                return AssistedRunner.Item(entry: entry, form: form, plan: plan, searchURL: search)
            }
            guard pre.result == nil, let plan = pre.plan else { return nil }
            return AssistedRunner.Item(entry: entry, form: form, plan: plan)
        }
    }

    func makeAssistedDriver() -> AssistedDriver {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-fake-submit") { return FakeAssistedDriver() }
        #endif
        return WebAssistedDriver(person: selectedPerson.map(formPerson), advertisingID: nil, termsPolicy: makeTermsPolicy())
    }

    /// The pages in the "tap to verify" task, ready for the visible runner. A placeholder plan stands in when the stored form's plan is
    /// not usable: the live page decides what is filled.
    func verifyItems(domains: [String], for original: Person) -> [AssistedRunner.Item] {
        guard isReady(original) else { return [] }
        let set = Set(domains), person = formPerson(original)
        let progress = household.progress(for: person.id)
        return directory.map(resolved).compactMap { entry -> AssistedRunner.Item? in
            guard set.contains(entry.domain) else { return nil }
            // No form at all, only an email address: shown one at a time with "no form exists, send an email instead".
            if entry.optOutForm == nil, entry.liveForm?.found != true, entry.contactEmail != nil {
                let page = entry.optOutURL ?? URL(string: "https://\(entry.domain)/")!
                let none = OptOutForm(page: page, method: "post", action: nil, fields: [], hops: 0)
                if progress.optOutAttempts[entry.id]?.contains(where: { $0.wasSubmitted && Date().timeIntervalSince($0.date) < AutoOptOut.defaultMinInterval }) == true { return nil }
                var item = AssistedRunner.Item(entry: entry, form: none, plan: FillPlan(values: [], verdict: .ready)); item.emailOnly = true
                return item
            }
            // A form the crawl could not read but a real page load found: the live page decides what is filled, so a stand-in form is enough.
            guard let form = entry.optOutForm ?? entry.liveForm?.page.flatMap(URL.init(string:)).map({ OptOutForm(page: $0, method: "post", action: nil, fields: [], hops: 1) }) else { return nil }
            // Shown in the person's language when the site offers its opt-out page in it; the original page is the fallback.
            var shown = form, fallback: OptOutForm?
            if let local = Regions.localizedPage(for: entry, language: Loc.language, country: ownerCountry), local != form.page {
                fallback = form
                shown = OptOutForm(page: local, method: form.method, action: nil, fields: [], hops: form.hops)
            }
            if progress.optOutAttempts[entry.id]?.contains(where: { $0.wasSubmitted && Date().timeIntervalSince($0.date) < AutoOptOut.defaultMinInterval }) == true { return nil }
            let plan = AutoOptOut.precheck(entry: entry, person: person, progress: progress, now: Date()).plan ?? FillPlan(values: [], verdict: .ready)
            let search = FormFiller.needsListing(form) ? entry.listingSearchURL(for: person) : nil
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uitest-fake-listing"), entry.domain == "advancedbackgroundchecks.com" {
                return AssistedRunner.Item(entry: entry, form: shown, plan: plan, fallbackForm: fallback, searchURL: URL(string: "https://example.com/search"))
            }
            #endif
            return AssistedRunner.Item(entry: entry, form: shown, plan: plan, fallbackForm: fallback, searchURL: search)
        }
    }

    /// The person reported a problem with a site (broken link, gated by something else, blocked them). Queues leave it alone for a month.
    func reportIssue(_ kind: IssueKind, site: String) {
        household.mutateProgress(for: selectedID) { $0.reportIssue(kind, site: site); $0.skipSite(site, reason: .notWorking) }
        save()
    }

    /// The person says a site is done (they did it another way, or a confirmation was missed). Counts like any request that went through.
    func markSiteDone(_ site: String) {
        household.mutateProgress(for: selectedID) { $0.recordOptOutAttempt(OptOutAttempt(date: Date(), outcome: "submitted", detail: AppModel.markedByHand), site: site) }
        save()
    }
    /// Takes back a "done" the person set by hand (not one the app sent).
    func unmarkSiteDone(_ site: String) {
        household.mutateProgress(for: selectedID) { $0.optOutAttempts[site]?.removeAll { $0.detail == AppModel.markedByHand } }
        save()
    }
    static let markedByHand = "marked done by you"
    func wasMarkedByHand(_ site: String) -> Bool { progress.optOutAttempts[site]?.last?.detail == AppModel.markedByHand }

    // MARK: Skipped sites

    /// Sets a site aside: it leaves today's batch (the next site takes its place) and comes back after a week with a reminder. Skipping it a
    /// second time can be for good.
    func skipSite(_ site: String, forever: Bool = false) {
        household.mutateProgress(for: selectedID) { $0.skipSite(site, reason: .skipped, forever: forever) }
        save()
    }
    func skipCount(_ site: String) -> Int { progress.skipCount(site) }
    func isSkippedForever(_ site: String) -> Bool { progress.isSkippedForever(site) }
    func bringBack(_ site: String) {
        household.mutateProgress(for: selectedID) { $0.unskip(site) }
        save()
    }

    /// Sites set aside and not finished since, with when each returns (nil: for good, or already back).
    var skippedSites: [(entry: DirectoryEntry, skip: SiteSkip, returns: Date?, forever: Bool)] {
        let byID = Dictionary(directory.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let p = progress
        return p.skippedSites().compactMap { id in
            guard let e = byID[id], let skip = p.lastSkip(id) else { return nil }
            return (e, skip, p.skipReturns(id), p.isSkippedForever(id))
        }.sorted { $0.skip.date > $1.skip.date }
    }
    /// How many skipped sites have waited their week and are ready to be tried again.
    var skippedDueCount: Int { progress.skippedDue().count }

    func activeIssue(for site: String) -> SiteIssue? { progress.activeIssue(for: site) }

    // MARK: Healing moved links

    /// The directory entry with any link the app healed on this device swapped in, so every flow uses the working address.
    func resolved(_ entry: DirectoryEntry) -> DirectoryEntry {
        var e = entry
        if let healed = household.healedLink(for: entry.id) { e.optOutForm = healed.form; e.optOutURL = healed.form.page }
        // Someone outside the US is sent to the broker's own site for their country when it has one, and its form is found on the live page.
        if let site = Regions.regionalSite(for: entry, country: ownerCountry), let page = (site.privacyPage ?? site.url) as String?, URL(string: page) != nil {
            e.optOutForm = nil; e.optOutURL = URL(string: page)
            e.liveForm = LiveFormCheck(checked: e.liveForm?.checked ?? "", found: site.hasForm ?? false, page: page, blockers: [])
            e.runCheck = nil
        }
        return e
    }

    func healedLink(for siteID: String) -> HealedLink? { household.healedLink(for: siteID) }

    /// The address to use for a site's opt-out page: a link the app healed on this device, else the recorded one.
    func effectiveURL(for entry: DirectoryEntry) -> URL? {
        // The page in the person's language when the site has one, else the recorded address.
        household.healedLink(for: entry.id)?.form.page ?? Regions.localizedPage(for: entry, language: Loc.language, country: ownerCountry) ?? entry.optOutForm?.page ?? entry.optOutURL
    }
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

    #if DEBUG
    /// Lets a test put its own page behind the guide (for example one that can never send).
    var guidedPageMakerOverride: GuidedPageMaker?
    #endif

    func makeGuidedPageMaker() -> GuidedPageMaker {
        #if DEBUG
        if let override = guidedPageMakerOverride { return override }
        if ProcessInfo.processInfo.arguments.contains("-uitest-fake-guided") { return FakeGuidedPageMaker() }
        #endif
        return WebGuidedPageMaker()
    }

    /// A guided runner for a hand-written broker flow, resuming at the first step not yet done.
    func guidedRunner(for broker: Broker) -> GuidedRunner? {
        guard let selected = selectedPerson, isReady(selected) else { return nil }
        let person = formPerson(selected)
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
        guard let selected = selectedPerson, isReady(selected) else { return nil }
        let person = formPerson(selected)
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
            // A page that would not load is skipped: it leaves today's batch and comes back in a week (the failure is not held against the site's method).
            if case .needsYou(let why) = result, why == AssistedRunner.unloadable || why == AssistedRunner.noForm { p.skipSite(entry.id, reason: .skipped) }
        }
        var rows = optOutRun[person.id] ?? []
        rows.removeAll { $0.id == entry.id }
        rows.append(AutoOptOutRow(id: entry.id, domain: entry.domain, result: result))
        optOutRun[person.id] = rows
        save()
    }

    /// Runs whatever is due: the daily scan and the weekly opt-out, for everyone in the family. Does nothing until the person has said yes.
    func runDueAutomation(now: Date = Date()) async {
        // Not while the person is still filling in their profile: the run would start before they finish adding previous addresses.
        guard storageProblem == nil, autoBusy == nil, !showProfileGate else { return }
        let settings = household.autoSettings
        if settings.scanDue(now: now) {
            autoBusy = "scan"
            for person in people where person.canBeSearched() && isReady(person) { await scanExposure(for: person) }
            household.updateAuto { $0.lastScan = now }
            save()
            autoBusy = nil
        }
        // Due on schedule, or a run that was cut off (the app was closed or suspended) and still has sites left.
        if household.autoSettings.optOutDue(now: now) || household.autoSettings.optOutResumePending == true {
            NSLog("OptOutRun: resuming a run that was cut off (pending=%d)", household.autoSettings.optOutResumePending == true ? 1 : 0)
            beginOptOutRun(total: directory.count, useContinued: true)
            for person in people where isReady(person) { await runAutoOptOut(for: person) }
            endOptOutRun(interrupted: autoStopRequested)
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
        return workSites
            .filter { $0.needsManualCheck && $0.automation != .unreachable && $0.bucket != "registry" }       // marketing and analytics brokers have nothing to look yourself up on
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
        evidence.removeAll(person: id)
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
        try? FileManager.default.removeItem(at: evidence.directory)
        household = Household()
        household.add(Person(displayName: "Me", relationship: .me))
        selectedID = household.people[0].id
        storageProblem = nil
        save()
    }

    /// Encrypting and writing the household takes a moment, so it runs off the main thread, one write at a time and in order. A failure is shown when it comes back.
    private let saveQueue = DispatchQueue(label: "dev.optoutkit.save", qos: .utility)
    /// Waits until every save started so far has been written (saves run in the background). Tests read the file straight after a change.
    func flushSaves() { saveQueue.sync {} }

    private func save() {
        guard storageProblem == nil else { return }
        let snapshot = household, store = store
        saveQueue.async { [weak self] in
            do { try store.save(snapshot) } catch {
                DispatchQueue.main.async { self?.storageProblem = Loc.f("Could not save: %@", error) }
            }
        }
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
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-fake-submit-delay"), args.indices.contains(i + 1), let secs = Double(args[i + 1]) { try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000)) }
        return form.page.absoluteString.count % 2 == 0 ? .submitted(awaitingEmail: true) : .challenged("a bot check")
    }

    /// A drawn stand-in for the page, so the review screens have something to show without loading a site.
    func submitCapturing(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitEvidence {
        let outcome = await submit(form, plan: plan, dryRun: dryRun)
        let text = "\(form.page.host ?? "site")\nFake page after sending"
        let image = await MainActor.run {
            UIGraphicsImageRenderer(size: CGSize(width: 390, height: 800)).image { ctx in
                UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 390, height: 800))
                (text as NSString).draw(in: CGRect(x: 20, y: 300, width: 350, height: 120), withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
            }
        }
        return SubmitEvidence(outcome: outcome, screenshot: image.jpegData(compressionQuality: 0.5))
    }
}
#endif


#if DEBUG
/// UI tests use this so the Solve-and-send screen never loads a real site: each page shows a check for two polls, then sends.
@MainActor
struct FakeAssistedDriver: AssistedDriver {
    func prepare(_ form: OptOutForm, plan: FillPlan) async -> AssistedPage? { FakeAssistedPage() }
    func openSearch(_ url: URL) async -> SearchPage? { FakeSearchPage() }
}

@MainActor
final class FakeSearchPage: SearchPage {
    private let view = WKWebView(frame: .zero)
    var webView: WKWebView? { view }
    init() { view.loadHTMLString("<html><body style='font-family:-apple-system;padding:24px'><h2>Results for Pat Example</h2><p><b>Pat Example</b>, 34<br>Springfield, IL<br>Relatives: Sam Example</p><hr><p><b>Pat Example</b>, 61<br>Portland, OR</p><hr><p><b>Patricia Example</b>, 29<br>Austin, TX</p></body></html>", baseURL: nil) }
    func currentURL() -> URL? { URL(string: "https://example.com/people/pat-example-il") }
    func close() {}
}

@MainActor
final class FakeAssistedPage: AssistedPage {
    private var polls = 0
    private let view = WKWebView(frame: .zero)
    var webView: WKWebView? { view }
    init() { view.loadHTMLString("<html><body style='font-family:-apple-system;padding:24px'><h1>Opt out of example.com</h1><p>Email</p><input value='you@example.com' style='width:100%;font-size:18px'><p>Full name</p><input value='Pat Example' style='width:100%;font-size:18px'><br><br><button style='font-size:18px'>Submit request</button></body></html>", baseURL: nil) }
    // -uitest-fake-hold keeps the check up, so a test can work on the screen without the site sending itself meanwhile.
    func blockers() async -> [AssistedBlocker] { polls += 1; return polls <= (ProcessInfo.processInfo.arguments.contains("-uitest-fake-hold") ? 10_000 : 2) ? [.check("a bot check")] : [] }
    func refill() async {}
    func send() async -> SubmitOutcome { .submitted(awaitingEmail: ProcessInfo.processInfo.arguments.contains("-uitest-fake-email")) }
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
