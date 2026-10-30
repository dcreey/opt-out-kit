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
        me.names = [NameEntry(kind: .legal, name: "Pat Example"), NameEntry(kind: .nickname, name: "Pat")]; me.birthdate = "1985-03-14"
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
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"
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

@MainActor
final class InterruptedRunAppTests: XCTestCase {
    func testAResultIsSavedTheMomentItArrivesAndTheRunIsMarkedPendingUntilItFinishes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed")
        let keys = FixedKey()
        let model = makeModel(url: url, keys: keys)
        let me = try XCTUnwrap(model.selectedPerson)
        let entry = try XCTUnwrap(model.directory.first)
        model.recordAutoResult(entry, .submitted(awaitingEmail: false), for: me.id, dryRun: false)
        // A fresh launch (the app was closed right after) still knows it was sent.
        let again = makeModel(url: url, keys: keys)
        XCTAssertTrue(again.progress.optOutAttempts[entry.id]?.contains { $0.wasSubmitted } ?? false, "the request is not lost when the app closes")
        model.recordAutoResult(entry, .submitted(awaitingEmail: false), for: me.id, dryRun: true)
        XCTAssertEqual(model.progress.optOutAttempts[entry.id]?.count, 1, "a dry run records nothing")
    }
}

@MainActor
final class PeriodSitesAppTests: XCTestCase {
    func testEveryAutomaticDomainIsATrackedSite() throws {
        let model = makeModel()
        let me = try XCTUnwrap(model.selectedPerson)
        let domains = model.automaticDomains(for: me)
        let sites = model.automaticSites(for: me)
        let known = Set(sites.map(\.domain))
        print("PERIODCHECK domains=\(domains.count) sites=\(sites.count) missing=\(domains.subtracting(known).sorted().prefix(8))")
        XCTAssertEqual(known, domains.intersection(Set(model.directory.map(\.domain))))
    }
}

@MainActor
final class MarkDoneAppTests: XCTestCase {
    func testMarkingASiteDoneCountsItAndCanBeTakenBack() throws {
        let model = makeModel()
        let entry = try XCTUnwrap(model.directory.first)
        XCTAssertFalse(entry.isCurrent(attempts: model.progress.optOutAttempts))
        model.markSiteDone(entry.id)
        XCTAssertTrue(entry.isCurrent(attempts: model.progress.optOutAttempts), "a site marked done counts as done")
        XCTAssertTrue(model.wasMarkedByHand(entry.id))
        model.unmarkSiteDone(entry.id)
        XCTAssertFalse(entry.isCurrent(attempts: model.progress.optOutAttempts))
        // A request the app really sent is never taken back by "undo".
        model.recordAttemptForTesting(OptOutAttempt(date: Date(), outcome: "submitted"), site: entry.id)
        model.unmarkSiteDone(entry.id)
        XCTAssertTrue(entry.isCurrent(attempts: model.progress.optOutAttempts))
    }
}

@MainActor
final class OverdueFollowUpAppTests: XCTestCase {
    func testASiteStillWaitingOnItsEmailAfter45DaysBecomesAFollowUpTask() throws {
        let model = makeModel()
        let entry = try XCTUnwrap(model.directory.first)
        model.recordAttemptForTesting(OptOutAttempt(date: Date().addingTimeInterval(-10 * 86_400), outcome: "submitted_email"), site: entry.id)
        XCTAssertEqual(model.overdueFollowUpCount, 0, "10 days is still normal")
        model.recordAttemptForTesting(OptOutAttempt(date: Date().addingTimeInterval(-60 * 86_400), outcome: "submitted_email"), site: entry.id)
        XCTAssertEqual(model.overdueFollowUpCount, 0, "the newest send counts")
        model.resetProgressForTesting()
        model.recordAttemptForTesting(OptOutAttempt(date: Date().addingTimeInterval(-60 * 86_400), outcome: "submitted_email"), site: entry.id)
        XCTAssertEqual(model.overdueFollowUps.map(\.entry.id), [entry.id])
        model.markFollowUpDone(entry.id)
        XCTAssertEqual(model.overdueFollowUpCount, 0, "finishing it ends the follow-up")
    }
}

@MainActor
final class PeriodHomeAppTests: XCTestCase {
    func testTheAutomaticTaskIsCompleteOnceEverySiteWentThroughThisPeriod() throws {
        let model = makeModel()
        let me = try XCTUnwrap(model.selectedPerson)
        let sites = model.automaticSites(for: me)
        XCTAssertGreaterThan(sites.count, 2)
        model.recordAutoResult(sites[0], .submitted(awaitingEmail: false), for: me.id, dryRun: false)
        // Starting the first run sets the period; recording alone does not, so set it as a run would.
        model.startPeriodForTesting()
        var t = try XCTUnwrap(model.currentPeriodTally)
        XCTAssertEqual(t.handled, 1); XCTAssertFalse(t.complete)
        let task = try XCTUnwrap(model.plan.flatMap(\.tasks).first { $0.kind == .automatic })
        XCTAssertFalse(model.isDone(task))
        for s in sites { model.recordAutoResult(s, .submitted(awaitingEmail: false), for: me.id, dryRun: false) }
        t = try XCTUnwrap(model.currentPeriodTally)
        XCTAssertTrue(t.complete, "none remaining")
        XCTAssertTrue(model.isDone(task), "so the task is marked fully complete")
    }
}


@MainActor
final class UnloadableSiteAppTests: XCTestCase {
    func testASiteWhosePageWillNotLoadIsSetAsideForAWeekAndNotHeldAgainstItsMethod() throws {
        let model = makeModel()
        let me = try XCTUnwrap(model.selectedPerson)
        let entry = try XCTUnwrap(model.directory.first)
        model.recordAssisted(entry, .needsYou(AssistedRunner.unloadable), for: me)
        XCTAssertEqual(model.skippedSites.map(\.entry.id), [entry.id])
        XCTAssertNil(model.progress.optOutAttempts[entry.id], "no failed attempt was recorded, so it is not moved to a guide")
    }
}

@MainActor
final class SharedLinkTests: XCTestCase {
    func testOnlyAWebAddressInsideAnExnayLinkIsTaken() {
        XCTAssertEqual(AppModel.sharedLink(in: URL(string: "exnay://link?u=https%3A%2F%2Fexample.com%2Fconfirm%3Fid%3D1")!), "https://example.com/confirm?id=1")
        XCTAssertNil(AppModel.sharedLink(in: URL(string: "exnay://link?u=javascript%3Aalert(1)")!))
        XCTAssertNil(AppModel.sharedLink(in: URL(string: "exnay://other?u=https%3A%2F%2Fexample.com")!))
        XCTAssertNil(AppModel.sharedLink(in: URL(string: "https://example.com")!))
    }
}
