import XCTest
import SwiftUI
import CryptoKit
import OptOutKitCore
@testable import OptOutKit

/// Tests of the pieces that are the phone itself (the Keychain, the web view): they need the iOS app and its simulator. The model's own tests run on the Mac
/// (`Packages/AssistedRunLogic/Tests/AssistedRunLogicTests/Model`).
final class KeychainKeyTests: XCTestCase {
    func testKeyIsCreatedOnceAndStable() throws {
        let provider = KeychainKey(service: "dev.optoutkit.tests.\(UUID())", account: "k")
        let a = try provider.key(), b = try provider.key()
        XCTAssertEqual(a.withUnsafeBytes { Data($0) }, b.withUnsafeBytes { Data($0) })
        XCTAssertEqual(a.bitCount, 256)
    }
}

@MainActor
final class WebViewFetcherTests: XCTestCase {
    /// The point of the web view: a page that fills in its results with JavaScript after a "loading" screen.
    func testWaitsForScriptToFillInResults() async throws {
        let html = """
        <html><head><title>Directory</title></head><body><div id="r">Loading...</div>
        <script>setTimeout(function(){document.getElementById('r').innerText='Search results: Pat Example, Springfield';}, 1500);</script>
        </body></html>
        """
        let page = try await WebViewFetcher().render(html: html)
        XCTAssertTrue(page.text.contains("Search results: Pat Example"), "got: \(page.text)")
        XCTAssertFalse(page.text.contains("Loading..."))
    }

    func testPlainStaticPageReturnsItsText() async throws {
        let page = try await WebViewFetcher().render(html: "<html><body>No results found</body></html>")
        XCTAssertTrue(page.text.contains("No results found"))
    }

    func testRechecksThroughTheWebViewFetcherLikeAnyOtherFetcher() async throws {
        // A spec checked against a page that only has its content after script runs: a plain fetcher would see "Loading...".
        struct ScriptedPage: PageFetcher {
            func fetch(_ url: URL) async throws -> FetchedPage {
                try await WebViewFetcher().render(html: "<body>Directory <span id=a>Loading...</span><script>setTimeout(()=>a.innerText='No result for this name',800)</script></body>")
            }
        }
        let broker = Broker(id: "b", name: "B", tier: .B, covers: nil, signals: nil, fields: nil, steps: [Step(say: "x")], recheckDays: 30, verified: nil,
                            recheck: Recheck(searchURL: "https://b.example/{first}-{last}", validPage: ["directory"], noResults: ["no result"], ignoreLocation: true))
        let pat = Person(displayName: "P", names: [NameEntry(kind: .legal, name: "Pat Example")])
        let outcome = await Rechecker(fetcher: ScriptedPage()).check(broker, for: pat)
        XCTAssertEqual(outcome, .removed)
    }
}

final class EvidenceImageTests: XCTestCase {
    private func jpeg(gray: CGFloat) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 80)).image { ctx in
            UIColor(white: gray, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
            UIColor(white: 0, alpha: 1).setFill(); ctx.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        }.jpegData(compressionQuality: 0.9)!
    }

    func testAnAlmostBlackScreenshotIsBrightenedAndANormalOneIsLeftAlone() throws {
        let dark = try XCTUnwrap(UIImage(data: jpeg(gray: 5.0 / 255)))
        XCTAssertLessThan(EvidenceImage.mean(of: dark), 0.03)
        let fixed = try XCTUnwrap(EvidenceImage.image(from: jpeg(gray: 5.0 / 255)))
        XCTAssertGreaterThan(EvidenceImage.mean(of: fixed), 0.3, "the page shows again")
        let normal = try XCTUnwrap(EvidenceImage.image(from: jpeg(gray: 1)))
        XCTAssertGreaterThan(EvidenceImage.mean(of: normal), 0.8)
    }
}

/// The automatic opt-out page must open at once, with the real directory of about 800 sites.
@MainActor
final class BrowserHandoffTests: XCTestCase {
    func testOpeningAsksAtOnceAndYesFinishesNoDoesNot() {
        let h = BrowserHandoff()
        var opened: [URL] = []
        h.open(URL(string: "https://example.com/optout")!) { opened.append($0) }
        XCTAssertTrue(h.asking); XCTAssertEqual(opened.count, 1)
        var finished = 0
        h.answer(completed: false) { finished += 1 }
        XCTAssertFalse(h.asking); XCTAssertEqual(finished, 0)
        h.open(URL(string: "https://example.com/optout")!) { _ in }
        h.answer(completed: true) { finished += 1 }
        XCTAssertEqual(finished, 1)
    }

    func testOnlyWebAddressesOpen() {
        let h = BrowserHandoff()
        h.open(URL(string: "file:///etc/passwd")!) { _ in XCTFail("not a web page") }
        XCTAssertFalse(h.asking)
    }
}

final class RowFieldTests: XCTestCase {
    private struct Row { var name: String }

    func testARowDeletedUnderTheBindingGivesTheDefaultAndIgnoresStoresInsteadOfTrapping() {
        var rows = [Row(name: "a"), Row(name: "b")]
        let list = Binding(get: { rows }, set: { rows = $0 })
        let second = RowField.binding(list, 1, \Row.name, default: "")
        XCTAssertEqual(second.wrappedValue, "b")
        second.wrappedValue = "B"; XCTAssertEqual(rows[1].name, "B")
        rows.remove(at: 1)                                        // the row is deleted; SwiftUI still holds its binding
        XCTAssertEqual(second.wrappedValue, "", "no trap: the default")
        second.wrappedValue = "late"; XCTAssertEqual(rows.count, 1, "a late store is ignored")
        rows.removeAll()
        XCTAssertEqual(RowField.binding(list, 0, \Row.name, default: "x").wrappedValue, "x")
    }
}

@MainActor
final class EditorPruneTests: XCTestCase {
    func testEmptyRowsAreDroppedWhenAProfileIsSaved() {
        var p = Person(displayName: "Me", relationship: .me)
        p.names = [NameEntry(kind: .legal, name: "Pat Example"), NameEntry(kind: .nickname, name: "  "), NameEntry(kind: .nickname, name: "Patty")]
        p.phones = ["(773) 633-1564", ""]; p.emails = ["", "pat@example.com"]
        p.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701"), Address(city: "", state: ""), Address(city: "Peoria", state: "IL")]
        let q = PersonEditorView.pruned(p)
        XCTAssertEqual(q.names.map(\.name), ["Pat Example", "Patty"])
        XCTAssertEqual(q.phones, ["(773) 633-1564"]); XCTAssertEqual(q.emails, ["pat@example.com"])
        XCTAssertEqual(q.addresses.map(\.city), ["Springfield", "Peoria"], "a started earlier address stays; an empty one goes")
    }
}

#if DEBUG
@MainActor
final class SiteReviewTests: XCTestCase {
    private func entries() throws -> [DirectoryEntry] {
        return try Catalog.contents(of: try XCTUnwrap(AppCatalog.url), includeExcluded: true).sites
    }

    func testTheQueueIsTheSitesWithNoReadableFormMostImportantFirst() throws {
        let rows = SiteReview.rows(from: try entries())
        XCTAssertGreaterThan(rows.count, 100)
        XCTAssertFalse(rows.contains { $0.domain == "peoplefinders.com" }, "a site with a readable form is not asked about")
        let all = try entries()
        let pri = rows.compactMap { r in all.first { $0.id == r.id }?.priority ?? 0 }
        XCTAssertEqual(pri, pri.sorted(by: >), "most important first")
    }

    func testTagsFromTheWebPageAreMergedAndTheNewerOneWins() throws {
        let review = SiteReview(entries: try entries())
        let first = try XCTUnwrap(review.rows.first)
        let json = #"[{"d":"\#(first.domain)","tag":"ok","url":"https://x.example/optout","at":"2099-01-01T00:00:00Z"}]"#
        XCTAssertEqual(review.importJSON(json), 1)
        XCTAssertTrue(review.isDone(first)); XCTAssertEqual(review.tags[first.domain]?.url, "https://x.example/optout")
        let older = #"[{"d":"\#(first.domain)","tag":"none","at":"2000-01-01T00:00:00Z"}]"#
        XCTAssertEqual(review.importJSON(older), 0, "an older tag never replaces a newer one")
        XCTAssertNotEqual(review.current?.domain, first.domain, "the queue moves past a site that is done")
        try? FileManager.default.removeItem(at: review.file)
    }
}
#endif

// The app speaks the languages its bundle holds (the translations ship in the app: lproj folders), so these need the iOS app.
@MainActor
final class LanguageAppTests: XCTestCase {
    override func tearDown() { L10n.language = "en"; Loc.language = "en" }

    private func model() -> AppModel {
        AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                 defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
    }

    func testTheAppSpeaksTheChosenLanguageEverywhereItBuildsWords() throws {
        let m = model()
        XCTAssertEqual(m.language, "en")
        m.setLanguage("fr")
        XCTAssertEqual(m.language, "fr")
        XCTAssertEqual(Loc.t("Next step"), "Étape suivante")
        XCTAssertEqual(OptOutMethod.manual.title, "Plus tard, pas encore de voie", "words from the core package follow the same choice")
        m.setLanguage("de")
        XCTAssertEqual(Loc.f("Step %lld of %lld", 2, 5), "Schritt 2 von 5")
        let ca = try XCTUnwrap(m.jurisdiction(code: "CA"))
        XCTAssertTrue(m.statements(for: ca)[0].text.hasPrefix("Kalifornien verlangt"), m.statements(for: ca)[0].text)
        m.setLanguage("es")
        XCTAssertEqual(m.jurisdiction(code: "NY")?.displayName, "Nueva York")
    }

    func testAnUnsupportedLanguageIsIgnoredAndTheChoiceIsRemembered() {
        let defaults = UserDefaults(suiteName: "ook.test.\(UUID())")!
        let store = HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey())
        let a = AppModel(store: store, defaults: defaults)
        a.setLanguage("xx")
        XCTAssertEqual(a.language, "en")
        a.setLanguage("es")
        let b = AppModel(store: store, defaults: defaults)
        XCTAssertEqual(b.language, "es", "remembered across launches")
    }

    func testEveryAppStringHasAllThreeTranslations() throws {
        let url = try XCTUnwrap(Bundle(for: AppModel.self).url(forResource: "es", withExtension: "lproj"))
        XCTAssertNotNil(Bundle(url: url))
        for lang in ["fr", "es", "de"] {
            Loc.language = lang
            XCTAssertNotEqual(Loc.t("Next step"), "Next step", lang)
            XCTAssertNotEqual(Loc.t("Mark done"), "Mark done", lang)
        }
    }
}

@MainActor
final class WebPageInspectorTests: XCTestCase {
    func testReadsTitleTextLinksAndFormsFromTheLiveDOM() async throws {
        let html = """
        <html><head><title>Privacy Request Portal</title></head><body>
        <p>Welcome. You have the right to opt out of the sale of your information.</p>
        <a href="/privacy-rights">Your Privacy Rights</a> <a href="https://other.example/x#frag">Other</a>
        <form action="https://x.example/submit" method="post">
          <label for="f">First name</label><input id="f" name="first">
          <input type="email" name="email" placeholder="Your email">
          <input type="hidden" name="token" value="x">
          <select name="state"><option>IL</option></select>
          <button type="submit">Send</button>
        </form></body></html>
        """
        let snap = try await XCTUnwrapAsync(await WebPageInspector().snapshot(html: html, url: URL(string: "https://x.example/request-portal/")!))
        XCTAssertEqual(snap.title, "Privacy Request Portal")
        XCTAssertTrue(snap.text.contains("right to opt out"))
        XCTAssertTrue(snap.links.contains { $0.text == "Your Privacy Rights" })
        XCTAssertEqual(snap.forms.count, 1)
        let form = snap.forms[0]
        XCTAssertEqual(form.method, "post")
        XCTAssertTrue(form.hasSubmit)
        XCTAssertEqual(form.fields.map(\.name), ["first", "email", "state"], "hidden inputs are left out")
        XCTAssertEqual(form.fields.first?.label, "First name", "labels come from <label for>")
        XCTAssertEqual(form.fields.last?.type, "select")
        // and the finder's rules accept it as an opt-out form on an opt-out page
        XCTAssertNotNil(LinkRules.bestForm(on: PageSnapshot(url: URL(string: "https://x.example/request-portal/")!, title: snap.title, text: snap.text, links: snap.links, forms: snap.forms)))
    }
}

private func XCTUnwrapAsync<T>(_ value: @autoclosure () async -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let v = await value()
    return try XCTUnwrap(v, file: file, line: line)
}

@MainActor
final class GuidedWebPageTests: XCTestCase {
    private let pat = Person(displayName: "Pat", relationship: .me, names: [NameEntry(kind: .legal, name: "Pat Example")],
                             addresses: [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")], emails: ["pat@example.com"])
    // MARK: the real guided page runs on the same code as Solve and send

    func testTheGuidedWebPageFindsFillsAndSendsThroughTheSharedPageCode() async {
        let html = """
            <html><body><h1>Opt out</h1>
            <form id="a" onsubmit="event.preventDefault(); document.getElementById('log').innerText += ' A-SENT:' + this.querySelector('input[type=email]').value;">
              <input id="fn" placeholder="First Name"><input id="ln" placeholder="Last Name"><input type="email" placeholder="Email"><button type="submit">Opt me out</button></form>
            <form id="d" onsubmit="event.preventDefault(); document.getElementById('log').innerText += ' D-SENT';"><h3>Opt out of Mobile ID</h3><input placeholder="Device ID"><button type="submit">Opt me out</button></form>
            <p id="log">LOG</p></body></html>
            """
        let page = WebGuidedPage()
        defer { page.close() }
        page.use(person: pat)
        await page.loadHTML(html)
        let filled = await page.scanAndFill(person: pat)
        XCTAssertGreaterThan(filled, 0, "it found the form and filled it")
        let blockers = await page.blockers()
        XCTAssertTrue(blockers.isEmpty)
        let outcome = await page.send([])
        let log = await page.visibleText()
        XCTAssertTrue(log.contains("A-SENT:pat@example.com"), log)
        XCTAssertTrue(outcome == .submitted(awaitingEmail: false) || { if case .failed = outcome { return true } else { return false } }(), "\(outcome)")
    }
}
