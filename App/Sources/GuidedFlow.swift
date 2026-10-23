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
    func blockers() async -> [AssistedBlocker]
    func send(_ values: [FieldValue]) async -> SubmitOutcome
    func close()
}

@MainActor
final class WebGuidedPage: GuidedPage {
    private let session = WebViewSession.make()
    private var shown: WKWebView?

    var webView: WKWebView? { shown ?? { shown = session.presentable(); return shown }() }

    func load(_ url: URL) async {
        try? await session.load(URLRequest(url: url))
        await session.settlePage(maxWait: 6)
        _ = await session.declineBanner()
    }

    func currentURL() -> URL? { session.webView.url }
    func visibleText() async -> String { await session.visibleText() }
    func fill(_ values: [FieldValue]) async -> Int { await session.fillFields(values) }

    func blockers() async -> [AssistedBlocker] {
        var out: [AssistedBlocker] = []
        if await session.hasTermsPrompt() { out.append(.terms) }
        if let text = await session.pendingCertification() { out.append(.certify(text)) }
        if let why = await session.visibleChallenge() { out.append(.check(why)) }
        return out
    }

    func send(_ values: [FieldValue]) async -> SubmitOutcome {
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
    @Published private(set) var status: String?
    @Published private(set) var ending: Ending?
    @Published private(set) var webView: WKWebView?

    let siteName: String
    private let page: GuidedPage
    private var fillValues: [FieldValue]
    private let person: Person
    private let onStepCompleted: (Int) -> Void
    private let onSent: (AutoOptOutResult) -> Void
    private let onIssue: (IssueKind) -> Void
    /// Looks for the site's current opt-out page when the recorded one is gone. Nil means healing is not available.
    private let healer: (() async -> URL?)?
    private var triedHealing = false
    private var openedSteps = Set<Int>()       // steps whose page the runner has already loaded
    private var lastURL: URL?
    private var filledFor: URL?
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
        if case .openPage(let url)? = flow.current?.action { await page.load(url); openedSteps.insert(flow.current!.id) }
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
            if filledFor != url {
                if await page.fill(fillValues) > 0 { filledFor = url; status = Loc.t("Your details are filled in."); apply(.formFilled) }
                else { status = Loc.t("Could not find the form's fields on this page. Fill it in yourself, then tap Next step.") }
            }
        case .clearBlockers:
            if filledFor != url { _ = await page.fill(fillValues); filledFor = url }       // a page reload can clear the fields
            let blockers = await page.blockers()
            if blockers.isEmpty { apply(.blockersCleared) } else { status = describe(blockers) }
        case .send:
            _ = await page.fill(fillValues)
            switch await page.send(fillValues) {
            case .submitted(let email):
                onSent(.submitted(awaitingEmail: email)); status = email ? Loc.t("Sent. Check your email for a link.") : "Sent."
                apply(.formSent(awaitingEmail: email))
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

    private func finish(_ e: Ending) {
        guard ending == nil else { return }
        ending = e
        page.close()
    }
}

// MARK: Screen: our guide on top in a coloured frame, the site's page below it

struct GuidedFlowView: View {
    @StateObject var runner: GuidedRunner
    @Environment(\.dismiss) private var dismiss

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
        .task { await runner.run() }
        .onChange(of: runner.ending) { _, e in if e != nil { dismiss() } }
    }
}

/// The guide, kept small: a slim coloured band that names Opt-Out Kit and the step (its content sits below the status bar and the
/// camera cut-out), the current step in full (scrolling if it is long), and the controls. It is on top, away from the home
/// indicator, and framed so it cannot be mistaken for part of the site below.
struct GuidedPanel: View {
    @ObservedObject var runner: GuidedRunner
    private var nextTitle: String {
        if case .pickListing? = runner.flow.current?.action { return Loc.t("This is my listing") }
        return runner.flow.index + 1 >= runner.flow.total ? Loc.t("Finish") : Loc.t("Next step")
    }
    /// The top safe area (status bar, and the Dynamic Island or notch where there is one): the band's colour runs behind it, the band's
    /// content starts below it.
    var topInset: CGFloat = 0
    var maxStepHeight: CGFloat = 140
    @State private var stepHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Cancel") { runner.cancel() }.font(.footnote.bold()).foregroundStyle(.white).accessibilityIdentifier("guided-cancel")
                Spacer(minLength: 4)
                Label("Opt-Out Kit · Guide", systemImage: "shield.lefthalf.filled").font(.caption.bold()).foregroundStyle(.white).lineLimit(1)
                    .accessibilityIdentifier("guided-banner")
                Text(runner.flow.progressLabel ?? Loc.t("All done")).font(.caption.bold()).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    .accessibilityIdentifier("guided-progress")
                Spacer(minLength: 4)
                Menu {
                    ForEach(IssueKind.allCases, id: \.self) { kind in
                        Button(kind.label) { runner.report(kind) }.accessibilityIdentifier("guided-issue-\(kind.rawValue)")
                    }
                } label: { Label("Not working", systemImage: "exclamationmark.bubble").labelStyle(.iconOnly).font(.body).foregroundStyle(.white) }
                    .accessibilityLabel(Loc.t("Not working"))
                    .accessibilityIdentifier("guided-not-working")
            }
            .padding(.horizontal, 12).padding(.top, topInset + 2).padding(.bottom, 6)
            .background(Color.accentColor)

            ProgressView(value: Double(runner.flow.index), total: Double(max(runner.flow.total, 1)))
                .progressViewStyle(.linear).tint(Color.accentColor).scaleEffect(x: 1, y: 0.6)

            VStack(alignment: .leading, spacing: 6) {
                if let step = runner.flow.current {
                    // The whole instruction is shown; a long one scrolls instead of being cut off with an ellipsis.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title).font(.subheadline.bold()).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("guided-step-title")
                            if let detail = step.detail {
                                Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { Color.clear.preference(key: StepHeightKey.self, value: $0.size.height) })
                    }
                    // As tall as the text needs, up to a cap; only a long instruction scrolls.
                    .frame(height: min(max(stepHeight, 20), maxStepHeight))
                    .onPreferenceChange(StepHeightKey.self) { stepHeight = $0 }
                }
                if let status = runner.status {
                    Label(status, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("guided-status")
                }
                HStack(spacing: 8) {
                    if runner.flow.index > 0 { Button("Back") { runner.back() }.buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("guided-back") }
                    if case .copy? = runner.flow.current?.action {
                        Button("Copy", systemImage: "doc.on.doc") { runner.copyCurrent() }
                            .buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("guided-copy")
                    }
                    Spacer()
                    Button(nextTitle) { runner.next() }
                        .buttonStyle(.borderedProminent).controlSize(.small).accessibilityIdentifier("guided-next")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))

            Rectangle().fill(Color.accentColor).frame(height: 3)
        }
    }
}

private struct StepHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
