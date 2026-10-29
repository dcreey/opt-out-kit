import XCTest
import OptOutKitCore
@testable import OptOutKit

@MainActor
private func makeModel(url: URL? = nil, keys: KeyProviding = FixedKey()) -> AppModel {
    let file = url ?? FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed")
    return AppModel(store: HouseholdStore(url: file, keys: keys), defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
}

@MainActor
final class AppModelTests: XCTestCase {
    func testBundledRegistryLoads() {
        let model = makeModel()
        XCTAssertNil(model.loadError)
        XCTAssertGreaterThanOrEqual(model.brokers.count, 3)
    }
}

@MainActor
final class PeopleTests: XCTestCase {
    func testProgressIsPerPerson() throws {
        let model = makeModel()
        let broker = try XCTUnwrap(model.brokers.first)
        let me = model.selectedPerson!.id
        model.complete(broker, step: 0)
        XCTAssertTrue(model.progress.isStepDone(broker.id, 0))
        model.addPerson(named: "Friend")
        XCTAssertNotEqual(model.selectedPerson?.id, me)
        XCTAssertFalse(model.progress.isStepDone(broker.id, 0))
        model.select(me)
        XCTAssertTrue(model.progress.isStepDone(broker.id, 0))
    }

    func testProfileEditsPersistAcrossLaunchesEncrypted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed")
        let keys = FixedKey()
        let first = makeModel(url: url, keys: keys)
        var me = try XCTUnwrap(first.selectedPerson)
        me.names = [NameEntry(kind: .legal, name: "Pat Example"), NameEntry(kind: .nickname, name: "Pat")]
        me.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701", fromYear: 2015)]
        first.update(me)
        first.flushSaves()

        let second = makeModel(url: url, keys: keys)
        XCTAssertEqual(second.selectedPerson?.legalName, "Pat Example")
        XCTAssertEqual(second.selectedPerson?.allNames, ["Pat Example", "Pat"])
        XCTAssertEqual(second.selectedPerson?.addresses.first?.city, "Springfield")
        let raw = try Data(contentsOf: url)
        XCTAssertNil(raw.range(of: Data("Pat Example".utf8)), "profile must not be stored in plaintext")
    }

    func testUnreadableDataIsNeverOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed")
        let first = makeModel(url: url)
        first.addPerson(named: "Mum")
        first.flushSaves()
        let before = try Data(contentsOf: url)

        let locked = makeModel(url: url, keys: FixedKey())   // different key: cannot decrypt
        XCTAssertNotNil(locked.storageProblem)
        locked.addPerson(named: "Dad")                       // must not write over the original
        locked.flushSaves()
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testAddedRelativeIsAPersonWithARelationship() throws {
        let model = makeModel()
        let mum = try XCTUnwrap(model.addPerson(named: "Mum", relationship: .parent))
        XCTAssertEqual(model.people.count, 2)
        XCTAssertEqual(model.people.first { $0.id == mum.id }?.relationship, .parent)
        XCTAssertEqual(model.selectedPerson?.legalName, "Mum")
    }

    func testLastPersonCannotBeRemoved() {
        let model = makeModel()
        model.remove(model.selectedPerson!.id)
        XCTAssertEqual(model.people.count, 1)
    }
}

final class KeychainKeyTests: XCTestCase {
    func testKeyIsCreatedOnceAndStable() throws {
        let provider = KeychainKey(service: "dev.optoutkit.tests.\(UUID())", account: "k")
        let a = try provider.key(), b = try provider.key()
        XCTAssertEqual(a.withUnsafeBytes { Data($0) }, b.withUnsafeBytes { Data($0) })
        XCTAssertEqual(a.bitCount, 256)
    }
}


@MainActor
final class OnboardingTests: XCTestCase {
    private func model(_ defaults: UserDefaults, catalog: [Announcement]) -> AppModel {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed")
        return AppModel(store: HouseholdStore(url: file, keys: FixedKey()), defaults: defaults, catalog: catalog)
    }

    func testWalkthroughOnFirstInstallThenNeverAgainUntilANewMessage() {
        let defaults = UserDefaults(suiteName: "ook.test.\(UUID())")!
        let v1 = [Announcement(id: 1, title: "Welcome", body: "")]
        let first = model(defaults, catalog: v1)
        XCTAssertEqual(first.pending, .walkthrough)
        first.finishAnnouncements()

        XCTAssertEqual(model(defaults, catalog: v1).pending, .nothing, "relaunch or no-message update shows nothing")

        let v2 = v1 + [Announcement(id: 2, title: "New", body: "")]
        XCTAssertEqual(model(defaults, catalog: v2).pending, .whatsNew([v2[1]]))
    }
}

private struct StubFetcher: PageFetcher {
    var page: FetchedPage
    func fetch(_ url: URL) async throws -> FetchedPage { page }
}

@MainActor
final class CheckWiringTests: XCTestCase {
    func testDueChecksRunAndVerifyThroughTheModel() async throws {
        let model = makeModel()
        let spokeo = try XCTUnwrap(model.brokers.first { $0.id == "spokeo" })
        var me = try XCTUnwrap(model.selectedPerson)
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]
        me.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")]
        model.update(me)
        for i in spokeo.steps.indices { model.complete(spokeo, step: i) }
        XCTAssertEqual(model.household.summary(for: spokeo), .submitted)

        let gone = StubFetcher(page: FetchedPage(status: 404, text: "Did not match any results Spokeo"))
        let day: TimeInterval = 86_400
        await model.runDueChecks(fetcher: gone, now: Date() + 4 * day)
        XCTAssertEqual(model.household.summary(for: spokeo), .submitted, "one check is not enough")
        await model.runDueChecks(fetcher: gone, now: Date() + 7 * day)
        XCTAssertEqual(model.household.summary(for: spokeo), .complete)
    }
}

@MainActor
final class DirectoryModelTests: XCTestCase {
    func testBundledDirectoryLoadsAndHidesGuidedSites() {
        let model = makeModel()
        XCTAssertGreaterThanOrEqual(model.directory.count, 200)
        XCTAssertFalse(model.unguidedSites.contains { $0.domain == "spokeo.com" }, "Spokeo already has a guided flow")
        XCTAssertTrue(model.unguidedSites.count < model.directory.count)
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

@MainActor
final class SkippedSitesAppTests: XCTestCase {
    func testASkippedSiteLeavesTodaysListAndAnIssueReportSetsItAsideToo() throws {
        let model = makeModel()
        let today = model.dailyGoals.verify
        XCTAssertGreaterThan(today.count, 2)
        let byDomain = Dictionary(model.directory.map { ($0.domain, $0) }, uniquingKeysWith: { a, _ in a })
        let first = try XCTUnwrap(byDomain[today[0]]), second = try XCTUnwrap(byDomain[today[1]])

        model.skipSite(first.id)
        XCTAssertFalse(model.dailyGoals.verify.contains(first.domain))
        XCTAssertEqual(model.skipCount(first.id), 1)
        XCTAssertEqual(model.skippedSites.map(\.entry.id), [first.id])
        XCTAssertNotNil(model.skippedSites.first?.returns)

        model.reportIssue(.brokenLink, site: second.id)
        XCTAssertFalse(model.dailyGoals.verify.contains(second.domain), "not working sets it aside like a skip")
        XCTAssertEqual(model.skippedSites.count, 2)

        model.skipSite(first.id, forever: true)
        XCTAssertTrue(model.isSkippedForever(first.id))
        model.bringBack(first.id)
        XCTAssertTrue(model.dailyGoals.verify.contains(first.domain), "bringing a site back returns it to the list")
        XCTAssertEqual(model.skippedDueCount, 0)
    }
}
