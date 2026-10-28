import SwiftUI
import WebKit
import OptOutKitCore

// MARK: Pages the runner drives

/// What stands between a prepared form and sending it, which only the person can clear.
enum AssistedBlocker: Equatable { case terms, check(String), certify(String), choose(String) }

/// One site's opt-out page, loaded and filled in, ready to be sent once the person has dealt with any blockers.
@MainActor
protocol AssistedPage: AnyObject {
    func blockers() async -> [AssistedBlocker]
    /// Puts the profile's values back, in case clearing a blocker reloaded the form.
    func refill() async
    func send() async -> SubmitOutcome
    /// What is on screen now, for noticing a confirmation the person caused themselves. Empty in tests.
    func pageText() async -> String
    /// When the page now shows a different privacy form from the one in use (a modal opened, a next step appeared), switches to it and fills it in. True when it did.
    func adoptNewForm() async -> Bool
    func close()
    /// The live web view to show the person, or nil in tests. Reading it changes nothing: `present()` must be called first.
    var webView: WKWebView? { get }
    /// Moves the page's web view out of its hidden window so a screen can show it. Called by the runner, never while a view is drawing.
    func present()
}

extension AssistedPage { func present() {}; func pageText() async -> String { "" }; func adoptNewForm() async -> Bool { false } }

@MainActor
protocol AssistedDriver {
    func prepare(_ form: OptOutForm, plan: FillPlan) async -> AssistedPage?
}

/// The real thing: a web view the person can see and use for the one step only they can do.
@MainActor
struct WebAssistedDriver: AssistedDriver {
    /// Test hook: render this HTML instead of loading the site, so a test can imitate a form and a bot check.
    var htmlOverride: String?
    /// When set, the form is found on the live page and filled from these details (the stored crawl is only a hint).
    var person: Person?
    var advertisingID: String?

    /// What a form looks like, to tell one from another when the page changes under the person.
    static func signature(_ form: LiveForm) -> String { form.fields.filter(\.visible).map { $0.label + "/" + $0.type }.joined(separator: "|") }

    func prepare(_ form: OptOutForm, plan: FillPlan) async -> AssistedPage? {
        let session = WebViewSession.make()
        do {
            if let htmlOverride { try await session.loadHTML(htmlOverride) } else { try await session.load(URLRequest(url: form.page)) }
        } catch { session.close(); return nil }
        await session.settlePage(maxWait: 10)
        _ = await session.denyCookies()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        _ = await session.denyCookies()
        await session.hideConsentOverlays()
        let page = WebAssistedPage(session: session, plan: plan)
        if let person {
            _ = await session.advanceToRequestForm()
            guard let live = LiveFormPicker.pick(await session.discoverFormsDeep(), pageContext: await session.pageContext()) else { session.close(); return nil }
            // Only a form that asks for the phone's advertising ID makes the app ask the person (once) for permission to read it.
            let liveForm = live.asOptOutForm(page: form.page)
            var adID = advertisingID
            if adID == nil, AdvertisingID.isAsked(by: liveForm.fields) { adID = await AdvertisingID.current() }
            let livePlan = FormFiller.plan(for: liveForm, signals: nil, person: person, advertisingID: adID)
            if case .ready = livePlan.verdict { page.useLive(form: live.token, plan: livePlan, ownerMayConfirm: person.mayConfirmOwnIdentity(), stateName: USStates.name(for: person.currentAddress?.state ?? "")) } else { session.close(); return nil }
            page.remember(person: person, advertisingID: adID, page: form.page, signature: Self.signature(live))
        }
        await page.refill()
        await session.scrollChallengeIntoView()
        return page
    }
}

@MainActor
final class WebAssistedPage: AssistedPage {
    private let session: WebViewSession
    private var plan: FillPlan
    private var liveForm: String?
    private var ownerMayConfirm = false
    private var stateName: String?
    private var person: Person?
    private var advertisingID: String?
    private var pageURL: URL?
    private var knownSignature = ""
    private var shown: WKWebView?

    init(session: WebViewSession, plan: FillPlan) { self.session = session; self.plan = plan }

    func useLive(form token: String, plan: FillPlan, ownerMayConfirm: Bool, stateName: String? = nil) { liveForm = token; self.plan = plan; self.ownerMayConfirm = ownerMayConfirm; self.stateName = stateName }

    func remember(person: Person, advertisingID: String?, page: URL, signature: String) { self.person = person; self.advertisingID = advertisingID; pageURL = page; knownSignature = signature }

    func adoptNewForm() async -> Bool {
        guard let person, let pageURL, liveForm != nil else { return false }
        let frameBefore = session.activeFrame
        let forms = await session.discoverForms()
        guard let new = LiveFormPicker.pick(forms, pageContext: await session.pageContext()) else { session.activeFrame = frameBefore; return false }
        let sig = WebAssistedDriver.signature(new)
        if sig == knownSignature { liveForm = new.token; return false }       // the same form, with its marks put on again
        let form = new.asOptOutForm(page: pageURL)
        let livePlan = FormFiller.plan(for: form, signals: nil, person: person, advertisingID: advertisingID)
        guard case .ready = livePlan.verdict else { session.activeFrame = frameBefore; return false }
        liveForm = new.token; plan = livePlan; knownSignature = sig
        // What the person already typed is kept; only empty boxes of the new form are filled.
        _ = await session.fillLive(plan.values, keepExisting: true)
        _ = await session.chooseRequestOptions(form: new.token, ownerMayConfirm: ownerMayConfirm)
        _ = await session.chooseCustomMenus(state: stateName)
        _ = await session.chooseTileButtons()
        return true
    }

    var webView: WKWebView? { shown }
    func present() { if shown == nil { shown = session.presentable() } }

    func blockers() async -> [AssistedBlocker] {
        var out: [AssistedBlocker] = []
        if await session.hasTermsPrompt() { out.append(.terms) }
        if let text = await session.pendingCertification() { out.append(.certify(text)) }
        if let why = await session.visibleChallenge() { out.append(.check(why)) }
        if await session.emptyCodeField() { out.append(.check("a code to type")) }
        // A required menu or box the app had no value for (a state list that does not offer the person's state, a request type): the person picks.
        if let liveForm, let what = await session.emptyRequiredChoice(form: liveForm) { out.append(.choose(what)) }
        return out
    }

    func refill() async {
        if let liveForm {
            _ = await session.fillLive(plan.values)
            _ = await session.chooseRequestOptions(form: liveForm, ownerMayConfirm: ownerMayConfirm)
            _ = await session.chooseCustomMenus(state: stateName)
            _ = await session.chooseTileButtons()
        } else { _ = await session.fillFields(plan.values) }
    }

    func send() async -> SubmitOutcome {
        let before = await session.visibleText()
        let pressed: Bool
        if let liveForm { pressed = await session.pressLiveSubmit(form: liveForm) } else { pressed = await session.pressSubmit(for: plan.values) }
        guard pressed else { return .failed("no submit button found") }
        await session.settlePage(maxWait: 20)
        if await session.pressConfirmStep() { await session.settlePage(maxWait: 20) }
        if let why = await session.visibleChallenge() { return .challenged(why) }
        return WebFormSubmitter.classifyAfterSending(before: before, after: await session.visibleText())
    }

    func pageText() async -> String { await session.viewportText() }

    func close() { session.close() }
}

// MARK: The queue

/// Walks a list of sites one at a time: loads the form, fills it in, waits for the person to clear the bot check (or accept
/// terms themselves), then sends it and reads the confirmation. The next site is loaded in the background meanwhile, so the
/// person's only job is the check. It never solves or accepts anything itself.
@MainActor
final class AssistedRunner: ObservableObject {
    struct Item: Identifiable {
        let entry: DirectoryEntry
        let form: OptOutForm
        let plan: FillPlan
        /// The page in English, tried when the translated one has no form we can fill.
        var fallbackForm: OptOutForm?
        var id: String { entry.id }
    }

    enum Phase: Equatable {
        case loading
        case waitingForTerms
        case waitingForCertification
        case waitingForCheck
        case waitingForChoice(String)   // a required menu we could not fill: the person picks, then we go on
        case sending
        case sent(awaitingEmail: Bool)
        case needsMore(String)        // sent, but no confirmation: the site wants another step from the person
        case timedOut
    }

    @Published private(set) var index = 0
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var page: AssistedPage?
    @Published private(set) var finished = false
    @Published private(set) var results: [String: AutoOptOutResult] = [:]
    /// True while the person is asked whether the page's email step should be tracked, after they tapped Mark as done.
    @Published var askFollowUp = false
    /// A short line about something the app did by itself (a new form appeared and was filled), shown under the instruction.
    @Published private(set) var notice: String?
    private var markedDone: AutoOptOutResult?
    /// How often the screen is read for a confirmation the person caused themselves (pressing the page's own button, a message appearing without a new page).
    var watchInterval: TimeInterval = 12

    let items: [Item]
    private let driver: AssistedDriver
    private let onResult: (DirectoryEntry, AutoOptOutResult) -> Void
    private var preparing: [Int: Task<AssistedPage?, Never>] = [:]
    private var skipFlag = false
    private var nextContinuation: CheckedContinuation<Void, Never>?
    var waitLimit: TimeInterval = 180
    var pollInterval: TimeInterval = 1
    var pauseAfterSent: TimeInterval = 1.2

    init(items: [Item], driver: AssistedDriver, onResult: @escaping (DirectoryEntry, AutoOptOutResult) -> Void) {
        self.items = items; self.driver = driver; self.onResult = onResult
    }

    var current: Item? { items.indices.contains(index) ? items[index] : nil }
    var sentCount: Int { results.values.filter { if case .submitted = $0 { return true } else { return false } }.count }

    /// The person says this site is done, in case a confirmation was not noticed. If the page mentions an email to follow, they are asked whether to track it.
    func markDone() async {
        let text = await page?.pageText() ?? ""
        if FormRun.mentionsEmailFollowUp(text) { askFollowUp = true } else { finishMarked(email: false) }
    }
    func answerFollowUp(track: Bool) { askFollowUp = false; finishMarked(email: track) }
    private func finishMarked(email: Bool) {
        markedDone = .submitted(awaitingEmail: email)
        phase = .sent(awaitingEmail: email)
        resumeNext()
    }

    /// Reads what is on screen; true outcome when the new text shows a confirmation, nil when nothing changed or it says nothing of the kind.
    private func watch(_ page: AssistedPage, baseline: inout String) async -> AutoOptOutResult? {
        let now = await page.pageText()
        guard !now.isEmpty, now != baseline else { return nil }
        let added = FormRun.newText(before: baseline, after: now)
        baseline = now
        if case .submitted(let email) = FormRun.classifyConfirmed(added) { return .submitted(awaitingEmail: email) }
        // Nothing confirmed, but the screen changed: a new privacy form may have appeared (a window opened, the next step). Fill it in if so.
        if await page.adoptNewForm() { notice = Loc.t("A new form appeared and we filled it in. Check it.") }
        return nil
    }

    func skip() { skipFlag = true; resumeNext() }
    func next() { resumeNext() }
    private func resumeNext() { nextContinuation?.resume(); nextContinuation = nil }

    private func prepare(_ i: Int) {
        guard items.indices.contains(i), preparing[i] == nil else { return }
        let item = items[i]
        preparing[i] = Task {
            if let page = await driver.prepare(item.form, plan: item.plan) { return page }
            if let fallback = item.fallbackForm { return await driver.prepare(fallback, plan: item.plan) }
            return nil
        }
    }

    func run() async {
        for i in items.indices {
            index = i; phase = .loading; skipFlag = false; page = nil; markedDone = nil; askFollowUp = false; notice = nil
            prepare(i)
            guard let ready = await preparing[i]?.value else { record(items[i], .failed("the page would not load")); continue }
            ready.present()         // here, not while the screen is drawing: moving a web view during a draw crashed the app
            page = ready
            prepare(i + 1)      // load the next one while the person works on this one

            var outcome: AutoOptOutResult?
            var attempts = 0
            var baseline = await ready.pageText()
            while outcome == nil, attempts < 3 {
                attempts += 1
                var waited: TimeInterval = 0, sinceWatch: TimeInterval = 0
                while true {
                    if skipFlag { outcome = .needsYou("skipped"); break }
                    if let done = markedDone { outcome = done; break }
                    let blockers = await ready.blockers()
                    if blockers.isEmpty { break }
                    if blockers.contains(.terms) { phase = .waitingForTerms }
                    else if blockers.contains(where: { if case .certify = $0 { return true } else { return false } }) { phase = .waitingForCertification }
                    else if let pick = blockers.compactMap({ if case .choose(let what) = $0 { return what } else { return nil } }).first { phase = .waitingForChoice(pick) }
                    else { phase = .waitingForCheck }
                    try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                    waited += pollInterval; sinceWatch += pollInterval
                    if sinceWatch >= watchInterval {
                        sinceWatch = 0
                        if let hit = await watch(ready, baseline: &baseline) {
                            outcome = hit
                            if case .submitted(let email) = hit { phase = .sent(awaitingEmail: email) }
                            break
                        }
                    }
                    if waited > waitLimit { phase = .timedOut; outcome = .needsYou("timed out waiting for the check"); break }
                }
                if outcome != nil { break }
                phase = .sending
                await ready.refill()
                switch await ready.send() {
                case .submitted(let email):
                    phase = .sent(awaitingEmail: email); outcome = .submitted(awaitingEmail: email)
                    try? await Task.sleep(nanoseconds: UInt64(pauseAfterSent * 1_000_000_000))
                case .challenged: continue      // a check appeared after sending: wait for the person again
                case .rejected(let why), .failed(let why):
                    phase = .needsMore(why)
                    outcome = .failed(why)
                    // The person finishes this one, then taps Next or Mark as done; meanwhile the screen is read every few seconds in case a confirmation appears.
                    var watched = await ready.pageText()
                    let watcher = Task { @MainActor [weak self] in
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: UInt64((self?.watchInterval ?? 12) * 1_000_000_000))
                            guard !Task.isCancelled, let self else { return }
                            if let hit = await self.watch(ready, baseline: &watched) {
                                self.markedDone = hit
                                if case .submitted(let email) = hit { self.phase = .sent(awaitingEmail: email) }
                                self.resumeNext(); return
                            }
                        }
                    }
                    await withCheckedContinuation { nextContinuation = $0 }
                    watcher.cancel()
                    if let done = markedDone { outcome = done }
                case .filledNotSubmitted: outcome = .dryRunReady
                }
            }
            record(items[i], outcome ?? .challenged("the check came back"))
            ready.close(); page = nil
        }
        finished = true
    }

    private func record(_ item: Item, _ result: AutoOptOutResult) {
        results[item.id] = result
        onResult(item.entry, result)
    }
}

// MARK: Screen

/// Hosts the live web view so the person can solve the check in it.
struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct AssistedOptOutView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject var runner: AssistedRunner

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if runner.finished { summary } else { working }
            }
            .navigationBarHidden(!runner.finished)
            .navigationTitle("Solve and send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .alert("This page mentions an email", isPresented: Binding(get: { runner.askFollowUp }, set: { _ in })) {
            Button("Yes, track it") { runner.answerFollowUp(track: true) }
            Button("No, it is done") { runner.answerFollowUp(track: false) }
        } message: { Text("A confirmation or verification email looks like it is coming. Track it, and the app reminds you to finish it in Email links?") }
        .task { await runner.run() }
    }

    private var working: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Group {
                    if let web = runner.page?.webView { WebViewHost(webView: web).id(runner.index) }
                    else { ProgressView("Loading the form…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
                .frame(height: geo.size.height * 0.75)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("Stop") { dismiss() }.font(.footnote).accessibilityIdentifier("assisted-stop")
                        Spacer()
                        Text("Site \(runner.index + 1) of \(runner.items.count)").font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            ForEach(IssueKind.allCases, id: \.self) { kind in
                                Button(kind.label) {
                                    if let item = runner.current { model.reportIssue(kind, site: item.entry.id) }
                                    runner.skip()
                                }
                            }
                        } label: { Label("Not working", systemImage: "exclamationmark.bubble").font(.footnote) }
                            .accessibilityIdentifier("assisted-not-working")
                    }
                    ProgressView(value: Double(runner.index), total: Double(max(runner.items.count, 1)))
                    Text(runner.current?.entry.domain ?? "").font(.subheadline.bold()).accessibilityIdentifier("assisted-site")
                    Label(instruction, systemImage: icon).font(.caption).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("assisted-instruction")
                    if let notice = runner.notice { Label(notice, systemImage: "doc.badge.plus").font(.caption).foregroundStyle(.blue).accessibilityIdentifier("assisted-notice") }
                    Spacer(minLength: 0)
                    HStack {
                        Button("Skip this site") { runner.skip() }.accessibilityIdentifier("assisted-skip")
                        Spacer()
                        // In case a confirmation was not noticed: the person says it is done.
                        if canMarkDone { Button("Mark as done") { Task { await runner.markDone() } }.accessibilityIdentifier("assisted-mark-done") }
                        if case .needsMore = runner.phase { Button("Next site") { runner.next() }.buttonStyle(.borderedProminent).accessibilityIdentifier("assisted-next") }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
                .frame(height: geo.size.height * 0.25)
                .background(.bar)
            }
        }
    }

    /// Whether the person can say this site is done: while it waits for them, or after a send that did not confirm.
    private var canMarkDone: Bool {
        switch runner.phase {
        case .waitingForTerms, .waitingForCertification, .waitingForCheck, .waitingForChoice, .needsMore, .timedOut: return true
        default: return false
        }
    }

    private var summary: some View {
        List {
            let sent = runner.results.values.filter { if case .submitted = $0 { return true } else { return false } }.count
            Section {
                Text("Sent \(sent) of \(runner.items.count).").font(.headline).accessibilityIdentifier("assisted-summary")
                Text("Some sites email you a link to confirm. That click is yours.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Each site") {
                ForEach(runner.items) { item in
                    VStack(alignment: .leading) {
                        Text(item.entry.domain)
                        Text(runner.results[item.id]?.label ?? Loc.t("Not reached")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var instruction: String {
        switch runner.phase {
        case .loading: return Loc.t("Loading the form and filling in your details…")
        case .waitingForTerms: return Loc.t("Your details are filled in. This site asks you to accept its terms: read them and accept yourself, then solve the check. We will send it after.")
        case .waitingForCertification: return Loc.t("Your details are filled in. This form asks you to tick a confirmation yourself: read it, tick it if it is true, and solve any check. We will send it after.")
        case .waitingForCheck: return Loc.t("Your details are filled in. Solve the check below and we will send it.")
        case .waitingForChoice(let what): return what.isEmpty ? Loc.t("Your details are filled in. Pick the option the form asks for below, then we will send it.") : Loc.f("Your details are filled in. Pick \"%@\" in the form below, then we will send it.", what)
        case .sending: return "Sending…"
        case .sent(let email): return email ? Loc.t("Sent. Check your email for a link to confirm.") : "Sent."
        case .needsMore(let why): return Loc.f("Sent, but the site did not confirm (%@). It may need one more step from you here. Tap Next site when you are done.", why)
        case .timedOut: return Loc.t("Timed out waiting for the check.")
        }
    }

    private var icon: String {
        switch runner.phase {
        case .sent: return "checkmark.circle.fill"
        case .waitingForTerms, .waitingForCertification, .waitingForCheck, .waitingForChoice: return "hand.point.up.left"
        case .needsMore, .timedOut: return "exclamationmark.triangle"
        default: return "hourglass"
        }
    }

    private var tint: Color {
        switch runner.phase {
        case .sent: return .green
        case .waitingForTerms, .waitingForCertification, .waitingForCheck, .waitingForChoice, .needsMore, .timedOut: return .orange
        default: return .secondary
        }
    }
}
