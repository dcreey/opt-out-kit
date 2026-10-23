import UIKit
import WebKit
import OptOutKitCore

/// Reads pages the way a browser does: it loads them in a hidden WKWebView, lets their JavaScript run, waits for the
/// page to stop changing, then returns what a person would see. This reaches sites whose results arrive after a
/// "loading" page, which a plain request cannot read. Each fetch gets its own private session (no cookies kept, none
/// shared), and nothing is shown on screen. A site that shows a bot check still shows it; we report that, never solve it.
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
final class WebViewSession: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var status = 200
    private var loadContinuation: CheckedContinuation<Void, Error>?

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
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: config)
        super.init()
        webView.navigationDelegate = self
        // Some pages only run timers while attached to a window, so park it invisibly in the key window.
        webView.alpha = 0.01
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        (scene?.keyWindow ?? scene?.windows.first)?.addSubview(webView)
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

    private static let gatePattern = #"acceptable use policy|by clicking [“"']?i agree|i agree.{0,120}(terms|policy)|accept (the )?terms|you must agree|j'accepte.{0,120}(conditions|politique)|accepter les conditions|acepto.{0,120}(términos|condiciones|política)|aceptar los términos|ich stimme.{0,120}(bedingungen|datenschutz)|nutzungsbedingungen akzeptieren"#

    /// The prompt text (the smallest element that holds the gate wording) and the same-site terms and privacy pages it links
    /// to. Nothing is clicked here.
    private func findTermsGate() async -> (prompt: String, links: [URL])? {
        let js = #"""
        (function(re){var rx=new RegExp(re,'i'),best=null;
        document.querySelectorAll('div,section,form,dialog,[role=dialog]').forEach(function(el){var t=el.innerText||'';
          if(rx.test(t)&&t.length<9000&&(!best||t.length<best.innerText.length))best=el;});
        if(!best)return null;
        var agree=/^\s*(i agree|i accept|agree|accept|j'accepte|accepter|tout accepter|acepto|aceptar|ich stimme zu|zustimmen|akzeptieren)\s*$/i,hasButton=false;
        for(var up=best,d=0;up&&d<4&&!hasButton;up=up.parentElement,d++){
          var bs=up.querySelectorAll('button,a,[role=button],input[type=button],input[type=submit]');
          for(var i=0;i<bs.length;i++){var t=(bs[i].innerText||bs[i].value||'');if(agree.test(t)){hasButton=true;break;}}}
        if(!hasButton)return null;   // acceptable-use text in a page footer is not a prompt: nothing to accept
        var host=location.hostname.split('.').slice(-2).join('.'),links=[];
        document.querySelectorAll('a[href]').forEach(function(a){
          if(/terms|acceptable use|privacy|conditions|confidentialit|mentions l[ée]gales|t[ée]rminos|condiciones|privacidad|nutzungsbedingungen|datenschutz|agb/i.test((a.innerText||'')+' '+a.href)&&a.hostname.split('.').slice(-2).join('.')===host)links.push(a.href);});
        return JSON.stringify({prompt:best.innerText,links:links.slice(0,4)});})(\#(Self.jsString(Self.gatePattern)));
        """#
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
        let js = #"""
        (function(re){var rx=new RegExp(re,'i'),el=null;
        document.querySelectorAll('div,section,form,dialog,[role=dialog]').forEach(function(e){var t=e.innerText||'';
          if(rx.test(t)&&t.length<9000&&(!el||t.length<el.innerText.length))el=e;});
        var agree=/^\s*(i agree|i accept|agree|accept|j'accepte|accepter|tout accepter|acepto|aceptar|ich stimme zu|zustimmen|akzeptieren)\s*$/i;
        for(var up=el,d=0;up&&d<4;up=up.parentElement,d++){
          var bs=up.querySelectorAll('button,a,[role=button],input[type=button],input[type=submit]');
          for(var i=0;i<bs.length;i++){var t=(bs[i].innerText||bs[i].value||'');if(agree.test(t)){bs[i].click();return true;}}}
        return false;})(\#(Self.jsString(Self.gatePattern)));
        """#
        return ((try? await webView.evaluateJavaScript(js)) as? Bool) ?? false
    }

    /// Cookie and tracking banners hide the page behind a prompt. We always pick the most private option
    /// ("Reject all", "Decline") and never "Accept". Returns true if a button was clicked.
    private func declineConsentBanner() async -> Bool {
        let js = """
        (function(){var re=/^\\s*(reject all|reject|decline|deny|no thanks|only necessary|necessary only|tout refuser|refuser|continuer sans accepter|rechazar todo|rechazar|solo necesarias|alle ablehnen|ablehnen|nur notwendige)\\s*$/i;
        var els=document.querySelectorAll('button,a,div,span,[role=button],input[type=button]');
        for(var i=0;i<els.length;i++){var t=(els[i].innerText||els[i].value||'').trim();
        if(re.test(t)){els[i].click();return true;}}return false;})();
        """
        return ((try? await webView.evaluateJavaScript(js)) as? Bool) ?? false
    }

    // MARK: Loading

    func load(_ request: URLRequest) async throws {
        // Ask for the site in the language the person chose, so a site that has its terms and forms in that language shows them.
        var request = request
        if request.value(forHTTPHeaderField: "Accept-Language") == nil {
            request.setValue("\(Loc.language),en;q=0.5", forHTTPHeaderField: "Accept-Language")
        }
        try await wait { self.webView.load(request) }
    }

    func loadHTML(_ html: String) async throws {
        try await wait { self.webView.loadHTMLString(html, baseURL: URL(string: "https://example.invalid/")) }
    }

    func submitForm(action: URL, body: String) async throws {
        let fields = body.split(separator: "&").map { pair -> [String] in
            let p = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return [p.first?.removingPercentEncoding ?? "", (p.count > 1 ? p[1] : "").removingPercentEncoding ?? ""]
        }
        let json = String(data: try JSONSerialization.data(withJSONObject: fields), encoding: .utf8) ?? "[]"
        let js = """
        (function(){var f=document.createElement('form');f.method='POST';f.action=\(Self.jsString(action.absoluteString));
        \(json).forEach(function(kv){var i=document.createElement('input');i.type='hidden';i.name=kv[0];i.value=kv[1];f.appendChild(i);});
        document.body.appendChild(f);f.submit();})();
        """
        try await wait { self.webView.evaluateJavaScript(js, completionHandler: nil) }
    }

    private static func jsString(_ s: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [s]), encoding: .utf8))?.dropFirst().dropLast().description ?? "\"\""
    }

    private func wait(_ start: () -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loadContinuation = c
            start()
        }
    }

    /// Waits until the visible text stops changing, so "loading..." screens give way to the real results.
    private func settle(maxWait: TimeInterval) async {
        let deadline = Date().addingTimeInterval(maxWait)
        var last = -1, stable = 0
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let probe = (try? await webView.evaluateJavaScript("(document.readyState||'') + '|' + (document.body ? document.body.innerText : '')")) as? String ?? ""
            let ready = probe.hasPrefix("complete|")
            let loading = probe.lowercased().contains("loading") || probe.lowercased().contains("please wait") || probe.lowercased().contains("searching")
            if ready && probe.count == last && !loading { stable += 1 } else { stable = 0 }
            last = probe.count
            if stable >= 4 { return }          // two quiet seconds
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse { status = http.statusCode }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resume(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resume(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resume(error) }

    private func resume(_ error: Error?) {
        guard let c = loadContinuation else { return }
        loadContinuation = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}

// MARK: Opt-out forms

/// Fills in a site's real opt-out form from a person's profile and sends it. It stops, and says so, at anything a person
/// must handle: a visible bot check, a terms prompt, a form it cannot fill. It never solves a challenge, never ticks a
/// legal acknowledgement, and only reports "sent" when the site shows a success message.
extension WebFormSubmitter {
    /// What the page said after sending, judged only on the lines that were not there before.
    nonisolated static func classifyAfterSending(before: String, after: String) -> SubmitOutcome {
        let added = FormRun.newText(before: before, after: after)
        if added.isEmpty { return .failed("nothing on the page changed after sending") }
        return FormRun.classify(added)
    }
}

struct WebFormSubmitter: FormSubmitter {
    var maxWait: TimeInterval = 20

    func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome {
        await FormRun.run(url: form.page, html: nil, plan: plan, dryRun: dryRun, maxWait: maxWait, capture: false).outcome
    }

    /// Fills and sends the form in a hidden web view, then takes a screenshot of whatever the page showed at the end.
    func submitCapturing(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitEvidence {
        await FormRun.run(url: form.page, html: nil, plan: plan, dryRun: dryRun, maxWait: maxWait, capture: !dryRun)
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

enum FormRun {
    /// The failure text for a page that is gone, so callers can tell a moved link from other failures and try to heal it.
    static let pageGone = "the page was gone (not found)"

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

    /// The lines of `after` that were not in `before`.
    nonisolated static func newText(before: String, after: String) -> String {
        let seen = Set(before.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        return after.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !seen.contains($0) }.joined(separator: "\n")
    }

    nonisolated static func classify(_ text: String) -> SubmitOutcome {
        let t = text.lowercased()
        // An error comes first: "problem with your submission" pages often also contain the word "request".
        if t.range(of: "problem with your submission|review the fields|fields? (have|has) an error|error occurred|something went wrong|please (try again|correct)|is required|invalid|could not be (processed|verified)", options: .regularExpression) != nil {
            return .rejected("the site showed an error after sending")
        }
        let success = t.range(of: "request (has been |was )?(received|submitted|processed|sent)|we have received|has been (received|submitted|processed)|check your (e-?mail|inbox)|confirm your (e-?mail|request)|sent you an? e-?mail|verification (e-?mail|link)|allow up to [0-9]+ days|will be (removed|processed|deleted)|opt-?out (has been|was) (received|processed|successful)", options: .regularExpression) != nil
        let needsEmail = t.range(of: "check your (e-?mail|inbox)|confirm your (e-?mail|request)|sent you an? e-?mail|verification (e-?mail|link)|click the link", options: .regularExpression) != nil
        if success { return .submitted(awaitingEmail: needsEmail) }
        if t.range(of: "please enter|please provide", options: .regularExpression) != nil {
            return .rejected("the site flagged a field or asked to try again")
        }
        return .failed("no success message was shown")
    }
}

extension WebViewSession {
    func settlePage(maxWait: TimeInterval) async { await settle(maxWait: maxWait) }

    /// A picture of the page as it is now, as a compressed JPEG. The web view is kept at phone size, so the picture reads like a
    /// phone screen.
    func screenshotJPEG(quality: CGFloat = 0.6) async -> Data? {
        if webView.frame.isEmpty { webView.frame = CGRect(x: 0, y: 0, width: 390, height: 800) }
        // The web view is kept almost invisible in a hidden window; a snapshot would inherit that and come out nearly transparent.
        let previousAlpha = webView.alpha
        webView.alpha = 1
        defer { webView.alpha = previousAlpha }
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
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

    /// Brings the bot check into view so the person does not have to hunt for it.
    func scrollChallengeIntoView() async {
        let js = #"""
        (function(){var f=[].slice.call(document.querySelectorAll('iframe')).filter(function(x){
          return /recaptcha|hcaptcha|challenges\.cloudflare\.com/.test(x.src||'');})[0];
          if(f){f.scrollIntoView({block:'center',behavior:'instant'});return true;} return false;})();
        """#
        _ = try? await webView.evaluateJavaScript(js)
    }

    func pageTitle() async -> String { (try? await webView.evaluateJavaScript("document.title")) as? String ?? "" }

    func visibleText() async -> String {
        (try? await webView.evaluateJavaScript("document.title + '\\n' + (document.body ? document.body.innerText : '')")) as? String ?? ""
    }

    /// A bot check a person has to act on, as opposed to an invisible one that passes by itself. Never solved here.
    func visibleChallenge() async -> String? {
        let js = #"""
        (function(){
          var text=(document.body?document.body.innerText:'').toLowerCase();
          if(/verify you are human|are you a human|checking your browser|just a moment|security challenge|performing security verification|v[ée]rifiez que vous [êe]tes humain|v[ée]rification de s[ée]curit[ée]|verifica que eres humano|comprobaci[oó]n de seguridad|best[äa]tigen sie, dass sie ein mensch|sicherheits[üu]berpr[üu]fung/.test(text)) return 'a bot check';
          var frames=document.querySelectorAll('iframe');
          for(var i=0;i<frames.length;i++){var f=frames[i],src=f.src||'',r=f.getBoundingClientRect();
            if(r.width<40||r.height<40) continue;
            if(f.closest&&f.closest('.grecaptcha-badge')) continue;
            if(/recaptcha\/(api2|enterprise)\/bframe/.test(src)) return 'a reCAPTCHA puzzle';
            if(/recaptcha\/(api2|enterprise)\/anchor/.test(src)){var ta=document.querySelector('textarea[name="g-recaptcha-response"]'); if(!ta||!ta.value) return 'a reCAPTCHA checkbox';}
            if(/hcaptcha\.com/.test(src)){var h=document.querySelector('textarea[name="h-captcha-response"]'); if(!h||!h.value) return 'an hCaptcha';}
            if(/challenges\.cloudflare\.com/.test(src)){var t=document.querySelector('input[name="cf-turnstile-response"]'); if(!t||!t.value) return 'a Cloudflare check';}
          }
          return null;})();
        """#
        return (try? await webView.evaluateJavaScript(js)) as? String
    }

    /// The text of an unticked checkbox that asks the person to certify, authorize or acknowledge something. Only they can tick it:
    /// a certification made for someone by software is not theirs. Nil when there is none.
    func pendingCertification() async -> String? {
        let js = #"""
        (function(){var re=/acknowledg|certif|attest|authori[sz]e|i agree|i accept|consent|under penalty|on behalf|je certifie|j'atteste|je reconnais|j'accepte|consentement|certifico|atesto|reconozco|acepto|consentimiento|ich best[äa]tige|ich versichere|einwilligung|zustimmung|ich stimme/i,out=null;
          document.querySelectorAll('input[type=checkbox]').forEach(function(c){
            if(c.checked||out) return;
            var t='';
            if(c.id){var l=document.querySelector('label[for="'+c.id+'"]'); if(l) t=l.innerText;}
            if(!t){var p=c.closest('label'); if(p) t=p.innerText;}
            if(!t){var n=c.parentElement; t=n?n.innerText:'';}
            // "I am an authorized agent submitting on behalf of someone else" is an option for agents, not a requirement for the subject.
            if(re.test(t)&&!/\bagent\b|on behalf of (someone|another)|representative|mandataire|repr[ée]sentant|au nom d|agente|representante|en nombre de|bevollm[äa]chtigt|im namen/i.test(t)) out=t.replace(/\s+/g,' ').trim().slice(0,140);});
          return out;})();
        """#
        return (try? await webView.evaluateJavaScript(js)) as? String
    }

    /// Ticks unticked boxes that only say "I confirm that I am the person associated with this email": a plain statement about the
    /// account owner, who allowed it. Legal certifications, agent statements and terms are left alone (same rule as
    /// `FormFiller.isSelfIdentityBox`). Returns how many were ticked.
    func tickIdentityBoxes() async -> Int {
        let js = #"""
        (function(){var yes=/\bi (confirm|verify|am)\b.{0,60}\b(person|owner|me)\b.{0,40}(email|e-mail|address|account|request|record)/i,
              no=/penalty|perjury|agent|behalf|representative|authori[sz]ed to|attest|acknowledg|certif|terms|privacy policy|legal/i,n=0,
              ack=/may be required to verify my identity.{0,200}authori[sz]e .{0,60} to contact me/i,notAck=/terms|privacy policy|\bsell|market|newsletter|advertis|share my|third part/i;
          document.querySelectorAll('input[type=checkbox]').forEach(function(c){
            if(c.checked) return;
            var t='';
            if(c.id){var l=document.querySelector('label[for="'+c.id+'"]'); if(l) t=l.innerText;}
            if(!t){var p=c.closest('label'); if(p) t=p.innerText;}
            if(!t){var q=c.parentElement; t=q?q.innerText:'';}
            t=t.replace(/\s+/g,' ').trim();
            if((yes.test(t)&&!no.test(t))||(ack.test(t)&&!notAck.test(t))){c.click(); if(!c.checked){c.checked=true; c.dispatchEvent(new Event('change',{bubbles:true}));} n++;}});
          return n;})();
        """#
        return ((try? await webView.evaluateJavaScript(js)) as? Int) ?? 0
    }

    /// Puts each value into its field, matching a dropdown's options by code or name. Returns how many fields were filled.
    func fillFields(_ allValues: [FieldValue]) async -> Int {
        if allValues.contains(where: { $0.type == FormFiller.confirmIdentityType }) { _ = await tickIdentityBoxes() }
        let values = allValues.filter { $0.type != FormFiller.confirmIdentityType }
        let payload = values.map { ["name": $0.name, "candidates": $0.candidates] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return 0 }
        let js = #"""
        (function(values){var filled=0;
        function setValue(el,v){var proto=el.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
          var d=Object.getOwnPropertyDescriptor(proto,'value'); if(d&&d.set){d.set.call(el,v);}else{el.value=v;}
          el.dispatchEvent(new Event('input',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true}));}
        values.forEach(function(v){
          var el=document.querySelector('[name="'+v.name.replace(/"/g,'\"')+'"]')||document.getElementById(v.name); if(!el) return;
          if(el.tagName==='SELECT'){var done=false;
            for(var c=0;c<v.candidates.length&&!done;c++){var want=v.candidates[c].toLowerCase();
              for(var i=0;i<el.options.length;i++){var o=el.options[i];
                if(o.value.toLowerCase()===want||o.text.trim().toLowerCase()===want){el.value=o.value;done=true;break;}}}
            if(done){el.dispatchEvent(new Event('change',{bubbles:true}));filled++;}
          } else {setValue(el,v.candidates[0]);filled++;}
        });
        return filled;})(\#(json));
        """#
        return ((try? await webView.evaluateJavaScript(js)) as? Int) ?? 0
    }

    /// Presses the form's own submit button (never one that says agree or accept), or submits the form directly.
    func pressSubmit(for values: [FieldValue]) async -> Bool {
        let first = values.first?.name ?? ""
        let js = #"""
        (function(name){
          var el=document.querySelector('[name="'+name.replace(/"/g,'\"')+'"]')||document.getElementById(name);
          var form=el&&el.form; if(!form) return false;
          var buttons=form.querySelectorAll('button,input[type=submit],input[type=button]');
          for(var i=0;i<buttons.length;i++){var b=buttons[i],t=(b.innerText||b.value||'').trim();
            if(/agree|accept/i.test(t)) continue;
            var type=(b.getAttribute('type')||'submit').toLowerCase();
            if(type==='submit'){b.click();return true;}}
          if(form.requestSubmit){form.requestSubmit();return true;}
          form.submit();return true;})(\#(Self.jsLiteral(first)));
        """#
        return ((try? await webView.evaluateJavaScript(js)) as? Bool) ?? false
    }

    private static func jsLiteral(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]), let j = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(j.dropFirst().dropLast())
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
        let js = #"""
        (function(){
          function abs(h){try{return new URL(h,location.href).href}catch(e){return null}}
          var links=[].slice.call(document.querySelectorAll('a[href]')).map(function(a){return {href:abs(a.getAttribute('href')),text:(a.innerText||'').trim().slice(0,120)};}).filter(function(l){return l.href;});
          var forms=[].slice.call(document.forms).map(function(f){
            var fields=[],hasSubmit=!!f.querySelector('button,input[type=submit]');
            [].slice.call(f.elements).forEach(function(el){
              var t=(el.type||el.tagName||'').toLowerCase();
              if(['hidden','submit','button','image','reset','fieldset','object','output'].indexOf(t)>=0) return;
              var label=''; if(el.id){var l=document.querySelector('label[for="'+el.id+'"]'); if(l) label=l.innerText;}
              if(!label) label=el.placeholder||el.getAttribute('aria-label')||el.name||'';
              fields.push({type:t==='select-one'?'select':t,name:el.name||el.id||'',label:String(label).replace(/\s+/g,' ').trim().slice(0,60)});});
            var a=f.getAttribute('action');
            return {action:a?abs(a):location.href,method:(f.method||'get').toLowerCase(),fields:fields,hasSubmit:hasSubmit};});
          return JSON.stringify({url:location.href,title:document.title||'',text:(document.body?document.body.innerText:'').slice(0,4000),links:links.slice(0,300),forms:forms});
        })();
        """#
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
