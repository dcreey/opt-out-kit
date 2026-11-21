import XCTest
import WebKit
import OptOutKitCore
@testable import AssistedRunLogic

/// Answers for any host as the same moved site.
private struct AnySite: PageInspector {
    func snapshot(_ url: URL) async -> PageSnapshot? { await movedSite(host: url.host ?? "x.example").snapshot(url) }
}

private struct FakeSite: PageInspector {
    var pages: [String: PageSnapshot]
    func snapshot(_ url: URL) async -> PageSnapshot? {
        pages[url.absoluteString] ?? PageSnapshot(url: url, status: 404, title: "Page not found", text: "Nothing here.")
    }
}

/// A site whose opt-out page moved: the old /optout is gone, the new page is under /request-portal/.
private func movedSite(host: String) -> FakeSite {
    func u(_ p: String) -> URL { URL(string: "https://\(host)\(p)")! }
    let form = FormSnapshot(action: u("/request-portal/"), method: "post",
                            fields: [FormField(type: "text", name: "first", label: "First"), FormField(type: "text", name: "last", label: "Last"), FormField(type: "email", name: "email", label: "Email")], hasSubmit: true)
    return FakeSite(pages: [
        "https://\(host)/": PageSnapshot(url: u("/"), title: "Home", text: "Welcome", links: [LinkSnapshot(href: u("/privacy-rights"), text: "Your Privacy Rights")]),
        "https://\(host)/privacy-rights": PageSnapshot(url: u("/privacy-rights"), title: "Privacy Rights", text: "Your privacy rights. Right to opt out.",
                                                      links: [LinkSnapshot(href: u("/request-portal/"), text: "Privacy Request Portal")]),
        "https://\(host)/request-portal/": PageSnapshot(url: u("/request-portal/"), title: "Request Portal", text: "Privacy Request Portal. Right to opt out and delete.", forms: [form]),
    ])
}

@MainActor
final class LinkHealingTests: XCTestCase {
    private func model() -> AppModel {
        AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                 defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
    }
    private func entry(_ host: String) -> DirectoryEntry {
        let old = OptOutForm(page: URL(string: "https://\(host)/optout")!, method: "post", action: nil, fields: [FormField(type: "email", name: "old_email", label: "Email")], hops: 1)
        return DirectoryEntry(id: host.replacingOccurrences(of: ".", with: "_"), domain: host, name: host, bucket: "direct", tier: .B, automation: .guided, optOutForm: old)
    }

    func testAMovedPageIsFoundAndRememberedAndEveryFlowUsesTheNewForm() async throws {
        let m = model()
        let e = entry("moved.example")
        XCTAssertEqual(m.effectiveURL(for: e)?.absoluteString, "https://moved.example/optout")
        let healed = await m.healLink(for: e, inspector: movedSite(host: "moved.example"))
        XCTAssertEqual(healed?.form.page.absoluteString, "https://moved.example/request-portal/")
        XCTAssertEqual(m.effectiveURL(for: e)?.absoluteString, "https://moved.example/request-portal/", "the site view now links the working page")
        let resolved = m.resolved(e)
        XCTAssertEqual(resolved.optOutForm?.fields.map(\.name), ["first", "last", "email"], "the new form's fields replace the old ones")
        m.forgetHealedLink(e.id)
        XCTAssertEqual(m.effectiveURL(for: e)?.absoluteString, "https://moved.example/optout", "the person can go back to the recorded link")
    }

    func testNothingIsSavedWhenTheSiteHasNoFindableForm() async {
        let m = model()
        let none = await m.healLink(for: entry("empty.example"), inspector: FakeSite(pages: [:]))
        XCTAssertNil(none)
        XCTAssertNil(m.healedLink(for: "empty_example"))
    }

    func testHealingSurvivesARelaunchBecauseItIsSavedWithTheHousehold() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed")
        let keys = FixedKey()
        let a = AppModel(store: HouseholdStore(url: url, keys: keys), defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        _ = await a.healLink(for: entry("moved.example"), inspector: movedSite(host: "moved.example"))
        a.flushSaves()          // saves are written in the background, one after another
        let b = AppModel(store: HouseholdStore(url: url, keys: keys), defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        XCTAssertEqual(b.healedLink(for: "moved_example")?.form.page.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), "request-portal")
    }

    func testABrokerFlowWhoseFirstPageMovedGuidesToTheNewPage() async throws {
        let m = model()
        var me = try XCTUnwrap(m.selectedPerson)
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"
        me.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")]
        m.update(me); m.setContactEmail("pat@example.com")      // a flow only starts for a person whose profile is complete
        let broker = try XCTUnwrap(m.brokers.first { $0.id == "peopleconnect" })
        let healed = await m.healLink(for: broker, inspector: movedSite(host: "suppression.peopleconnect.us"))
        XCTAssertNotNil(healed, "the broker's host was crawled for the new page")
        let runner = try XCTUnwrap(m.guidedRunner(for: broker))
        guard case .openPage(let url)? = runner.flow.plan.steps.first?.action else { return XCTFail("first step should open a page") }
        XCTAssertEqual(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), "request-portal")
    }

    func testTheWeeklyRunHealsAPageThatWentMissingAndRetriesTheSiteOnce() async throws {
        struct GoneThenFine: FormSubmitter {
            let calls = Calls()
            func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome {
                calls.pages.append(form.page.path)
                return !form.page.path.hasPrefix("/request-portal") ? .failed(FormRun.pageGone) : .submitted(awaitingEmail: false)
            }
        }
        final class Calls: @unchecked Sendable { var pages: [String] = [] }
        let m = model()
        var me = try XCTUnwrap(m.selectedPerson)
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"; me.emails = ["pat@example.com"]
        me.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")]
        m.update(me); m.setContactEmail("pat@example.com")
        let submitter = GoneThenFine()
        await m.runAutoOptOut(for: me, automaticOnly: false, submitter: submitter, inspector: AnySite())
        XCTAssertFalse(submitter.calls.pages.isEmpty)
        XCTAssertTrue(submitter.calls.pages.contains { $0.hasPrefix("/request-portal") }, "a site whose page was gone was tried again at its new address")
        XCTAssertNotNil(m.directory.first { m.healedLink(for: $0.id) != nil }, "and the new address was remembered")
    }
}


private func XCTUnwrapAsync<T>(_ value: @autoclosure () async -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let v = await value()
    return try XCTUnwrap(v, file: file, line: line)
}
