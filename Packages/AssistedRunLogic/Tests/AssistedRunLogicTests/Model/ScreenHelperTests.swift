import XCTest
import SwiftUI
import OptOutKitCore
@testable import AssistedRunLogic

/// The rules behind a few screens, moved off the simulator: the queue of sites Solve and send works through, the "Open in my browser" question, a row binding
/// that survives its row being deleted, the profile's empty rows dropped on save, the admin review queue, and the language choice.
@MainActor
final class ScreenHelperTests: XCTestCase {
    private func model(_ store: HouseholdStore? = nil, _ defaults: UserDefaults? = nil) -> AppModel {
        AppModel(store: store ?? HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                 defaults: defaults ?? UserDefaults(suiteName: "ook.test.\(UUID())")!)
    }
    override func tearDown() { L10n.language = "en"; Loc.language = "en" }

    func testTheAppModelQueuesOnlySitesItCanFillAndHasNotSentRecently() throws {
        let m = model()
        var me = try XCTUnwrap(m.selectedPerson)
        XCTAssertTrue(m.assistedItems(for: me).isEmpty, "with no name or email there is nothing to fill in")
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"; me.emails = ["pat@example.com"]
        me.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")]
        m.update(me); m.setContactEmail("pat@example.com")
        let queue = m.assistedItems(for: me)
        XCTAssertGreaterThan(queue.count, 50)
        // once a site is recorded as sent it leaves the queue for a week
        let first = try XCTUnwrap(queue.first)
        m.recordAssisted(first.entry, .submitted(awaitingEmail: false), for: me)
        XCTAssertFalse(m.assistedItems(for: me).contains { $0.id == first.id })
    }

    func testOpeningInTheBrowserAsksAtOnceAndYesFinishesNoDoesNot() {
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

    func testOnlyWebAddressesOpenInTheBrowser() {
        let h = BrowserHandoff()
        h.open(URL(string: "file:///etc/passwd")!) { _ in XCTFail("not a web page") }
        XCTAssertFalse(h.asking)
    }

    func testARowDeletedUnderTheBindingGivesTheDefaultAndIgnoresStoresInsteadOfTrapping() {
        struct Row { var name: String }
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

    func testEmptyRowsAreDroppedWhenAProfileIsSaved() {
        var p = Person(displayName: "Me", relationship: .me)
        p.names = [NameEntry(kind: .legal, name: "Pat Example"), NameEntry(kind: .nickname, name: "  "), NameEntry(kind: .nickname, name: "Patty")]
        p.phones = ["(773) 633-1564", ""]; p.emails = ["", "pat@example.com"]
        p.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701"), Address(city: "", state: ""), Address(city: "Peoria", state: "IL")]
        let q = p.prunedForSave()
        XCTAssertEqual(q.names.map(\.name), ["Pat Example", "Patty"])
        XCTAssertEqual(q.phones, ["(773) 633-1564"]); XCTAssertEqual(q.emails, ["pat@example.com"])
        XCTAssertEqual(q.addresses.map(\.city), ["Springfield", "Peoria"], "a started earlier address stays; an empty one goes")
    }

    func testTheReviewQueueIsTheSitesWithNoReadableFormMostImportantFirst() throws {
        _ = AppCatalog.ensureOpen()
        let all = try Catalog.contents(of: try XCTUnwrap(AppCatalog.url), includeExcluded: true).sites
        let rows = SiteReviewQueue.rows(from: all)
        XCTAssertGreaterThan(rows.count, 100)
        XCTAssertFalse(rows.contains { $0.domain == "peoplefinders.com" }, "a site with a readable form is not asked about")
        let pri = rows.compactMap { r in all.first { $0.id == r.id }?.priority ?? 0 }
        XCTAssertEqual(pri, pri.sorted(by: >), "most important first")
    }

    func testReviewTagsAreMergedAndTheNewerOneWins() {
        var tags: [String: SiteReviewQueue.Tag] = [:]
        XCTAssertEqual(SiteReviewQueue.merge(&tags, [.init(d: "a.example", tag: "ok", url: "https://x.example/optout", at: "2099-01-01T00:00:00Z")]), 1)
        XCTAssertEqual(tags["a.example"]?.url, "https://x.example/optout")
        XCTAssertEqual(SiteReviewQueue.merge(&tags, [.init(d: "a.example", tag: "none", at: "2000-01-01T00:00:00Z")]), 0, "an older tag never replaces a newer one")
        XCTAssertEqual(tags["a.example"]?.tag, "ok")
    }

    /// The language choice: words from the core package and the laws follow it, an unsupported one is ignored, and the choice is remembered. (That every app
    /// string is translated is `tools/l10n.py check` in CI; that the app's own words show in the chosen language is the language UI test.)
    func testTheChosenLanguageIsUsedForTheCoreWordsAndLawsAndIsRemembered() throws {
        let defaults = UserDefaults(suiteName: "ook.test.\(UUID())")!
        let store = HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey())
        let m = model(store, defaults)
        XCTAssertEqual(m.language, "en")
        m.setLanguage("fr")
        XCTAssertEqual(OptOutMethod.manual.title, "Plus tard, pas encore de voie", "words from the core package follow the choice")
        m.setLanguage("de")
        let ca = try XCTUnwrap(m.jurisdiction(code: "CA"))
        XCTAssertTrue(m.statements(for: ca)[0].text.hasPrefix("Kalifornien verlangt"), m.statements(for: ca)[0].text)
        m.setLanguage("xx")
        XCTAssertEqual(m.language, "de", "an unsupported language is ignored")
        m.setLanguage("es")
        XCTAssertEqual(m.jurisdiction(code: "NY")?.displayName, "Nueva York")
        XCTAssertEqual(model(store, defaults).language, "es", "remembered across launches")
    }
}
