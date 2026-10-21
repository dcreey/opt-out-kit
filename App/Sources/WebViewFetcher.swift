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
private final class WebViewSession: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var status = 200
    private var loadContinuation: CheckedContinuation<Void, Error>?

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

    private static let gatePattern = #"acceptable use policy|by clicking [“"']?i agree|i agree.{0,120}(terms|policy)|accept (the )?terms|you must agree"#

    /// The prompt text (the smallest element that holds the gate wording) and the same-site terms and privacy pages it links
    /// to. Nothing is clicked here.
    private func findTermsGate() async -> (prompt: String, links: [URL])? {
        let js = #"""
        (function(re){var rx=new RegExp(re,'i'),best=null;
        document.querySelectorAll('div,section,form,dialog,[role=dialog]').forEach(function(el){var t=el.innerText||'';
          if(rx.test(t)&&t.length<9000&&(!best||t.length<best.innerText.length))best=el;});
        if(!best)return null;
        var host=location.hostname.split('.').slice(-2).join('.'),links=[];
        document.querySelectorAll('a[href]').forEach(function(a){
          if(/terms|acceptable use|privacy/i.test((a.innerText||'')+' '+a.href)&&a.hostname.split('.').slice(-2).join('.')===host)links.push(a.href);});
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
        var agree=/^\s*(i agree|i accept|agree|accept)\s*$/i;
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
        (function(){var re=/^\\s*(reject all|reject|decline|deny|no thanks|only necessary|necessary only)\\s*$/i;
        var els=document.querySelectorAll('button,a,div,span,[role=button],input[type=button]');
        for(var i=0;i<els.length;i++){var t=(els[i].innerText||els[i].value||'').trim();
        if(re.test(t)){els[i].click();return true;}}return false;})();
        """
        return ((try? await webView.evaluateJavaScript(js)) as? Bool) ?? false
    }

    // MARK: Loading

    func load(_ request: URLRequest) async throws {
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
