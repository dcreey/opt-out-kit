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
    func close()
    /// The live web view to show the person, or nil in tests. Reading it changes nothing: `present()` must be called first.
    var webView: WKWebView? { get }
    /// Moves the page's web view out of its hidden window so a screen can show it. Called by the runner, never while a view is drawing.
    func present()
}

extension AssistedPage { func present() {} }

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
    private var shown: WKWebView?

    init(session: WebViewSession, plan: FillPlan) { self.session = session; self.plan = plan }

    func useLive(form token: String, plan: FillPlan, ownerMayConfirm: Bool, stateName: String? = nil) { liveForm = token; self.plan = plan; self.ownerMayConfirm = ownerMayConfirm; self.stateName = stateName }

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
            index = i; phase = .loading; skipFlag = false; page = nil
            prepare(i)
            guard let ready = await preparing[i]?.value else { record(items[i], .failed("the page would not load")); continue }
            ready.present()         // here, not while the screen is drawing: moving a web view during a draw crashed the app
            page = ready
            prepare(i + 1)      // load the next one while the person works on this one

            var outcome: AutoOptOutResult?
            var attempts = 0
            while outcome == nil, attempts < 3 {
                attempts += 1
                var waited: TimeInterval = 0
                while true {
                    if skipFlag { outcome = .needsYou("skipped"); break }
                    let blockers = await ready.blockers()
                    if blockers.isEmpty { break }
                    if blockers.contains(.terms) { phase = .waitingForTerms }
                    else if blockers.contains(where: { if case .certify = $0 { return true } else { return false } }) { phase = .waitingForCertification }
                    else if let pick = blockers.compactMap({ if case .choose(let what) = $0 { return what } else { return nil } }).first { phase = .waitingForChoice(pick) }
                    else { phase = .waitingForCheck }
                    try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                    waited += pollInterval
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
                    await withCheckedContinuation { nextContinuation = $0 }      // the person finishes this one, then taps Next
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
                    Spacer(minLength: 0)
                    HStack {
                        Button("Skip this site") { runner.skip() }.accessibilityIdentifier("assisted-skip")
                        Spacer()
                        if case .needsMore = runner.phase { Button("Next site") { runner.next() }.buttonStyle(.borderedProminent).accessibilityIdentifier("assisted-next") }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
                .frame(height: geo.size.height * 0.25)
                .background(.bar)
            }
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
