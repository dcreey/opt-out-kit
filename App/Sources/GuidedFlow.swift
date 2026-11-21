import SwiftUI
import WebKit
import OptOutKitCore

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

struct WebGuidedPageMaker: GuidedPageMaker { @MainActor func make() -> GuidedPage { WebGuidedPage() } }

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
    @Preference("guide.collapsed") private var guideCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            GuideSurface(topInset: topInset, collapsed: $guideCollapsed) {
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
