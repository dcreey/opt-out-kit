import XCTest
import WebKit
import OptOutKitCore
@testable import OptOutKit

/// The Spokeo semi-automated flow on the real site, end to end, WITHOUT sending: search for the person, pick a listing, open the
/// opt-out form, fill it in, show the bot check. The page's send is replaced by one that cannot send. Runs only when asked:
/// TEST_RUNNER_OPTOUT_LIVE=1. The profile is made up; the name is a common one so the search has results to pick from.
@MainActor
final class LiveSpokeoFlowTests: XCTestCase {
    /// A real browser page whose send never reaches the site.
    final class NoSendPage: GuidedPage {
        let inner = WebGuidedPage()
        private(set) var sendAttempts = 0
        var webView: WKWebView? { inner.webView }
        func load(_ url: URL) async { await inner.load(url) }
        func currentURL() -> URL? { inner.currentURL() }
        func visibleText() async -> String { await inner.visibleText() }
        func fill(_ values: [FieldValue]) async -> Int { await inner.fill(values) }
        func blockers() async -> [AssistedBlocker] { await inner.blockers() }
        func send(_ values: [FieldValue]) async -> SubmitOutcome { sendAttempts += 1; return .filledNotSubmitted }
        func close() { inner.close() }
    }
    struct Maker: GuidedPageMaker { let page: NoSendPage; func make() -> GuidedPage { page } }

    private func js(_ web: WKWebView, _ script: String) async -> Any? { try? await web.evaluateJavaScript(script) }

    private func shot(_ web: WKWebView, _ name: String) async {
        web.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        if let image = try? await web.takeSnapshot(configuration: nil) {
            let a = XCTAttachment(image: image); a.name = name; a.lifetime = .keepAlways; add(a)
        }
    }

    private func waitUntil(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if await condition() { return true }; try? await Task.sleep(nanoseconds: 500_000_000) }
        return false
    }

    func testSpokeoFromSearchToAFilledFormWithoutSending() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPTOUT_LIVE"] == "1", "set TEST_RUNNER_OPTOUT_LIVE=1 to run")
        let model = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                             defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        var me = try XCTUnwrap(model.selectedPerson)
        me.names = [NameEntry(kind: .legal, name: "John Smith")]
        me.addresses = [Address(street: "1 Main St", city: "Chicago", state: "IL", zip: "62701")]
        XCTAssertTrue(me.isComplete)
        model.update(me)
        model.setContactEmail("pat@gmail.com")          // forms get pat+optoutkit@gmail.com

        let page = NoSendPage()
        model.guidedPageMakerOverride = Maker(page: page)
        let spokeo = try XCTUnwrap(model.brokers.first { $0.id == "spokeo" })
        let runner = try XCTUnwrap(model.guidedRunner(for: spokeo))
        XCTAssertEqual(runner.flow.plan.steps.first?.title, "Open your own listing")
        let task = Task { await runner.run() }
        defer { runner.cancel(); page.close() }

        // 1. The app searched Spokeo for the person.
        _ = await waitUntil(40) { page.currentURL()?.host?.contains("spokeo.com") == true }
        let web = try XCTUnwrap(page.webView)
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let searchURL = try XCTUnwrap(page.currentURL())
        print("LIVESPOKEO search page: \(searchURL.absoluteString)")
        XCTAssertTrue(searchURL.path.lowercased().contains("john-smith"), "searched for the profile's name")
        await shot(web, "1-search-results")

        // 2. The person taps their listing: here, the first result link that is a person's page.
        let links = (await js(web, """
            (function(){var out=[];document.querySelectorAll('a[href]').forEach(function(a){var h=a.href;
              if(/^https:\\/\\/www\\.spokeo\\.com\\/[^\\/?#]+\\/[^\\/?#]+\\/[^\\/?#]+/.test(h) && !/privacy|optout|terms|about|search|help|blog|login/.test(h)) out.push(h);});
            return JSON.stringify(Array.from(new Set(out)).slice(0,8));})();
            """) as? String) ?? "[]"
        print("LIVESPOKEO candidate links: \(links)")
        let candidates = (try? JSONDecoder().decode([String].self, from: Data(links.utf8))) ?? []
        let target = try XCTUnwrap(candidates.first, "no person link found on the results page; see the screenshot")
        _ = await js(web, "(function(){var a=Array.from(document.querySelectorAll('a[href]')).find(function(x){return x.href==='\(target)'}); if(a) a.click(); else location.href='\(target)'; })();")
        let navigated = await waitUntil(30) { page.currentURL()?.absoluteString != searchURL.absoluteString }
        XCTAssertTrue(navigated)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let listing = try XCTUnwrap(page.currentURL())
        print("LIVESPOKEO listing page: \(listing.absoluteString)")
        await shot(web, "2-listing-page")

        // 3. "This is my listing": the app opens the opt-out form and fills it in.
        runner.next()
        XCTAssertEqual(runner.flow.chosenListing, listing)
        let opened = await waitUntil(40) { page.currentURL()?.path.contains("optout") == true }
        XCTAssertTrue(opened, "the opt-out form opened")
        let filled = await waitUntil(40) {
            (await self.js(web, "(function(){var u=document.querySelector('input[name=url]');return u?u.value:''})();") as? String)?.isEmpty == false
        }
        XCTAssertTrue(filled, "the listing address was filled into the form")
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let filledURL = await js(web, "(function(){var u=document.querySelector('input[name=url]');return u?u.value:''})();") as? String
        let filledEmail = await js(web, "(function(){var u=document.querySelector('input[name=email]');return u?u.value:''})();") as? String
        print("LIVESPOKEO form: url=\(filledURL ?? "nil") email=\(filledEmail ?? "nil") step=\(runner.flow.current?.title ?? "done") status=\(runner.status ?? "-") sendAttempts=\(page.sendAttempts)")
        XCTAssertEqual(filledURL, listing.absoluteString, "their listing is in the form")
        XCTAssertEqual(filledEmail, "pat+optoutkit@gmail.com", "the household email, tagged for Gmail")
        _ = await js(web, "(function(){var u=document.querySelector('input[name=url]'); if(u){u.scrollIntoView({block:'center'});} })();")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        await shot(web, "3-filled-form")

        // 4. A bot check stops it for the person. Nothing was sent.
        let blockers = await page.blockers()
        print("LIVESPOKEO blockers: \(blockers) currentStep=\(runner.flow.current?.title ?? "done")")
        task.cancel()
    }
}
