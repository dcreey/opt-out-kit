import UIKit
import WebKit
import OptOutKitCore

/// Reads pages the way a browser does: it loads them in a hidden WKWebView, lets their JavaScript run, waits for the
/// page to stop changing, then returns what a person would see. This reaches sites whose results arrive after a
/// "loading" page, which a plain request cannot read. Each fetch gets its own private session (no cookies kept, none
/// shared), and nothing is shown on screen. A site that shows a human check still shows it; we report that, never solve it.
struct WebViewFetcher: PageFetcher {
    var maxWait: TimeInterval = 14
    /// Decides whether an "I agree to our terms" prompt may be accepted for the person. Nil means never: the prompt is
    /// reported (`Rechecker.termsGateMarker`) and left alone. See `TermsGate` for the rules, and docs/TERMS.md.
    var termsPolicy: TermsPolicy?

    func fetch(_ url: URL) async throws -> FetchedPage {
        guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
        return try await WebViewSession.run(maxWait: maxWait, terms: termsPolicy, domain: url.host ?? "") { session in
            try await session.load(URLRequest(url: url))
        }
    }

    /// A browser POST: load the site's own origin first (so the form is same-origin, as it would be for a person),
    /// then submit a real HTML form. WKWebView drops the body of a direct POST request, so it cannot be done any other way.
    func post(_ url: URL, body: String) async throws -> FetchedPage {
        guard url.scheme == "https", let origin = URL(string: "/", relativeTo: url)?.absoluteURL else { throw URLError(.unsupportedURL) }
        return try await WebViewSession.run(maxWait: maxWait, terms: termsPolicy, domain: url.host ?? "") { session in
            try await session.load(URLRequest(url: origin))
            try await session.submitForm(action: url, body: body)
        }
    }

    /// Test hook: render HTML the test supplies, including any scripts in it.
    func render(html: String, domain: String = "example.test") async throws -> FetchedPage {
        try await WebViewSession.run(maxWait: maxWait, terms: termsPolicy, domain: domain) { session in try await session.loadHTML(html) }
    }
}

/// The app's side of the terms decision. It is given the prompt text and the addresses of the terms pages the prompt links
/// to, reads those pages itself, and answers with a `TermsDecision`. Only `.accept` lets the web view press "I agree".
protocol TermsPolicy: Sendable {
    func decide(domain: String, prompt: String, documentLinks: [URL]) async -> TermsDecision
    /// Called after the button was pressed, so the acceptance can be logged on the device.
    func accepted(domain: String, paragraphs: Int, libraryVersion: Int) async
}

@MainActor
final class WebViewSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private var status = 200
    /// The token of the form a live run chose, so the final picture is cropped around it.
    var chosenForm: String?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var waitSerial = 0
    /// Frames (pages inside the page) that reported forms or fields, and the one the chosen form lives in, when it is not the page itself.
    var frames: [(info: WKFrameInfo, href: String)] = []
    var activeFrame: WKFrameInfo?
    private let reporter = FrameReporter()
    /// Set only for a background run's site (`PageActivity.report`): told of every sign of life from the page, so a page that goes quiet is given up.
    /// Nil for every screen a person uses (Solve and send, guides), which are left exactly as they were.
    private let activity: (@Sendable () -> Void)? = PageActivity.report
    private let activityReporter = ActivityReporter()
    func touch() { activity?() }
    /// The run gave this site up (it went quiet or ran out of time): the page was stopped and taken out of the window, and every later step fails at once.
    private(set) var abandoned = false
    /// Runs a script on the page. An answer is a sign of life (a page whose scripts never answer is the one that wedges a run).
    func evaluate(_ js: String) async throws -> Any? {
        if abandoned { throw CancellationError() }
        let r = try await webView.evaluateJavaScript(js)
        touch()
        return r
    }
    /// The same, in one frame.
    func evaluate(_ js: String, in frame: WKFrameInfo, contentWorld: WKContentWorld) async throws -> Any? {
        if abandoned { throw CancellationError() }
        let r = try await webView.evaluateJavaScript(js, in: frame, contentWorld: contentWorld)
        touch()
        return r
    }

    /// Ends a background run's page that the run gave up on: it stops loading, leaves the window, and a load still waiting is ended, so the work
    /// behind it winds down instead of keeping a hidden page alive for the rest of the run.
    func abandon() {
        guard !abandoned else { return }
        abandoned = true
        close()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        resume(CancellationError(), force: true)
    }

    /// The HTTP status of the last page the web view loaded.
    var httpStatus: Int { status }

    /// For form runs, which drive the session step by step instead of through `run`.
    static func make() -> WebViewSession { WebViewSession() }

    func close() { webView.stopLoading(); webView.removeFromSuperview() }

    /// Hands the web view to a visible screen so a person can use it. It leaves the hidden window it was parked in.
    func presentable() -> WKWebView {
        webView.removeFromSuperview()
        webView.alpha = 1
        return webView
    }

    private override init() {
        let bin = PageActivity.bin
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Global Privacy Control: every page the app opens is told, in script too, that this person opts out of sale and sharing.
        config.userContentController.addUserScript(WKUserScript(source: PageScript.source("global-privacy-control"),
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: false))
        // Every frame that has inputs tells the session, so a form inside a frame from another site can be read and filled.
        config.userContentController.add(reporter, contentWorld: .page, name: "ookFrame")
        config.userContentController.addUserScript(WKUserScript(source: PageScript.source("frame-reporter"), injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        // The person's own touches and keys (only real ones, never the page's or the app's scripted events) are noted, so the app can leave the page alone while they type,
        // and tell a confirmation they caused (they pressed a button, a link or Enter) from one the page showed by itself.
        config.userContentController.addUserScript(WKUserScript(source: PageScript.source("touch-tracker"), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if activity != nil {
            // Signs of life from the page itself: the page changing, and a request it made coming back (at most one a second).
            config.userContentController.add(activityReporter, contentWorld: .page, name: "ookActivity")
            config.userContentController.addUserScript(WKUserScript(source: Self.activityScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: config)
        super.init()
        reporter.session = self
        activityReporter.session = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        bin?.add(self)
        // Some pages only run timers while attached to a window, so park it invisibly in the key window.
        webView.alpha = 0.01
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        // Behind everything else in the window, so even a moment of full opacity is covered by the app.
        (scene?.keyWindow ?? scene?.windows.first)?.insertSubview(webView, at: 0)
    }

    static func run(maxWait: TimeInterval, terms: TermsPolicy? = nil, domain: String = "",
                    _ steps: @MainActor @escaping (WebViewSession) async throws -> Void) async throws -> FetchedPage {
        try await MainActor.run { () -> WebViewSession in WebViewSession() }.execute(maxWait: maxWait, terms: terms, domain: domain, steps)
    }

    private func execute(maxWait: TimeInterval, terms: TermsPolicy?, domain: String,
                         _ steps: (WebViewSession) async throws -> Void) async throws -> FetchedPage {
        defer { webView.stopLoading(); webView.removeFromSuperview() }
        try await steps(self)
        await settle(maxWait: maxWait)
        if await declineConsentBanner() { await settle(maxWait: 6) }

        // An "I agree to our terms" prompt. It is accepted only when the policy says every paragraph on it and on the
        // pages it links to is on the list a person reviewed and approved. In every other case it is left alone and reported.
        var gateLeftAlone = false
        if let gate = await findTermsGate() {
            if let terms,
               case .accept(let paragraphs, let version) = await terms.decide(domain: domain, prompt: gate.prompt, documentLinks: gate.links),
               await clickAgree() {
                await terms.accepted(domain: domain, paragraphs: paragraphs, libraryVersion: version)
                await settle(maxWait: maxWait)
            } else {
                gateLeftAlone = true
            }
        }
        var text = (try? await webView.evaluateJavaScript("document.title + '\\n' + (document.body ? document.body.innerText : '')")) as? String ?? ""
        if gateLeftAlone { text += "\n" + Rechecker.termsGateMarker }
        return FetchedPage(status: status, text: text)
    }

    // MARK: Terms prompts

    /// For a page the person is working on: when the person allowed it and every paragraph of the prompt and its terms pages is on the reviewed list,
    /// presses "I agree" and logs it. Anything else leaves the prompt for them. True when the button was pressed.
    func acceptTermsIfAllowed(policy: TermsPolicy?, domain: String) async -> Bool {
        guard let policy, let gate = await findTermsGate() else { return false }
        guard case .accept(let paragraphs, let version) = await policy.decide(domain: domain, prompt: gate.prompt, documentLinks: gate.links), await clickAgree() else { return false }
        await policy.accepted(domain: domain, paragraphs: paragraphs, libraryVersion: version)
        await settle(maxWait: 8)
        return true
    }

    private static let gatePattern = #"acceptable use policy|by clicking [“"']?i agree|i agree.{0,120}(terms|policy)|accept (the )?terms|you must agree|j'accepte.{0,120}(conditions|politique)|accepter les conditions|acepto.{0,120}(términos|condiciones|política)|aceptar los términos|ich stimme.{0,120}(bedingungen|datenschutz)|nutzungsbedingungen akzeptieren"#

    /// The prompt text (the smallest element that holds the gate wording) and the same-site terms and privacy pages it links
    /// to. Nothing is clicked here.
    private func findTermsGate() async -> (prompt: String, links: [URL])? {
        let js = PageScript.call("find-terms-gate", Self.gatePattern)
        guard let json = (try? await webView.evaluateJavaScript(js)) as? String,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prompt = object["prompt"] as? String else { return nil }
        let links = ((object["links"] as? [String]) ?? []).compactMap(URL.init(string:))
        return (prompt, links)
    }

    /// Presses "I agree" inside the same dialog that holds the terms text, so a cookie banner elsewhere on the page is never
    /// touched. Returns true if a button was pressed.
    private func clickAgree() async -> Bool {
        let js = PageScript.call("click-agree", Self.gatePattern)
        return ((try? await webView.evaluateJavaScript(js)) as? Bool) ?? false
    }

    /// Cookie and tracking banners hide the page behind a prompt. We always pick the most private option
    /// ("Reject all", "Decline") and never "Accept". Returns true if a button was clicked.
    private func declineConsentBanner() async -> Bool {
        let js = PageScript.source("decline-consent-banner")
        return ((try? await webView.evaluateJavaScript(js)) as? Bool) ?? false
    }

    // MARK: Loading

    /// `budget`: keep trying for at most this many seconds in all (a dropped or slow first attempt is retried), then give up. Without it, the usual three tries.
    func load(_ request: URLRequest, within budget: TimeInterval? = nil) async throws {
        let deadline = budget.map { Date().addingTimeInterval($0) }
        // Ask for the site in the language the person chose, so a site that has its terms and forms in that language shows them.
        var request = request
        request.setValue("1", forHTTPHeaderField: "Sec-GPC")
        if request.value(forHTTPHeaderField: "Accept-Language") == nil {
            request.setValue("\(Loc.language),en;q=0.5", forHTTPHeaderField: "Accept-Language")
        }
        request.timeoutInterval = deadline.map { max(4, $0.timeIntervalSinceNow) } ?? 45
        // A site that drops the first attempt, or that is slow to answer, is tried again before the page is given up on.
        var attempt = 0
        while true {
            do { try await wait(limit: deadline == nil ? 50 : request.timeoutInterval + 1) { self.webView.load(request) }; return }
            catch {
                attempt += 1
                if let deadline {
                    // Within a budget: retry until it runs out, whatever the error was.
                    guard deadline.timeIntervalSinceNow > 2.5 else { throw error }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    request.timeoutInterval = max(3, deadline.timeIntervalSinceNow)
                } else {
                    guard attempt < 3, Self.isTransient(error) else { throw error }
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
                }
            }
        }
    }

    /// Errors that say "try again" (timed out, connection lost, could not connect, the load was interrupted), not "this page is gone".
    static func isTransient(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSURLErrorDomain { return [NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorDNSLookupFailed].contains(e.code) }
        return e.domain == "WebKitErrorDomain" && e.code == 102
    }

    /// Loads HTML the app holds (no network). WebKit now and then fails such a load at once with an internal "InvalidTransition" error (seen on CI's
    /// simulators); the same HTML is loaded once more, since nothing about the page caused it. A cancel or a timeout is not tried again.
    func loadHTML(_ html: String) async throws {
        let base = URL(string: "https://example.invalid/")
        do { try await wait { self.webView.loadHTMLString(html, baseURL: base) } }
        catch where !(error is CancellationError) && (error as? URLError)?.code != .timedOut && !abandoned {
            NSLog("OOK loadHTML failed once, loading again: %@", "\(error)")
            try await wait { self.webView.loadHTMLString(html, baseURL: base) }
        }
    }

    func submitForm(action: URL, body: String) async throws {
        let fields = body.split(separator: "&").map { pair -> [String] in
            let p = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return [p.first?.removingPercentEncoding ?? "", (p.count > 1 ? p[1] : "").removingPercentEncoding ?? ""]
        }
        let json = String(data: try JSONSerialization.data(withJSONObject: fields), encoding: .utf8) ?? "[]"
        let js = PageScript.call("submit-form", json: [Self.jsString(action.absoluteString), json])
        SiteRun.markSent?()          // a background run's watchdog now knows the form went to the site (`SiteRun`)
        try await wait { self.webView.evaluateJavaScript(js, completionHandler: nil) }
    }

    private static func jsString(_ s: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [s]), encoding: .utf8))?.dropFirst().dropLast().description ?? "\"\""
    }

    private func wait(limit: TimeInterval = 50, _ start: () -> Void) async throws {
        if abandoned { throw CancellationError() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loadContinuation = c
            waitSerial += 1
            let mine = waitSerial
            start()
            // A load that never reports back (a redirect that was cancelled and not followed) ends as a timeout instead of hanging.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                if self?.waitSerial == mine { self?.resume(URLError(.timedOut), force: true) }
            }
        }
    }

    /// Waits until the visible text stops changing, so "loading..." screens give way to the real results.
    private func settle(maxWait: TimeInterval) async {
        let deadline = Date().addingTimeInterval(maxWait)
        var last = -1, stable = 0
        // Looked at every quarter second; settled once loaded and unchanged for `PageSettle.quietFor` (it was two seconds, looked at every half second).
        while Date() < deadline, !abandoned, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(PageSettle.pollEvery * 1_000_000_000))
            let probe = (try? await webView.evaluateJavaScript("(document.readyState||'') + '|' + (document.body ? document.body.innerText : '')")) as? String ?? ""
            let ready = probe.hasPrefix("complete|")
            if ready && probe.count == last && !PageSettle.stillLoading(probe) { stable += 1 } else { stable = 0 }
            last = probe.count
            if PageSettle.settled(sameFor: stable) { return }
        }
    }

    // MARK: WKUIDelegate

    /// A link that asks for a new window (target="_blank", window.open) opens in this same page: there is no second window to show, and without this the tap does nothing.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil || navigationAction.targetFrame?.isMainFrame == false,
           let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https" { webView.load(navigationAction.request) }
        return nil
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        touch()
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse { status = http.statusCode }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { touch(); resume(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { touch(); resume(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { touch(); resume(error) }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { touch() }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { touch() }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) { touch() }

    /// A navigation that was cancelled because the page moved on to another one (a redirect) is not a failure: the next one reports.
    private func resume(_ error: Error?, force: Bool = false) {
        if let error, !force, (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled { return }
        guard let c = loadContinuation else { return }
        loadContinuation = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}

// MARK: Opt-out forms

/// Fills in a site's real opt-out form from a person's profile and sends it. It stops, and says so, at anything a person
/// must handle: a visible human check, a terms prompt, a form it cannot fill. It never solves a challenge, never ticks a
/// legal acknowledgement, and only reports "sent" when the site shows a success message.
extension WebFormSubmitter {
    /// What the page said after sending, judged only on the lines that were not there before.
    nonisolated static func newLines(before: String, after: String) -> String { FormRun.newText(before: before, after: after) }

    nonisolated static func classifyAfterSending(before: String, after: String) -> SubmitOutcome {
        let added = FormRun.newText(before: before, after: after)
        if added.isEmpty { return .failed("nothing on the page changed after sending") }
        return FormRun.classifyConfirmed(added)
    }
}

struct WebFormSubmitter: FormSubmitter {
    var maxWait: TimeInterval = 20
    /// When set, the form is found on the live page and filled from these details (the stored crawl is only a hint). When nil, the
    /// stored form's plan is followed, which tests use.
    var person: Person?
    /// The phone's advertising ID, when a form asks for it and the person allowed reading it.
    var advertisingID: String?

    func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome {
        await FormRun.run(url: form.page, html: nil, plan: plan, dryRun: dryRun, maxWait: maxWait, capture: false).outcome
    }

    /// It reports the page's signs of life, so the run gives up on a page that goes quiet (`AutoOptOut.idleLimit`).
    var reportsActivity: Bool { true }

    /// The same, with every web view made for this site telling `activity` of the page's signs of life.
    /// When the run gives the site up, its work is cancelled and every web view it made is ended at once.
    func submitCapturing(_ form: OptOutForm, plan: FillPlan, dryRun: Bool, activity: @escaping @Sendable () -> Void) async -> SubmitEvidence {
        let bin = await MainActor.run { SessionBin() }
        return await withTaskCancellationHandler {
            await PageActivity.$bin.withValue(bin) {
                await PageActivity.$report.withValue(activity) { await submitCapturing(form, plan: plan, dryRun: dryRun) }
            }
        } onCancel: {
            Task { @MainActor in bin.abandonAll(); NSLog("OptOutRun: gave up a site, its pages were ended") }
        }
    }

    /// Fills and sends the form in a hidden web view, then takes a screenshot of whatever the page showed at the end.
    func submitCapturing(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitEvidence {
        if let person { return await FormRun.runLive(url: form.page, html: nil, person: person, dryRun: dryRun, maxWait: maxWait, capture: !dryRun, advertisingID: advertisingID) }
        return await FormRun.run(url: form.page, html: nil, plan: plan, dryRun: dryRun, maxWait: maxWait, capture: !dryRun)
    }

    /// Test hook: run the same steps against HTML the test supplies.
    func submit(html: String, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome {
        await FormRun.run(url: nil, html: html, plan: plan, dryRun: dryRun, maxWait: maxWait, capture: false).outcome
    }

    /// Test hook: fill and send a local page, then return the page title it set, so a test can see what the form received.
    @MainActor
    func submitReturningTitle(html: String, plan: FillPlan) async -> String {
        let session = WebViewSession.make()
        defer { session.close() }
        guard (try? await session.loadHTML(html)) != nil else { return "" }
        await session.settlePage(maxWait: 5)
        _ = await session.fillFields(plan.values)
        _ = await session.pressSubmit(for: plan.values)
        await session.settlePage(maxWait: 6)
        return await session.pageTitle()
    }
}

extension FormRun {

    @MainActor
    static func run(url: URL?, html: String?, plan: FillPlan, dryRun: Bool, maxWait: TimeInterval, capture: Bool = false) async -> SubmitEvidence {
        let session = WebViewSession.make()
        defer { session.close() }
        do {
            if let html { try await session.loadHTML(html) }
            else if let url, url.scheme == "https" { try await session.load(URLRequest(url: url)) }
            else { return SubmitEvidence(outcome: .failed("not a secure page")) }
        } catch { return SubmitEvidence(outcome: .failed("the page would not load")) }
        let outcome = await steps(session, plan: plan, dryRun: dryRun, maxWait: maxWait)
        // What the page shows at the end: the confirmation, or whatever stopped the form.
        return SubmitEvidence(outcome: outcome, screenshot: capture ? await session.screenshotJPEG() : nil)
    }

    @MainActor
    private static func steps(_ session: WebViewSession, plan: FillPlan, dryRun: Bool, maxWait: TimeInterval) async -> SubmitOutcome {
        await session.settlePage(maxWait: 10)
        _ = await session.declineBanner()

        if await session.pageLooksMissing() { return .failed(FormRun.pageGone) }
        if await session.hasTermsPrompt() { return .challenged("a terms prompt that you need to accept yourself") }
        if let why = await session.visibleChallenge() { return .challenged(why) }

        let filled = await session.fillFields(plan.values)
        if filled == 0 { return .failed("the form's fields were not on the page") }
        if dryRun { return .filledNotSubmitted }
        if await session.pendingCertification() != nil { return .challenged("a certification box that you must tick yourself") }

        let before = await session.visibleText()
        guard await session.pressSubmit(for: plan.values) else { return .failed("no submit button found") }
        await session.settlePage(maxWait: maxWait)
        if let why = await session.visibleChallenge() { return .challenged(why) }
        // Only what appeared after sending counts: a page that already said "request received" somewhere (hidden templates, footers,
        // policy text) is not a confirmation.
        return WebFormSubmitter.classifyAfterSending(before: before, after: await session.visibleText())
    }
}

extension WebViewSession {
    func settlePage(maxWait: TimeInterval) async { await settle(maxWait: maxWait) }

    /// A picture of the page as it is now, as a compressed JPEG. The web view is kept at phone size, so the picture reads like a
    /// phone screen.
    func screenshotJPEG(quality: CGFloat = 0.6, aroundForm token: String? = nil) async -> Data? {
        if webView.frame.isEmpty { webView.frame = CGRect(x: 0, y: 0, width: 390, height: 800) }
        // The web view is kept almost invisible in a hidden window; a snapshot would inherit that and come out nearly transparent.
        let previousAlpha = webView.alpha
        webView.alpha = 1
        defer { webView.alpha = previousAlpha }
        // Capture the whole page (up to a limit), so the result a site shows below the form is in the picture.
        let pageHeight = ((try? await webView.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)")) as? Double) ?? 800
        let originalFrame = webView.frame
        // A snapshot taller than about 8000 pixels comes out blank, so a long page is cropped to a window around the form.
        let capHeight: CGFloat = 2400
        let fullHeight = min(max(800, CGFloat(pageHeight)), 6000)
        // Resized and made opaque only while off the screen, so the person never sees the page flash up behind the app.
        webView.frame = CGRect(x: -10_000, y: 0, width: originalFrame.width, height: fullHeight)
        defer { webView.frame = originalFrame }
        try? await Task.sleep(nanoseconds: 400_000_000)
        var top: CGFloat = 0
        if let token, let y = (try? await webView.evaluateJavaScript(PageScript.call("form-top", token))) as? Double {
            top = max(0, CGFloat(y) - 200)
        }
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: min(top, max(0, fullHeight - 800)), width: webView.bounds.width, height: min(capHeight, fullHeight - min(top, max(0, fullHeight - 800))))
        guard let image = try? await webView.takeSnapshot(configuration: config) else { return nil }
        // A page without its own background snapshots with transparency, which a JPEG shows as black: paint it on white first.
        let flat = UIGraphicsImageRenderer(size: image.size).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: image.size))
            image.draw(at: .zero)
        }
        return flat.jpegData(compressionQuality: quality)
    }

    /// True when the page just loaded is an error page, which means the recorded link has moved or died.
    func pageLooksMissing() async -> Bool {
        let text = await visibleText()
        return LinkRules.isErrorPage(PageSnapshot(url: webView.url ?? URL(string: "https://invalid.example")!, status: httpStatus,
                                                  title: String(text.prefix(120)), text: text))
    }
    func declineBanner() async -> Bool { await declineConsentBanner() }
    func hasTermsPrompt() async -> Bool { await findTermsGate() != nil }

    /// Brings the human check into view so the person does not have to hunt for it.
    func scrollChallengeIntoView() async {
        let js = PageScript.source("scroll-challenge-into-view")
        _ = try? await webView.evaluateJavaScript(js)
    }

    func pageTitle() async -> String { (try? await webView.evaluateJavaScript("document.title")) as? String ?? "" }

    /// True when the page changed on screen since the last call and has been still for a moment (a window opened, the next step appeared, a message showed).
    /// A watcher inside the page (a MutationObserver) records changes at no cost while nothing happens; the app asks for the flag every second or so.
    /// A page that has just loaded, or has no watcher yet, counts as changed. Marks the app puts on the form (`data-ook`) are not changes.
    /// True while the person has the cursor in a box on the page and has touched or typed in the last 45 seconds: nothing may be clicked, scrolled or filled then.
    func userIsTyping() async -> Bool {
        let js = PageScript.source("user-is-typing")
        return (try? await webView.evaluateJavaScript(js)) as? Bool ?? false
    }

    /// How many times the person pressed a button, link or Enter on the page (this page load), or nil if it cannot be read.
    func userPresses() async -> Int? { (try? await webView.evaluateJavaScript("window.__ookPress||0")) as? Int }

    func pageChanged() async -> Bool {
        let js = PageScript.source("page-changed")
        var changed = (try? await webView.evaluateJavaScript(js)) as? Bool ?? false
        if let f = activeFrame, (try? await webView.evaluateJavaScript(js, in: f, contentWorld: .page)) as? Bool == true { changed = true }
        return changed
    }

    /// The text currently on screen (what is inside the viewport), from the page and from the frame the form is in. Cheap enough to read every few seconds.
    func viewportText() async -> String {
        let js = PageScript.source("viewport-text")
        let page = (try? await webView.evaluateJavaScript(js)) as? String ?? ""
        guard let f = activeFrame else { return page }
        let inside = (try? await webView.evaluateJavaScript(js, in: f, contentWorld: .page)) as? String ?? ""
        return inside.isEmpty ? page : page + "\n" + inside
    }

    func visibleText() async -> String {
        let page = (try? await webView.evaluateJavaScript("document.title + '\\n' + (document.body ? document.body.innerText : '')")) as? String ?? ""
        // The answer a site gives after sending often appears inside the frame the form was in.
        guard let f = activeFrame else { return page }
        let inside = (try? await webView.evaluateJavaScript("document.body ? document.body.innerText : ''", in: f, contentWorld: .page)) as? String ?? ""
        return inside.isEmpty ? page : page + "\n" + inside
    }

    /// A human check a person has to act on, as opposed to an invisible one that passes by itself. Never solved here.
    func visibleChallenge() async -> String? {
        let js = PageScript.source("visible-challenge")
        return (try? await webView.evaluateJavaScript(js)) as? String
    }

    /// The text of an unticked checkbox that asks the person to certify, authorize or acknowledge something. Only they can tick it:
    /// a certification made for someone by software is not theirs. Nil when there is none.
    func pendingCertification() async -> String? {
        let js = PageScript.source("pending-certification")
        return (try? await webView.evaluateJavaScript(js)) as? String
    }

    /// Ticks unticked boxes that only say "I confirm that I am the person associated with this email": a plain statement about the
    /// account owner, who allowed it. Legal certifications, agent statements and terms are left alone (same rule as
    /// `FormFiller.isSelfIdentityBox`). Returns how many were ticked.
    func tickIdentityBoxes() async -> Int {
        let js = PageScript.source("tick-identity-boxes")
        return ((try? await webView.evaluateJavaScript(js)) as? Int) ?? 0
    }

    /// Puts each value into its field, matching a dropdown's options by code or name. Returns how many fields were filled.
    func fillFields(_ allValues: [FieldValue]) async -> Int {
        if allValues.contains(where: { $0.type == FormFiller.confirmIdentityType }) { _ = await tickIdentityBoxes() }
        let values = allValues.filter { $0.type != FormFiller.confirmIdentityType }
        let payload = values.map { ["name": $0.name, "candidates": $0.candidates] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return 0 }
        let js = PageScript.call("fill-fields", json: [json])
        return ((try? await webView.evaluateJavaScript(js)) as? Int) ?? 0
    }

    /// Presses the form's own submit button (never one that says agree or accept), or submits the form directly.
    func pressSubmit(for values: [FieldValue]) async -> Bool {
        let first = values.first?.name ?? ""
        let js = PageScript.call("press-submit", first)
        let pressed = ((try? await webView.evaluateJavaScript(js)) as? Bool) ?? false
        if pressed { SiteRun.markSent?() }          // a background run's watchdog now knows the form went to the site (`SiteRun`)
        return pressed
    }

}

// MARK: Reading a page's links and forms, for finding a moved opt-out page

/// Describes a page from its live DOM, so pages built by JavaScript can be read too. Used by the link finder to heal moved links.
struct WebPageInspector: PageInspector {
    var maxWait: TimeInterval = 8

    func snapshot(_ url: URL) async -> PageSnapshot? {
        guard url.scheme == "https" else { return nil }
        return await WebInspection.run(url: url, html: nil, maxWait: maxWait)
    }

    /// Test hook: describe HTML the test supplies.
    func snapshot(html: String, url: URL) async -> PageSnapshot? {
        await WebInspection.run(url: url, html: html, maxWait: maxWait)
    }
}

@MainActor
private enum WebInspection {
    static func run(url: URL, html: String?, maxWait: TimeInterval) async -> PageSnapshot? {
        let session = WebViewSession.make()
        defer { session.close() }
        do {
            if let html { try await session.loadHTML(html) } else { try await session.load(URLRequest(url: url)) }
        } catch { return nil }
        await session.settlePage(maxWait: maxWait)
        _ = await session.declineBanner()
        return await session.describePage(fallbackURL: url)
    }
}

extension WebViewSession {
    /// The title, visible text, links and forms of the current page.
    func describePage(fallbackURL: URL) async -> PageSnapshot? {
        let js = PageScript.source("describe-page")
        guard let json = (try? await webView.evaluateJavaScript(js)) as? String, let data = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let links = (o["links"] as? [[String: Any]] ?? []).compactMap { l -> LinkSnapshot? in
            guard let h = (l["href"] as? String).flatMap(URL.init(string:)) else { return nil }
            return LinkSnapshot(href: h, text: l["text"] as? String ?? "")
        }
        let forms = (o["forms"] as? [[String: Any]] ?? []).map { f -> FormSnapshot in
            let fields = (f["fields"] as? [[String: Any]] ?? []).map { FormField(type: $0["type"] as? String ?? "text", name: $0["name"] as? String ?? "", label: $0["label"] as? String ?? "") }
            return FormSnapshot(action: (f["action"] as? String).flatMap(URL.init(string:)), method: f["method"] as? String ?? "get",
                                fields: fields, hasSubmit: f["hasSubmit"] as? Bool ?? false)
        }
        return PageSnapshot(url: (o["url"] as? String).flatMap(URL.init(string:)) ?? fallbackURL, status: httpStatus,
                            title: o["title"] as? String ?? "", text: o["text"] as? String ?? "", links: links, forms: forms)
    }
}


/// Which background-run site the web views made now belong to, so they report the page's signs of life to that run's watchdog.
enum PageActivity {
    @TaskLocal static var report: (@Sendable () -> Void)?
    /// The web views made for that site, so they can be ended when the run gives the site up.
    @TaskLocal static var bin: SessionBin?
}

/// The web views one background-run site made. When the run gives the site up (its work is cancelled), they are all ended (`WebViewSession.abandon`).
@MainActor
final class SessionBin {
    private var sessions: [WeakSession] = []
    private(set) var ended = false
    func add(_ s: WebViewSession) {
        if ended { s.abandon(); return }
        sessions.append(WeakSession(s))
    }
    func abandonAll() {
        ended = true
        for s in sessions { s.value?.abandon() }
        sessions = []
    }
    private struct WeakSession { weak var value: WebViewSession?; init(_ v: WebViewSession) { value = v } }
}

extension WebViewSession {
    /// Posts (at most once a second) when the page changes or a request it made comes back. Added only for a background run's site.
    static let activityScript = PageScript.source("activity")
}

/// Hands the page's signs of life to its session.
private final class ActivityReporter: NSObject, WKScriptMessageHandler {
    weak var session: WebViewSession?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in self.session?.touch() }
    }
}

/// Receives the report each frame with inputs sends, and hands its frame handle to the session.
private final class FrameReporter: NSObject, WKScriptMessageHandler {
    weak var session: WebViewSession?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let href = body["href"] as? String else { return }
        let info = message.frameInfo
        Task { @MainActor in self.session?.noteFrameFromReporter(info, href: href) }
    }
}

extension WebViewSession {
    @MainActor func noteFrameFromReporter(_ info: WKFrameInfo, href: String) { frames.removeAll { $0.href == href }; frames.append((info, href)) }
}
