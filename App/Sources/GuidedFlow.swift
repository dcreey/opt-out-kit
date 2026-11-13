import SwiftUI
import WebKit
import OptOutKitCore

// MARK: The page a guided flow drives

/// What the guided runner needs from a browser page. The real one wraps the web view; tests script it.
@MainActor
protocol GuidedPage: AnyObject {
    var webView: WKWebView? { get }
    func load(_ url: URL) async
    func currentURL() -> URL?
    func visibleText() async -> String
    func fill(_ values: [FieldValue]) async -> Int
    /// A site with no known form: look for one on the live page and fill it in. Pages that cannot scan fill nothing.
    func scanAndFill(person: Person) async -> Int
    func blockers() async -> [AssistedBlocker]
    func send(_ values: [FieldValue]) async -> SubmitOutcome
    func close()
}

extension GuidedPage {
    func scanAndFill(person: Person) async -> Int { 0 }
    /// Who the guide is for, so a page can find and fill their form the same way Solve and send does.
    func use(person: Person) {}
}

@MainActor
final class WebGuidedPage: GuidedPage {
    private let session = WebViewSession.make()
    private var shown: WKWebView?
    private var person: Person?
    /// The page as Solve and send sees it (`WebAssistedPage`): for a site with no form of its own to follow, the guide finds, fills and sends with that same code.
    private var live: WebAssistedPage?
    private var liveFor: URL?

    var webView: WKWebView? { shown ?? { shown = session.presentable(); return shown }() }

    func use(person: Person) { self.person = person }

    /// Test hook: shows this page instead of loading an address.
    func loadHTML(_ html: String) async { try? await session.loadHTML(html); await session.settlePage(maxWait: 3) }

    private func livePage() async -> WebAssistedPage? {
        guard let url = session.webView.url else { return nil }
        if let live, liveFor == url { return live }
        guard let person else { return nil }
        live = nil; liveFor = url
        let driver = WebAssistedDriver(person: person, advertisingID: nil, termsPolicy: nil)
        let stand = OptOutForm(page: url, method: "post", action: nil, fields: [], hops: 1)
        live = await driver.prepareLoaded(session: session, form: stand, plan: FillPlan(values: [], verdict: .ready), keepOpenWithoutForm: true, advanceOnlyWithoutForm: true) as? WebAssistedPage
        return live
    }

    func load(_ url: URL) async {
        try? await session.load(URLRequest(url: url))
        await session.settlePage(maxWait: 6)
        _ = await session.declineBanner()
    }

    func currentURL() -> URL? { session.webView.url }
    func visibleText() async -> String { await session.visibleText() }
    func fill(_ values: [FieldValue]) async -> Int {
        if let live, liveFor == session.webView.url { await live.refill(); return live.lastFill.filled }
        return await session.fillFields(values)
    }
    func scanAndFill(person: Person) async -> Int {
        self.person = person
        if let page = await livePage() { return max(page.lastFill.filled, 0) }
        return await session.scanAndFill(person: person)
    }

    func blockers() async -> [AssistedBlocker] {
        if let live, liveFor == session.webView.url { return await live.blockers() }
        var out: [AssistedBlocker] = []
        if await session.hasTermsPrompt() { out.append(.terms) }
        if let text = await session.pendingCertification() { out.append(.certify(text)) }
        if let why = await session.visibleChallenge() { out.append(.check(why)) }
        return out
    }

    func send(_ values: [FieldValue]) async -> SubmitOutcome {
        if let live, liveFor == session.webView.url {
            // The same read of a send as every other flow: forms that follow each other, a form's next step, a check the person has to clear.
            var sentEmail = false, sent = false
            for _ in 0..<6 {
                await live.refill()
                switch await PageFlow.sendOnce(live) {
                case .sent(let email, let more): sent = true; sentEmail = sentEmail || email; if !more { return .submitted(awaitingEmail: sentEmail) }
                case .nextStep: continue
                case .handToPerson: return .challenged("a reCAPTCHA that \(PageFlow.rejectedMarker)")
                case .checkAppeared(let why): return sent ? .submitted(awaitingEmail: sentEmail) : .challenged(why)
                case .notConfirmed(let answer): return sent ? .submitted(awaitingEmail: sentEmail) : answer
                case .dryRun: return .filledNotSubmitted
                }
            }
            return sent ? .submitted(awaitingEmail: sentEmail) : .failed("the form did not finish")
        }
        guard await session.pressSubmit(for: values) else { return .failed("no submit button found") }
        await session.settlePage(maxWait: 20)
        if let why = await session.visibleChallenge() { return .challenged(why) }
        return FormRun.classify(await session.visibleText())
    }

    func close() { session.close() }
}

@MainActor
protocol GuidedPageMaker { func make() -> GuidedPage }

struct WebGuidedPageMaker: GuidedPageMaker { @MainActor func make() -> GuidedPage { WebGuidedPage() } }

// MARK: The runner

/// Drives one guided opt-out: shows the current step, watches the page for signs the person finished it, does the parts the app
/// can do (copy a value, fill the form, press submit once the person has cleared the checks), and always leaves a Next button.
@MainActor
final class GuidedRunner: ObservableObject {
    enum Ending: Equatable { case finished, cancelled, reported(IssueKind) }

    @Published private(set) var flow: GuidedFlow
    /// The same line is set on every tick while a step waits; only a different one redraws the screen (an open menu blinked otherwise).
    private(set) var status: String? { willSet { if newValue != status { objectWillChange.send() } } }
    @Published private(set) var ending: Ending?
    @Published private(set) var webView: WKWebView?

    let siteName: String
    /// "Is it completely done?" after a send the page did not call finished; asked only where a person is on screen (the guided screen sets `asksAboutFollowUp`).
    let finishQuestion = FinishQuestion()
    var asksAboutFollowUp = false
    private var emailStepFlagged = false
    /// The person said (from the … menu) that this site has another email step.
    func flagEmailStep() { emailStepFlagged = true; finishQuestion.dismiss() }
    var siteID: String { flow.plan.siteID }
    /// Whether an email follows the send; nil when the person says it is not done yet (nothing is recorded and the guide stays on the page).
    private func emailAfterSend(_ email: Bool) async -> Bool? {
        if email || emailStepFlagged { return true }
        guard asksAboutFollowUp else { return false }
        let text = await page.visibleText()
        if FormRun.finishIsCertain(text) { return false }
        switch await finishQuestion.ask(site: siteName, pageSaidEmail: false, allowsNotYet: true) {
        case .done: return false
        case .emailFollows, .unsure: return true
        case .notYet: return nil
        }
    }
    /// "Not yet": the page is left as it is. From here the person finishes it themselves; a confirmation that appears later is noticed, and nothing is pressed again.
    private func stayAfterNotYet() async {
        forceManual = true; manualBaseline = await page.visibleText()
        status = Loc.t("Finish it in the page. We will notice the confirmation, or tap Next step.")
    }
    private let page: GuidedPage
    private var fillValues: [FieldValue]
    private let person: Person
    private let onStepCompleted: (Int) -> Void
    /// Asked when the send step comes up: whether to press the page's own button. The screen sets it from the person's checkbox.
    var autoSubmit: () -> Bool = { true }
    private var manualBaseline: String?
    /// The page's human check refused a scripted press: from here the person presses the page's own button.
    private var forceManual = false
    private let onSent: (AutoOptOutResult) -> Void
    private let onIssue: (IssueKind) -> Void
    /// Looks for the site's current opt-out page when the recorded one is gone. Nil means healing is not available.
    private let healer: (() async -> URL?)?
    private var triedHealing = false
    private var openedSteps = Set<Int>()       // steps whose page the runner has already loaded
    private var lastURL: URL?
    private var filledFor: URL?
    private var scannedFor: URL?           // pages already scanned for a form (a scan can click, so it is not repeated every tick)
    private var started = false
    var pollInterval: TimeInterval = 1

    init(plan: GuidedPlan, resumeAt: Int = 0, person: Person, fillValues: [FieldValue] = [], page: GuidedPage,
         onStepCompleted: @escaping (Int) -> Void = { _ in }, onSent: @escaping (AutoOptOutResult) -> Void = { _ in },
         onIssue: @escaping (IssueKind) -> Void = { _ in }, healer: (() async -> URL?)? = nil) {
        var f = GuidedFlow(plan: plan)
        if resumeAt > 0 { f.resume(at: resumeAt) }
        self.flow = f; self.siteName = plan.siteName; self.person = person; self.fillValues = fillValues
        self.page = page; self.onStepCompleted = onStepCompleted; self.onSent = onSent; self.onIssue = onIssue; self.healer = healer
        self.webView = page.webView
        page.use(person: person)
    }

    // The person's buttons

    func next() {
        let before = flow.index
        apply(.nextTapped); status = nil
        if case .pickListing? = flow.plan.steps.indices.contains(before) ? flow.plan.steps[before].action : nil {
            if flow.index == before { status = Loc.t("Open your own listing in the page first, then tap \"This is my listing\".") }
            else if let listing = flow.chosenListing {
                // The form's address field now has something to hold: the listing the person picked.
                fillValues += flow.plan.listingFields.map { FieldValue(name: $0, type: "url", candidates: [listing.absoluteString], label: "") }
            }
        }
    }
    func back() { apply(.backTapped); status = nil }

    /// The person asks for another try at filling the form (a page that failed and was refreshed, one that cleared the fields, one the first scan missed):
    /// looks for the form again on the page they are on and fills it in. Works at any step; never sends.
    func fillAgain() {
        Task {
            status = Loc.t("Looking for the form…")
            let filled = fillValues.isEmpty ? await page.scanAndFill(person: person) : await page.fill(fillValues)
            status = filled > 0 ? Loc.t("Your details are filled in again.") : Loc.t("Could not find the form's fields on this page. Fill it in yourself, then tap Next step.")
        }
    }
    func cancel() { finish(.cancelled) }
    func report(_ kind: IssueKind) {
        // A broken link is worth one automatic attempt at finding where the page moved before giving up on the site.
        if kind == .brokenLink, healer != nil, !triedHealing {
            Task { if await healAndReload() { return }; onIssue(kind); finish(.reported(kind)) }
            return
        }
        onIssue(kind); finish(.reported(kind))
    }

    /// Crawls the site for its current opt-out page and reloads it. Returns true if a new page was found and loaded.
    @discardableResult
    private func healAndReload() async -> Bool {
        triedHealing = true
        status = Loc.t("This link looks broken. Looking for the new page…")
        guard let healer, let url = await healer() else {
            status = Loc.t("The opt-out page has moved and we could not find the new one. You will need to find it yourself on the site; the steps below still apply.")
            return false
        }
        await page.load(url)
        lastURL = page.currentURL(); filledFor = nil
        status = Loc.t("The page had moved. We found the new one and loaded it.")
        apply(.pageLoaded(lastURL))
        return true
    }

    /// Whether the page just loaded is an error page (the link is gone).
    private func looksBroken() async -> Bool {
        let text = await page.visibleText()
        return LinkRules.isErrorPage(PageSnapshot(url: page.currentURL() ?? URL(string: "https://invalid.example")!, status: nil,
                                                  title: String(text.prefix(120)), text: text))
    }

    /// Copies the current step's value for the person to paste. The clipboard clears itself after a minute.
    func copyCurrent() {
        guard case .copy(let field)? = flow.current?.action else { return }
        guard let value = person.value(for: field) else {
            status = Loc.f("Your %@ is not on your profile yet. Add it later, or tap Next step.", Describe.field(field).lowercased())
            return
        }
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: value]], options: [.expirationDate: Date().addingTimeInterval(60)])
        status = Loc.t("Copied. Paste it into the form. It clears in a minute.")
        apply(.copied)
    }

    // The loop

    func run() async {
        guard !started else { return }
        started = true
        if case .openPage(let url)? = flow.current?.action, let stepID = flow.current?.id { await page.load(url); openedSteps.insert(stepID) }   // the step can change or end while the page loads
        else if case .pickListing(let search)? = flow.current?.action { await page.load(search) }
        else if let url = firstURL { await page.load(url) }
        webView = page.webView
        lastURL = page.currentURL()
        if healer != nil, await looksBroken() { _ = await healAndReload() }      // heal a moved link before the person sees an error
        else { apply(.pageLoaded(lastURL)) }
        if case .pickListing? = flow.current?.action { apply(.searchLanded(page.currentURL())) }     // this address is not a listing
        while ending == nil, !flow.isFinished {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            guard ending == nil else { break }
            await tick()
        }
        if flow.isFinished, ending == nil { finish(.finished) }
    }

    private var firstURL: URL? {
        for step in flow.plan.steps { if case .openPage(let u) = step.action { return u } }
        return nil
    }

    private func tick() async {
        let url = page.currentURL()
        if url != lastURL { lastURL = url; filledFor = nil; apply(.url(url)) }
        guard let step = flow.current else { return }
        apply(.text(await page.visibleText()))
        guard flow.current?.id == step.id else { return }

        switch step.action {
        case .openPage(let target):
            // A later step that opens a page (the opt-out form after the person picked their listing) is opened for them.
            if !openedSteps.contains(step.id) {
                openedSteps.insert(step.id)
                if page.currentURL()?.absoluteString != target.absoluteString { await page.load(target); lastURL = page.currentURL(); filledFor = nil; apply(.pageLoaded(lastURL)) }
            }
        case .autofill:
            if fillValues.isEmpty {
                // No known form for this site: scan the page for one, once per page.
                if scannedFor != url {
                    scannedFor = url; status = Loc.t("Looking for the opt-out form…")
                    if await page.scanAndFill(person: person) > 0 { filledFor = url; status = Loc.t("Your details are filled in. Check them, solve any check and submit it."); apply(.formFilled) }
                    else { status = Loc.t("Could not find the form's fields on this page. Fill it in yourself, then tap Next step.") }
                }
            } else if filledFor != url {
                if await page.fill(fillValues) > 0 { filledFor = url; status = Loc.t("Your details are filled in."); apply(.formFilled) }
                else { status = Loc.t("Could not find the form's fields on this page. Fill it in yourself, then tap Next step.") }
            }
        case .clearBlockers:
            if filledFor != url { _ = await page.fill(fillValues); filledFor = url }       // a page reload can clear the fields
            let blockers = await page.blockers()
            if blockers.isEmpty { apply(.blockersCleared) } else { status = describe(blockers) }
        case .send where !autoSubmit() || forceManual:
            // The person sends it themselves: nothing is pressed, and a confirmation that appears afterwards is noticed.
            let now = await page.visibleText()
            guard let base = manualBaseline else { manualBaseline = now; status = Loc.t("Your details are filled in. Press the page's own button yourself; we will notice the confirmation, or tap Next step."); break }
            if case .submitted(let said) = FormRun.classifyConfirmed(FormRun.newText(before: base, after: now)) {
                guard let email = await emailAfterSend(said) else { await stayAfterNotYet(); break }
                onSent(.submitted(awaitingEmail: email)); status = email ? Loc.t("Sent. Check your email for a link.") : "Sent."
                apply(.formSent(awaitingEmail: email))
            }
        case .send:
            _ = await page.fill(fillValues)
            switch await page.send(fillValues) {
            case .submitted(let said):
                guard let email = await emailAfterSend(said) else { await stayAfterNotYet(); break }
                onSent(.submitted(awaitingEmail: email)); status = email ? Loc.t("Sent. Check your email for a link.") : "Sent."
                apply(.formSent(awaitingEmail: email))
            case .challenged(let why) where why.contains(PageFlow.rejectedMarker):
                forceManual = true; manualBaseline = nil
                status = Loc.t("The site's human check did not accept an automatic send. Press its Submit button yourself.")
            case .challenged(let why): status = Loc.f("The site wants another check: %@. Solve it and we will send again.", why)
            case .rejected(let why), .failed(let why):
                status = Loc.f("We could not confirm it was sent (%@). Finish it yourself in the page, then tap Next step.", why)
            case .filledNotSubmitted: break
            }
        default: break
        }
    }

    private func describe(_ blockers: [AssistedBlocker]) -> String {
        if blockers.contains(.terms) { return Loc.t("Read and accept this site's terms yourself, then solve the check.") }
        if blockers.contains(where: { if case .certify = $0 { return true } else { return false } }) { return Loc.t("Tick the confirmation box yourself if it is true, then solve the check.") }
        return Loc.t("Solve the check in the page. We will send it after.")
    }

    private func apply(_ event: GuidedEvent) {
        let before = flow.current?.id
        if let done = flow.apply(event) {
            onStepCompleted(done)
            if flow.autoCompleted.contains(done) { status = Loc.f("Step %@ done: we saw you finish it.", done + 1) }
        }
        if flow.isFinished, ending == nil, before != nil { finish(.finished) }
    }

    /// The person finished the request in their own browser and said so.
    func finishedInBrowser() { finish(.finished) }

    private func finish(_ e: Ending) {
        guard ending == nil else { return }
        ending = e
        page.close()
    }
}

// MARK: Screen: our guide on top in a coloured frame, the site's page below it

struct GuidedFlowView: View {
    @StateObject var runner: GuidedRunner
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var intro = false

    var body: some View {
        // The geometry is read with the safe area intact, so the guide knows how tall the status bar and the camera cut-out are; only
        // the content ignores the top safe area, so the coloured band can run behind it.
        GeometryReader { geo in
            VStack(spacing: 0) {
                GuidedPanel(runner: runner, topInset: geo.safeAreaInsets.top, maxStepHeight: geo.size.height * 0.2)
                // The site's own page sits below the guide, clearly a different thing.
                Group {
                    if let web = runner.webView { WebViewHost(webView: web) }
                    else { ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier("guided-browser")
            }
            .ignoresSafeArea(edges: .top)
        }
        .onAppear { runner.autoSubmit = { model.autoSubmit } }
        .task {
            intro = !model.guidedIntroSeen
            while intro { try? await Task.sleep(nanoseconds: 200_000_000) }        // the guide waits while the walkthrough is open
            await runner.run()
        }
        .guidedIntro($intro) { model.markGuidedIntroSeen(); intro = false }
        .onChange(of: runner.ending) { _, e in if e != nil { dismiss() } }
    }
}

/// The guide, on black and on top: its actions come first (the menu on the left, Back, Copy and Next on the right), then the step in full
/// (scrolling if it is long). A gold line carrying the app's icon and name separates it from the site's own page below, the same as in the
/// semi-automated screen.
struct GuidedPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var runner: GuidedRunner
    private var nextTitle: String {
        if case .pickListing? = runner.flow.current?.action { return Loc.t("This is my listing") }
        return runner.flow.index + 1 >= runner.flow.total ? Loc.t("Finish") : Loc.t("Next step")
    }
    /// The top safe area (status bar, and the Dynamic Island or notch where there is one): the black runs behind it, the content starts below it.
    var topInset: CGFloat = 0
    var maxStepHeight: CGFloat = 140
    @State private var stepHeight: CGFloat = 0
    @StateObject private var browserHandoff = BrowserHandoff()
    @AppStorage("guide.collapsed") private var guideCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            GuideSurface(topInset: topInset) {
                HStack(spacing: 10) {
                    Menu {
                        PageMenu.items(web: runner.webView, idPrefix: "guided", details: model.pageDetails, browser: browserHandoff, anotherEmailStep: { runner.flagEmailStep(); model.addFollowUpStep(runner.siteID) }) { runner.fillAgain() }
                        Menu {
                            ForEach(IssueKind.allCases, id: \.self) { kind in
                                Button(kind.label) { runner.report(kind) }.accessibilityIdentifier("guided-issue-\(kind.rawValue)")
                            }
                        } label: { Label("Not working", systemImage: "exclamationmark.bubble") }.accessibilityIdentifier("guided-not-working")
                        Button(role: .destructive) { runner.cancel() } label: { Label("Cancel", systemImage: "xmark.circle") }.accessibilityIdentifier("guided-cancel")
                    } label: { Image(systemName: "ellipsis.circle").font(.title2) }
                        .accessibilityLabel(Loc.t("More")).accessibilityIdentifier("guided-more")
                    GuideCollapseButton(collapsed: $guideCollapsed)
                    if guideCollapsed {
                        Text(runner.siteName).font(.subheadline.bold()).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6).layoutPriority(-1).accessibilityIdentifier("guided-progress")
                    } else {
                        Text(runner.flow.progressLabel ?? Loc.t("All done")).font(.caption.bold()).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                            .accessibilityIdentifier("guided-progress")
                    }
                    Spacer()
                    if runner.flow.index > 0 { Button("Back") { runner.back() }.buttonStyle(GuideSecondaryStyle()).accessibilityIdentifier("guided-back") }
                    if case .copy? = runner.flow.current?.action {
                        Button("Copy", systemImage: "doc.on.doc") { runner.copyCurrent() }.buttonStyle(GuideSecondaryStyle()).accessibilityIdentifier("guided-copy")
                    }
                    Button(nextTitle) { runner.next() }.buttonStyle(GuidePrimaryStyle()).accessibilityIdentifier("guided-next")
                }
                if !guideCollapsed { ProgressView(value: Double(runner.flow.index), total: Double(max(runner.flow.total, 1))).tint(Color.exnayGold) }
                if !guideCollapsed, let step = runner.flow.current {
                    // The whole instruction is shown; a long one scrolls instead of being cut off with an ellipsis.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title).font(.subheadline.bold()).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("guided-step-title")
                            if let detail = step.detail {
                                Text(detail).font(.footnote).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { Color.clear.preference(key: StepHeightKey.self, value: $0.size.height) })
                    }
                    // As tall as the text needs, up to a cap; only a long instruction scrolls.
                    .frame(height: min(max(stepHeight, 20), maxStepHeight))
                    .onPreferenceChange(StepHeightKey.self) { stepHeight = $0 }
                }
                if !guideCollapsed { AutoSubmitToggle().padding(.top, 4) }
                if !guideCollapsed, let status = runner.status {
                    Label(status, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("guided-status")
                }
            }
            GuideBoundary()
        }
        .browserHandoffAlert(browserHandoff) { runner.finishedInBrowser() }
        .finishQuestionAlert(runner.finishQuestion)
        .onAppear { runner.asksAboutFollowUp = true }
    }
}

private struct StepHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
