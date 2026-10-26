import XCTest
import Yams
@testable import OptOutKitCore

final class CoreTests: XCTestCase {
    /// Repo-level brokers/ directory, reached relative to this file.
    private var brokersDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("brokers")
    }

    func testAllBrokerDefinitionsLoad() throws {
        let brokers = try Registry.load(directory: brokersDir)
        XCTAssertGreaterThanOrEqual(brokers.count, 3)
        XCTAssertEqual(Set(brokers.map(\.tier)), [.A, .B, .C])
    }

    func testQueueOrdersEasiestTierFirst() throws {
        let brokers = try Registry.load(directory: brokersDir)
        XCTAssertEqual(brokers.first?.tier, .A)
    }

    func testStepsUnlockInOrderAndFinishBroker() throws {
        let broker = try Registry.decode(yaml: """
        id: t
        name: T
        tier: A
        steps:
          - say: one
          - say: two
        recheck_days: 30
        """)
        var p = OptOutKitCore.Progress()
        p.complete(broker, step: 1)
        XCTAssertFalse(p.isStepDone("t", 1), "later step must stay locked")
        p.complete(broker, step: 0)
        p.complete(broker, step: 1)
        XCTAssertTrue(p.isDone("t"))
        XCTAssertNil(p.nextBroker(in: [broker]))
    }
}

final class HouseholdTests: XCTestCase {
    private let broker = Broker(id: "b", name: "B", tier: .A, covers: nil, signals: nil, fields: nil,
                                steps: [Step(say: "one")], recheckDays: 30, verified: nil)

    func testEachPersonHasIndependentProgress() {
        var h = Household()
        let me = Person(displayName: "Me"), mum = Person(displayName: "Mum")
        h.add(me); h.add(mum)
        h.mutateProgress(for: me.id) { $0.complete(broker, step: 0) }
        XCTAssertTrue(h.progress(for: me.id).isDone("b"))
        XCTAssertFalse(h.progress(for: mum.id).isDone("b"))
    }

    func testRemovingPersonDeletesTheirData() {
        var h = Household()
        let p = Person(displayName: "P", names: [NameEntry(kind: .legal, name: "Pat Example")])
        h.add(p); h.remove(p.id)
        XCTAssertTrue(h.people.isEmpty)
        XCTAssertTrue(h.progress.isEmpty)
    }

    func testBrokerOnlyGetsFieldsThePersonProvided() {
        let p = Person(displayName: "P", names: [NameEntry(kind: .legal, name: "Pat Example")],
                       addresses: [Address(city: "Springfield", state: "IL")], emails: ["pat@example.com"])
        XCTAssertEqual(p.value(for: "email"), "pat@example.com")
        XCTAssertEqual(p.value(for: "address"), "Springfield, IL")
        XCTAssertNil(p.value(for: "birthdate"))
        XCTAssertNil(p.value(for: "ssn"))
    }
}

final class StorageTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).bin")
    }

    private func sample() -> Household {
        var h = Household()
        h.add(Person(displayName: "Me", names: [NameEntry(kind: .legal, name: "Pat Example")], emails: ["pat@example.com"]))
        return h
    }

    func testRoundTrip() throws {
        let store = HouseholdStore(url: tempURL(), keys: FixedKey())
        defer { try? store.erase() }
        XCTAssertNil(try store.load())
        let h = sample()
        try store.save(h)
        XCTAssertEqual(try store.load(), h)
    }

    func testFileHoldsNoPlaintext() throws {
        let store = HouseholdStore(url: tempURL(), keys: FixedKey())
        defer { try? store.erase() }
        try store.save(sample())
        let raw = try Data(contentsOf: store.url)
        XCTAssertNil(raw.range(of: Data("Pat Example".utf8)))
        XCTAssertNil(raw.range(of: Data("pat@example.com".utf8)))
    }

    func testWrongKeyFailsInsteadOfReturningEmpty() throws {
        let url = tempURL()
        let writer = HouseholdStore(url: url, keys: FixedKey())
        defer { try? writer.erase() }
        try writer.save(sample())
        XCTAssertThrowsError(try HouseholdStore(url: url, keys: FixedKey()).load())
    }

    func testTamperingIsDetected() throws {
        let key = FixedKey()
        let store = HouseholdStore(url: tempURL(), keys: key)
        defer { try? store.erase() }
        try store.save(sample())
        var raw = try Data(contentsOf: store.url)
        raw[raw.count - 5] ^= 0xFF
        try raw.write(to: store.url)
        XCTAssertThrowsError(try store.load())
    }

    func testSharedEmailsAreFlagged() {
        var h = Household()
        h.add(Person(displayName: "A", emails: ["Shared@Example.com"]))
        h.add(Person(displayName: "B", emails: ["shared@example.com", "b@example.com"]))
        XCTAssertEqual(h.sharedEmails, ["shared@example.com"])
    }
}

final class PersonTests: XCTestCase {
    func testAllNamesIncludeNicknamesAndPreviousNames() {
        let p = Person(displayName: "P", names: [
            NameEntry(kind: .legal, name: "Patricia Example"),
            NameEntry(kind: .previousLegal, name: "Patricia Old"),
            NameEntry(kind: .nickname, name: "Pat"),
            NameEntry(kind: .nickname, name: ""),
        ])
        XCTAssertEqual(p.legalName, "Patricia Example")
        XCTAssertEqual(p.allNames, ["Patricia Example", "Patricia Old", "Pat"])
    }

    func testRelationshipOptionsIncludeTheFamilyTypes() {
        for r: Relationship in [.parent, .sibling, .cousin, .otherFamily] { XCTAssertTrue(Relationship.allCases.contains(r)) }
        XCTAssertEqual(Relationship.me.label, "Me")
        XCTAssertEqual(Relationship.auntUncle.label, "Aunt or uncle")
    }

    func testNoGenderSpecificDuplicates() {
        let labels = Relationship.allCases.map(\.rawValue)
        for banned in ["mother", "father", "sister", "brother", "son", "daughter", "friend", "other"] {
            XCTAssertFalse(labels.contains(banned), "\(banned) duplicates a neutral option")
        }
    }
}

final class StatusTests: XCTestCase {
    private func broker(_ steps: Int = 2) -> Broker {
        Broker(id: "b", name: "B", tier: .A, covers: nil, signals: nil, fields: nil,
               steps: (0..<steps).map { Step(say: "s\($0)") }, recheckDays: 30, verified: nil)
    }

    func testSummaryAcrossProfiles() {
        let b = broker()
        var h = Household()
        let a = Person(displayName: "A"), c = Person(displayName: "C")
        h.add(a); h.add(c)
        XCTAssertEqual(h.summary(for: b), .notStarted)

        h.mutateProgress(for: a.id) { $0.complete(b, step: 0) }
        XCTAssertEqual(h.summary(for: b), .inProgress)

        h.mutateProgress(for: a.id) { $0.complete(b, step: 1) }
        XCTAssertEqual(h.summary(for: b), .partial(done: 1, of: 2))
        XCTAssertEqual(h.summary(for: b).label, "Partial: 1 of 2 profiles opted out")

        h.mutateProgress(for: c.id) { $0.complete(b, step: 0); $0.complete(b, step: 1) }
        XCTAssertEqual(h.summary(for: b), .submitted, "submitted is not verified")
    }

    func testSingleProfileNeverReadsAsPartial() {
        let b = broker(1)
        var h = Household()
        let a = Person(displayName: "A")
        h.add(a)
        h.mutateProgress(for: a.id) { $0.complete(b, step: 0) }
        XCTAssertEqual(h.summary(for: b), .submitted)
    }

    func testRecheckDueDateFollowsRecheckDays() {
        let b = broker(1)
        var h = Household()
        let a = Person(displayName: "A")
        h.add(a)
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        h.mutateProgress(for: a.id) { $0.complete(b, step: 0, now: day) }
        guard case .done(_, let due) = h.statuses(for: b)[0].status else { return XCTFail("expected done") }
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: day, to: due).day, 30)
    }

    func testPlainEnglishFallsBackForUnknownTags() {
        XCTAssertEqual(Describe.signal("captcha"), "You solve a CAPTCHA")
        XCTAssertEqual(Describe.signal("brand_new_tag"), "brand new tag")
    }
}

final class AnnouncementTests: XCTestCase {
    private let catalog = [Announcement(id: 1, title: "Welcome", body: ""),
                           Announcement(id: 2, title: "Sites page", body: "")]

    func testFreshInstallGetsWalkthrough() {
        XCTAssertEqual(Announcements.pending(lastSeen: nil, catalog: catalog), .walkthrough)
    }

    func testUpdateWithNoNewMessageShowsNothing() {
        XCTAssertEqual(Announcements.pending(lastSeen: 2, catalog: catalog), .nothing)
    }

    func testUpdateWithNewMessageShowsOnlyTheNewOnes() {
        XCTAssertEqual(Announcements.pending(lastSeen: 1, catalog: catalog), .whatsNew([catalog[1]]))
        XCTAssertEqual(Announcements.newestID(catalog), 2)
    }
}


private struct FakeFetcher: PageFetcher {
    var pages: [String: FetchedPage] = [:]
    var fallback: FetchedPage?
    var fail = false
    /// POST bodies are matched the same way as URLs, against the body text.
    func post(_ url: URL, body: String) async throws -> FetchedPage {
        if fail { throw URLError(.notConnectedToInternet) }
        if let p = pages.first(where: { body.contains($0.key) })?.value { return p }
        if let fallback { return fallback }
        throw URLError(.badURL)
    }
    func fetch(_ url: URL) async throws -> FetchedPage {
        if fail { throw URLError(.notConnectedToInternet) }
        if let p = pages.first(where: { url.absoluteString.contains($0.key) })?.value { return p }
        if let fallback { return fallback }
        throw URLError(.badURL)
    }
}

final class RecheckerTests: XCTestCase {
    private let spec = Recheck(searchURL: "https://broker.example/search?n={first}+{last}&c={city}",
                               validPage: ["search results"], noResults: ["no records found"])
    private func broker(_ recheck: Recheck?) -> Broker {
        Broker(id: "b", name: "B", tier: .A, covers: nil, signals: nil, fields: nil,
               steps: [Step(say: "x")], recheckDays: 30, verified: nil, recheck: recheck)
    }
    private let pat = Person(displayName: "Pat", names: [NameEntry(kind: .legal, name: "Pat Example")],
                             addresses: [Address(city: "Springfield", state: "IL")])
    private func run(_ f: FakeFetcher, person: Person? = nil, spec: Recheck? = nil) async -> CheckOutcome {
        await Rechecker(fetcher: f).check(broker(spec ?? self.spec), for: person ?? pat)
    }

    func testStillListedWhenNameAndCityAppear() async {
        let f = FakeFetcher(fallback: FetchedPage(status: 200, text: "Search results: Pat Example, Springfield IL, age 40"))
        let r = await run(f)
        XCTAssertEqual(r, .stillListed)
    }

    func testRemovedWhenSiteSaysNoResults() async {
        let f = FakeFetcher(fallback: FetchedPage(status: 200, text: "Search results. No records found."))
        let r = await run(f)
        XCTAssertEqual(r, .removed)
    }

    func testRemovedWhenValidPageHasNoMatch() async {
        let f = FakeFetcher(fallback: FetchedPage(status: 200, text: "Search results: Someone Else, Peoria"))
        let r = await run(f)
        XCTAssertEqual(r, .removed)
    }

    func testNameWithoutMatchingCityIsNotAListing() async {
        let f = FakeFetcher(fallback: FetchedPage(status: 200, text: "Search results: Pat Example, Tucson AZ"))
        let r = await run(f)
        XCTAssertEqual(r, .removed)
    }

    func testBlockedIsInconclusiveNeverRemoved() async {
        let r403 = await run(FakeFetcher(fallback: FetchedPage(status: 403, text: "")))
        let cf = await run(FakeFetcher(fallback: FetchedPage(status: 200, text: "Just a moment...")))
        XCTAssertEqual(r403, .inconclusive(.blocked))
        XCTAssertEqual(cf, .inconclusive(.blocked))
    }

    func testChangedPageIsInconclusiveNotRemoved() async {
        // A redesign drops our marker: must not read as "no results".
        let r = await run(FakeFetcher(fallback: FetchedPage(status: 200, text: "<html>Welcome to our new site</html>")))
        XCTAssertEqual(r, .inconclusive(.unrecognizedPage))
    }

    func testNetworkFailureIsInconclusive() async {
        let r = await run(FakeFetcher(fail: true))
        XCTAssertEqual(r, .inconclusive(.network))
    }

    func testAnyNameVariantListedMeansStillListed() async {
        var p = pat
        p.names.append(NameEntry(kind: .previousLegal, name: "Patricia Old"))
        let f = FakeFetcher(pages: ["Patricia": FetchedPage(status: 200, text: "Search results: Patricia Old, Springfield")],
                            fallback: FetchedPage(status: 200, text: "Search results. No records found."))
        let r = await run(f, person: p)
        XCTAssertEqual(r, .stillListed)
    }

    func testMissingSpecOrProfileDataIsInconclusive() async {
        let f = FakeFetcher(fallback: FetchedPage(status: 200, text: "Search results"))
        let noSpec = await Rechecker(fetcher: f).check(broker(nil), for: pat)
        XCTAssertEqual(noSpec, .inconclusive(.noRecheckSpec))
        let nameless = await run(f, person: Person(displayName: "X"))
        XCTAssertEqual(nameless, .inconclusive(.missingProfileData))
        let noCity = await run(f, person: Person(displayName: "X", names: [NameEntry(kind: .legal, name: "Pat Example")]))
        XCTAssertEqual(noCity, .inconclusive(.missingProfileData), "template needs {city}")
    }

    func testRecheckDecodesFromYAML() throws {
        let b = try Registry.decode(yaml: """
        id: t
        name: T
        tier: A
        steps:
          - say: one
        recheck_days: 30
        processing_days: 3
        recheck:
          search_url: "https://x.example/?q={full}"
          valid_page: ["results"]
          no_results: ["none"]
        """)
        XCTAssertEqual(b.recheck?.validPage, ["results"])
        XCTAssertEqual(b.processingDays, 3)
    }
}

final class VerificationTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var broker: Broker {
        Broker(id: "b", name: "B", tier: .A, covers: nil, signals: nil, fields: nil,
               steps: [Step(say: "x")], recheckDays: 30, verified: nil, processingDays: 3)
    }
    private func submitted() -> OptOutKitCore.Progress {
        var p = OptOutKitCore.Progress(); p.complete(broker, step: 0, now: t0); return p
    }

    func testOneRemovedResultIsNotEnough() {
        var p = submitted()
        p.record(.removed, for: "b", on: t0 + 4 * day)
        XCTAssertEqual(p.verification(for: "b"), .unverified)
    }

    func testTwoRemovedOnDifferentDaysVerifies() {
        var p = submitted()
        p.record(.removed, for: "b", on: t0 + 4 * day)
        p.record(.removed, for: "b", on: t0 + 6 * day)
        XCTAssertEqual(p.verification(for: "b"), .verified(since: t0 + 6 * day))
    }

    func testTwoResultsOnTheSameDayDoNotVerify() {
        var p = submitted()
        p.record(.removed, for: "b", on: t0 + 4 * day)
        p.record(.removed, for: "b", on: t0 + 4 * day + 60)
        XCTAssertEqual(p.verification(for: "b"), .unverified)
    }

    func testInconclusiveChecksAreIgnored() {
        var p = submitted()
        p.record(.removed, for: "b", on: t0 + 4 * day)
        p.record(.inconclusive, for: "b", on: t0 + 5 * day)
        p.record(.removed, for: "b", on: t0 + 6 * day)
        XCTAssertEqual(p.verification(for: "b"), .verified(since: t0 + 6 * day))
    }

    func testListedAgainOverridesEarlierVerification() {
        var p = submitted()
        p.record(.removed, for: "b", on: t0 + 4 * day)
        p.record(.removed, for: "b", on: t0 + 6 * day)
        p.record(.stillListed, for: "b", on: t0 + 40 * day)
        XCTAssertEqual(p.verification(for: "b"), .relisted(on: t0 + 40 * day))
    }

    func testChecksBeforeSubmissionAreIgnored() {
        var p = OptOutKitCore.Progress()
        p.record(.stillListed, for: "b", on: t0 - day)
        p.complete(broker, step: 0, now: t0)
        XCTAssertEqual(p.verification(for: "b"), .unverified)
    }

    func testScheduleWaitsForProcessingThenChecksEveryTwoDaysThenMonthly() throws {
        var p = submitted()
        XCTAssertEqual(p.nextCheck(for: broker), Calendar.current.date(byAdding: .day, value: 3, to: t0))
        p.record(.inconclusive, for: "b", on: t0 + 3 * day)
        XCTAssertEqual(p.nextCheck(for: broker), Calendar.current.date(byAdding: .day, value: 2, to: t0 + 3 * day))
        p.record(.removed, for: "b", on: t0 + 4 * day)
        p.record(.removed, for: "b", on: t0 + 6 * day)
        XCTAssertEqual(p.nextCheck(for: broker), Calendar.current.date(byAdding: .day, value: 30, to: t0 + 6 * day))
    }

    func testSummaryReflectsVerificationAndRelisting() {
        var h = Household()
        let a = Person(displayName: "A")
        h.add(a)
        h.mutateProgress(for: a.id) { $0.complete(broker, step: 0, now: self.t0) }
        XCTAssertEqual(h.summary(for: broker), .submitted)
        h.mutateProgress(for: a.id) {
            $0.record(.removed, for: "b", on: self.t0 + 4 * self.day)
            $0.record(.removed, for: "b", on: self.t0 + 6 * self.day)
        }
        XCTAssertEqual(h.summary(for: broker), .complete)
        h.mutateProgress(for: a.id) { $0.record(.stillListed, for: "b", on: self.t0 + 40 * self.day) }
        XCTAssertEqual(h.summary(for: broker), .relisted)
    }
}

final class CheckRunnerTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let spec = Recheck(searchURL: "https://b.example/{first}-{last}/{state_slug}/{city_slug}",
                               validPage: ["results page"], noResults: ["no matches"])
    private var broker: Broker {
        Broker(id: "b", name: "B", tier: .A, covers: nil, signals: nil, fields: nil,
               steps: [Step(say: "x")], recheckDays: 30, verified: nil, processingDays: 3, recheck: spec)
    }
    private let pat = Person(displayName: "Pat", names: [NameEntry(kind: .legal, name: "Pat Example")],
                             addresses: [Address(city: "New York", state: "NY")])

    private func household(submitted: Bool = true) -> Household {
        var h = Household()
        h.add(pat)
        if submitted { h.mutateProgress(for: pat.id) { $0.complete(self.broker, step: 0, now: self.t0) } }
        return h
    }

    func testNothingDueBeforeProcessingTimeThenDue() {
        let h = household()
        XCTAssertTrue(CheckRunner.due(in: h, brokers: [broker], now: t0 + 1 * day).isEmpty)
        XCTAssertEqual(CheckRunner.due(in: h, brokers: [broker], now: t0 + 3 * day).count, 1)
    }

    func testBrokersWithoutRecheckSpecAndUnsubmittedAreNeverDue() {
        var noSpec = broker; noSpec.recheck = nil
        XCTAssertTrue(CheckRunner.due(in: household(), brokers: [noSpec], now: t0 + 30 * day).isEmpty)
        XCTAssertTrue(CheckRunner.due(in: household(submitted: false), brokers: [broker], now: t0 + 30 * day).isEmpty)
    }

    func testTwoRoundsOfRemovedProduceAVerifiedEventOnce() async {
        var h = household()
        let runner = CheckRunner(fetcher: FakeFetcher(fallback: FetchedPage(status: 404, text: "Results page: no matches")))
        let first = await runner.run(CheckRunner.due(in: h, brokers: [broker], now: t0 + 3 * day), spacing: 0)
        XCTAssertEqual(h.apply(first, now: t0 + 3 * day), [], "one check is not enough")

        let second = await runner.run(CheckRunner.due(in: h, brokers: [broker], now: t0 + 5 * day), spacing: 0)
        XCTAssertEqual(h.apply(second, now: t0 + 5 * day), [.verified(personID: pat.id, brokerID: "b")])
        XCTAssertEqual(h.summary(for: broker), .complete)
        XCTAssertTrue(CheckRunner.due(in: h, brokers: [broker], now: t0 + 6 * day).isEmpty, "next check is a month away")
    }

    func testRelistingProducesAnEvent() async {
        var h = household()
        h.mutateProgress(for: pat.id) {
            $0.record(.removed, for: "b", on: self.t0 + 4 * self.day)
            $0.record(.removed, for: "b", on: self.t0 + 6 * self.day)
        }
        let runner = CheckRunner(fetcher: FakeFetcher(fallback: FetchedPage(status: 200, text: "Results page: Pat Example, New York")))
        let out = await runner.run(CheckRunner.due(in: h, brokers: [broker], now: t0 + 40 * day), spacing: 0)
        XCTAssertEqual(h.apply(out, now: t0 + 40 * day), [.relisted(personID: pat.id, brokerID: "b")])
    }

    func testBlockedChecksChangeNothingAndStayDue() async {
        var h = household()
        let runner = CheckRunner(fetcher: FakeFetcher(fallback: FetchedPage(status: 403, text: "")))
        let out = await runner.run(CheckRunner.due(in: h, brokers: [broker], now: t0 + 3 * day), spacing: 0)
        XCTAssertEqual(h.apply(out, now: t0 + 3 * day), [])
        XCTAssertEqual(h.summary(for: broker), .submitted)
    }

    func testSearchURLUsesStateNameAndSlugs() {
        let url = Rechecker.url(spec.searchURL, name: "Pat Example", city: "New York", state: "NY")
        XCTAssertEqual(url?.absoluteString, "https://b.example/Pat-Example/New-York/New-York")
    }

    func testNotFoundPageServedAs404IsStillRecognised() async {
        let r = await Rechecker(fetcher: FakeFetcher(fallback: FetchedPage(status: 404, text: "Results page. No matches")))
            .check(broker, for: pat)
        XCTAssertEqual(r, .removed)
    }
}

/// Talks to the real internet, so it only runs when asked: OPTOUT_LIVE=1 swift test --filter LiveSpokeoTests
final class LiveSpokeoTests: XCTestCase {
    private var spokeo: Broker {
        get throws {
            let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("brokers")
            return try XCTUnwrap(try Registry.load(directory: dir).first { $0.id == "spokeo" })
        }
    }

    func testMadeUpNameReadsAsRemovedAndCommonNameAsListed() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPTOUT_LIVE"] == "1", "set OPTOUT_LIVE=1 to run")
        let checker = Rechecker(fetcher: URLSessionFetcher())
        let nobody = Person(displayName: "N", names: [NameEntry(kind: .legal, name: "Zzyzx Qwertyuiop")],
                            addresses: [Address(city: "Springfield", state: "IL")])
        let common = Person(displayName: "C", names: [NameEntry(kind: .legal, name: "John Smith")],
                            addresses: [Address(city: "Springfield", state: "IL")])
        let gone = await checker.check(try spokeo, for: nobody)
        let listed = await checker.check(try spokeo, for: common)
        XCTAssertEqual(gone, .removed)
        XCTAssertEqual(listed, .stillListed)
    }
}

/// Read-only dry run against the live Spokeo search for a real person. The details come from the environment so
/// no personal data is ever committed: OPTOUT_LIVE=1 OPTOUT_NAME="First Last" OPTOUT_CITY=... OPTOUT_STATE=XX
final class LiveDryRunTests: XCTestCase {
    func testScanSpokeoForPersonFromEnvironment() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["OPTOUT_LIVE"] == "1", "set OPTOUT_LIVE=1 to run")
        let name = try XCTUnwrap(env["OPTOUT_NAME"]), city = try XCTUnwrap(env["OPTOUT_CITY"]), state = try XCTUnwrap(env["OPTOUT_STATE"])
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("brokers")
        let spokeo = try XCTUnwrap(try Registry.load(directory: dir).first { $0.id == "spokeo" })
        let person = Person(displayName: "Me", names: [NameEntry(kind: .legal, name: name)],
                            addresses: [Address(city: city, state: state)])
        let outcome = await Rechecker(fetcher: URLSessionFetcher()).check(spokeo, for: person)
        print("DRYRUN outcome: \(outcome.result.rawValue) reason: \(outcome.reason?.rawValue ?? "none")")
    }
}

final class PipelineTests: XCTestCase {
    private func broker(calibration: Bool = true) -> Broker {
        Broker(id: "b", name: "B", tier: .A, covers: nil, signals: nil, fields: nil,
               steps: [Step(open: URL(string: "https://b.example/optout")!)], recheckDays: 30, verified: nil,
               recheck: Recheck(searchURL: "https://b.example/{first}-{last}", validPage: ["directory"],
                                noResults: ["no result"], ignoreLocation: true,
                                calibration: calibration ? .init(listedName: "John Smith") : nil))
    }

    func testPassesWhenCheckSeparatesMadeUpFromKnownName() async {
        let f = FakeFetcher(pages: ["Zzyzx": FetchedPage(status: 404, text: "Directory: No result for this name"),
                                    "John": FetchedPage(status: 200, text: "Directory: 5 reports for John Smith")],
                            fallback: FetchedPage(status: 200, text: "Directory home"))
        let rows = await BrokerPipeline(fetcher: f, spacing: 0).run([broker()])
        XCTAssertEqual(rows[0].status, .pass)
        XCTAssertTrue(BrokerPipeline.markdown(rows).contains("1 pass"))
    }

    func testFailsWhenTheKnownNameIsNotFound() async {
        // The page still looks right but the matcher no longer finds people: a silent drift the pipeline must catch.
        let f = FakeFetcher(fallback: FetchedPage(status: 404, text: "Directory: No result"))
        let rows = await BrokerPipeline(fetcher: f, spacing: 0).run([broker()])
        guard case .fail = rows[0].status else { return XCTFail("expected fail, got \(rows[0].status)") }
    }

    func testBlockedSiteIsReportedBlockedNotFailed() async {
        let rows = await BrokerPipeline(fetcher: FakeFetcher(fallback: FetchedPage(status: 403, text: "")), spacing: 0).run([broker()])
        XCTAssertEqual(rows[0].status, .blocked)
        XCTAssertTrue(rows[0].steps[0].blocked)
    }

    func testBrokerWithoutRecheckNeedsResearch() async {
        var b = broker(); b.recheck = nil
        let rows = await BrokerPipeline(fetcher: FakeFetcher(fallback: FetchedPage(status: 200, text: "hi")), spacing: 0).run([b])
        XCTAssertEqual(rows[0].status, .needsResearch)
    }

    func testChangedPageFailsTheCalibration() async {
        let f = FakeFetcher(fallback: FetchedPage(status: 200, text: "Brand new site, nothing recognisable"))
        let rows = await BrokerPipeline(fetcher: f, spacing: 0).run([broker()])
        guard case .fail = rows[0].status else { return XCTFail("a redesign must fail, not pass: \(rows[0].status)") }
    }

    func testCensusClassifiesPages() {
        XCTAssertEqual(Census.classify(nil), .unreachable)
        XCTAssertEqual(Census.classify(FetchedPage(status: 403, text: "")), .blocked)
        XCTAssertEqual(Census.classify(FetchedPage(status: 200, text: "<div class=g-recaptcha>")), .captchaMarker)
        XCTAssertEqual(Census.classify(FetchedPage(status: 200, text: "hello")), .reachable)
    }
}

final class DirectoryTests: XCTestCase {
    private var directoryURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("directory")
    }

    func testGeneratedDirectoryDecodesAndIsComplete() throws {
        let entries = try Registry.loadDirectory(directoryURL)
        XCTAssertGreaterThanOrEqual(entries.count, 200, "the 212 EasyOptOuts sites")
        XCTAssertTrue(entries.allSatisfy { !$0.domain.isEmpty && $0.id == $0.domain.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: "-", with: "_") })
    }

    func testEverySiteMarkedClosedCarriesItsEvidenceAndNoWayToOptOut() throws {
        let closed = try Registry.loadDirectory(directoryURL).filter { $0.closed != nil }
        XCTAssertGreaterThanOrEqual(closed.count, 10)
        for e in closed {
            XCTAssertGreaterThanOrEqual(e.closed?.evidence.count ?? 0, 4, "\(e.domain): two tries at two addresses")
            XCTAssertTrue(e.optOutForm == nil && e.contactEmail == nil && e.liveForm?.found != true, "\(e.domain) has a way to opt out")
        }
    }

    func testFoundFormsDecodeWithTheirFields() throws {
        let entries = try Registry.loadDirectory(directoryURL)
        let withForm = entries.filter { $0.optOutForm != nil }
        XCTAssertFalse(withForm.isEmpty, "the profiler should have found some real opt-out forms")
        XCTAssertTrue(withForm.allSatisfy { !$0.optOutForm!.fields.isEmpty })
    }

    func testFormFieldDisplayNames() {
        XCTAssertEqual(FormField(type: "text", name: "fname", label: "First Name:").display, "First Name")
        XCTAssertEqual(FormField(type: "text", name: "model[city]", label: "").display, "City")
    }

    func testGuidedSitesAreNotListedTwice() {
        let flow = Broker(id: "spokeo", name: "Spokeo", tier: .A, covers: ["freepeopledirectory.com"], signals: nil, fields: nil,
                          steps: [Step(say: "x")], recheckDays: 30, verified: nil)
        func entry(_ d: String) -> DirectoryEntry {
            DirectoryEntry(id: d.replacingOccurrences(of: ".", with: "_"), domain: d, name: d, bucket: "direct", tier: nil,
                           automation: .unknown, confidence: nil, optOutURL: nil, optOutForm: nil, family: nil, familyParent: nil, template: nil, searchCheck: nil, signals: nil, profiled: nil)
        }
        let left = Directory.unguided([entry("spokeo.com"), entry("freepeopledirectory.com"), entry("other.com")], brokers: [flow])
        XCTAssertEqual(left.map(\.domain), ["other.com"])
    }

    func testFamilySize() {
        func e(_ d: String, _ f: String?) -> DirectoryEntry {
            DirectoryEntry(id: d, domain: d, name: d, bucket: "direct", tier: .B, automation: .guided, confidence: nil,
                           optOutURL: nil, optOutForm: nil, family: f, familyParent: nil, template: nil, searchCheck: nil, signals: nil, profiled: nil)
        }
        let all = [e("a.us", "x"), e("b.us", "x"), e("c.us", nil)]
        XCTAssertEqual(Directory.familySize(of: all[0], in: all), 2)
        XCTAssertEqual(Directory.familySize(of: all[2], in: all), 1)
    }
}

final class ExposureScanTests: XCTestCase {
    private func entry(_ domain: String, check: SearchCheck?) -> DirectoryEntry {
        DirectoryEntry(id: domain.replacingOccurrences(of: ".", with: "_"), domain: domain, name: domain, bucket: "direct",
                       tier: .B, automation: .guided, confidence: nil, optOutURL: nil, optOutForm: nil, family: nil,
                       familyParent: nil, template: nil, searchCheck: check, signals: nil, profiled: nil)
    }
    private func check(_ url: String) -> SearchCheck {
        SearchCheck(status: .calibrated, searchURL: url, validPage: ["directory"], noResults: ["no result"],
                    ignoreLocation: true, calibration: nil, checked: nil)
    }
    private let pat = Person(displayName: "P", names: [NameEntry(kind: .legal, name: "Pat Example")])

    func testScanCoversOnlyCalibratedSitesAndReportsEachOutcome() async {
        let entries = [
            entry("listed.example", check: check("https://listed.example/{first}-{last}")),
            entry("clean.example", check: check("https://clean.example/{first}-{last}")),
            entry("blocked.example", check: SearchCheck(status: .blocked)),
            entry("nosearch.example", check: nil),
        ]
        let fetcher = FakeFetcher(pages: [
            "listed.example": FetchedPage(status: 200, text: "Directory: Pat Example lives here"),
            "clean.example": FetchedPage(status: 404, text: "Directory: No result for this name"),
        ])
        let results = await ExposureScan(fetcher: fetcher, perHostSpacing: 0).run(entries, for: pat)
        XCTAssertEqual(results.map(\.entry.domain), ["clean.example", "listed.example"])
        XCTAssertEqual(results.first { $0.entry.domain == "listed.example" }?.outcome, .stillListed)
        XCTAssertEqual(results.first { $0.entry.domain == "clean.example" }?.outcome, .removed)
    }

    func testSearchCheckOnlyBecomesARecheckWhenCalibrated() {
        XCTAssertNotNil(check("https://x.example/{full}").recheck)
        XCTAssertNil(SearchCheck(status: .undifferentiated).recheck)
        XCTAssertNil(SearchCheck(status: .calibrated, searchURL: "https://x.example/{full}", validPage: [], noResults: nil,
                                 ignoreLocation: nil, calibration: nil, checked: nil).recheck)
    }

    func testProgressIsReported() async {
        let entries = (1...5).map { entry("s\($0).example", check: check("https://s\($0).example/{first}-{last}")) }
        let fetcher = FakeFetcher(fallback: FetchedPage(status: 200, text: "Directory: nothing here"))
        let counter = ProgressCounter()
        _ = await ExposureScan(fetcher: fetcher, perHostSpacing: 0).run(entries, for: pat, progress: { done, total in
            Task { await counter.record(done, total) }
        })
        try? await Task.sleep(nanoseconds: 100_000_000)
        let last = await counter.last
        XCTAssertEqual(last?.1, 5)
    }
}

private actor ProgressCounter {
    var last: (Int, Int)?
    func record(_ d: Int, _ t: Int) { if d >= (last?.0 ?? 0) { last = (d, t) } }
}


final class PostCheckTests: XCTestCase {
    private let spec = Recheck(searchURL: "https://b.example/search", validPage: ["directory"], noResults: ["no result"],
                               ignoreLocation: false, method: "POST", body: "firstname={first}&lastname={last}&city={city}&state={state}")
    private func broker() -> Broker {
        Broker(id: "b", name: "B", tier: .B, covers: nil, signals: nil, fields: nil,
               steps: [Step(say: "x")], recheckDays: 30, verified: nil, recheck: spec)
    }
    private let pat = Person(displayName: "Pat", names: [NameEntry(kind: .legal, name: "Pat Example")],
                             addresses: [Address(city: "Springfield", state: "IL")])

    func testBodyIsFilledAndEncodedForPOST() {
        XCTAssertEqual(Rechecker.fill(spec.body!, name: "Mary-Ann O'Neil", city: "St Louis", state: "MO", encoding: .form),
                       "firstname=Mary-Ann&lastname=O%27Neil&city=St%20Louis&state=MO")
    }

    func testPostSearchFindsListing() async {
        let f = FakeFetcher(pages: ["firstname=Pat": FetchedPage(status: 200, text: "Directory: Pat Example, Springfield")])
        let r = await Rechecker(fetcher: f).check(broker(), for: pat)
        XCTAssertEqual(r, .stillListed)
    }

    func testPostSearchNoResults() async {
        let f = FakeFetcher(fallback: FetchedPage(status: 200, text: "Directory: no result"))
        let r = await Rechecker(fetcher: f).check(broker(), for: pat)
        XCTAssertEqual(r, .removed)
    }

    func testFetcherThatCannotPostIsInconclusiveNotRemoved() async {
        struct GetOnly: PageFetcher { func fetch(_ url: URL) async throws -> FetchedPage { FetchedPage(status: 200, text: "Directory: no result") } }
        let r = await Rechecker(fetcher: GetOnly()).check(broker(), for: pat)
        XCTAssertEqual(r, .inconclusive(.network))
    }

    func testPostNeedsTheBodyPlaceholdersFilled() async {
        let noCity = Person(displayName: "X", names: [NameEntry(kind: .legal, name: "Pat Example")])
        let r = await Rechecker(fetcher: FakeFetcher(fallback: FetchedPage(status: 200, text: "Directory"))).check(broker(), for: noCity)
        XCTAssertEqual(r, .inconclusive(.missingProfileData))
    }
}


final class BrowserSpecTests: XCTestCase {
    private let spec = Recheck(searchURL: "https://b.example/{first}-{last}", validPage: ["directory"], noResults: ["no result"],
                               needsBrowser: true, ignoreLocation: true)
    private let pat = Person(displayName: "P", names: [NameEntry(kind: .legal, name: "Pat Example")])

    func testSpecThatNeedsABrowserIsInconclusiveWithoutOne() async {
        let plain = FakeFetcher(fallback: FetchedPage(status: 200, text: "Directory: loading"))
        let r = await Rechecker(fetcher: plain).check(spec: spec, for: pat)
        XCTAssertEqual(r, .inconclusive(.needsBrowser))
    }

    func testSpecThatNeedsABrowserUsesTheBrowserFetcherNotThePlainOne() async {
        let plain = FakeFetcher(fallback: FetchedPage(status: 200, text: "Directory: Pat Example is listed"))   // would read as listed
        let browser = FakeFetcher(fallback: FetchedPage(status: 200, text: "Directory: no result"))
        let r = await Rechecker(fetcher: plain, browserFetcher: browser).check(spec: spec, for: pat)
        XCTAssertEqual(r, .removed)
    }

    func testTermsGatedSitesAreNeverScanned() {
        let gated = SearchCheck(status: .termsGate)
        XCTAssertNil(gated.recheck)
        XCTAssertEqual(gated.statusLabel, "Results are behind terms you must accept yourself")
    }
}

final class ScoringTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testPointsAreForLookingNotForTappingDone() {
        var p = OptOutKitCore.Progress()
        XCTAssertEqual(Score.compute(p, brokers: []).points, 0)
        p.recordSiteCheck(.removed, site: "a", source: .selfReported, on: t0)
        p.recordSiteCheck(.stillListed, site: "b", source: .selfReported, on: t0)
        p.recordSiteCheck(.removed, site: "c", source: .automatic, on: t0)
        p.recordSiteCheck(.inconclusive, site: "d", source: .automatic, on: t0)
        XCTAssertEqual(Score.compute(p, brokers: []).points, 5 + 3 + 2)
    }

    func testOnlyTheLatestLookAtASiteCounts() {
        var p = OptOutKitCore.Progress()
        p.recordSiteCheck(.removed, site: "a", source: .selfReported, on: t0)
        p.recordSiteCheck(.stillListed, site: "a", source: .selfReported, on: t0 + 86_400)
        XCTAssertEqual(Score.compute(p, brokers: []).points, 3, "a re-listing replaces the old clean look; no double counting")
    }

    func testVerifiedOptOutsEarnTenAndLevelsAdvance() {
        let b = Broker(id: "b", name: "B", tier: .A, covers: nil, signals: nil, fields: nil,
                       steps: [Step(say: "x")], recheckDays: 30, verified: nil, processingDays: 3)
        var p = OptOutKitCore.Progress()
        p.complete(b, step: 0, now: t0)
        XCTAssertEqual(Score.compute(p, brokers: [b]).points, 0, "submitted is not verified")
        p.record(.removed, for: "b", on: t0 + 4 * 86_400)
        p.record(.removed, for: "b", on: t0 + 6 * 86_400)
        let s = Score.compute(p, brokers: [b])
        XCTAssertEqual(s.points, 10)
        XCTAssertEqual(s.level.name, "Exposed")
        XCTAssertEqual(s.nextLevelAt, 25)
        for i in 0..<5 { p.recordSiteCheck(.removed, site: "s\(i)", source: .selfReported, on: t0) }
        XCTAssertEqual(Score.compute(p, brokers: [b]).level.name, "Covering Tracks")
    }

    func testOldSavedRecordsWithoutASourceStillDecode() throws {
        let json = #"{"date": 0, "result": "removed"}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(CheckRecord.self, from: json)
        XCTAssertEqual(r.source, .automatic)
    }

    func testLookupURLUsesTheSearchWhenItIsAPlainGet() {
        var e = DirectoryEntry(id: "x_us", domain: "x.us", name: "x.us", bucket: "direct", tier: .B, automation: .guided, confidence: nil,
                               optOutURL: nil, optOutForm: nil, family: nil, familyParent: nil, template: nil,
                               searchCheck: SearchCheck(status: .undifferentiated, candidate: .init(method: "GET", url: "https://x.us/find?n={first}+{last}", body: nil)),
                               signals: nil, profiled: nil)
        let pat = Person(displayName: "P", names: [NameEntry(kind: .legal, name: "Pat Example")])
        XCTAssertEqual(e.lookupURL(for: pat).absoluteString, "https://x.us/find?n=Pat+Example")
        e.searchCheck = SearchCheck(status: .undifferentiated, candidate: .init(method: "POST", url: "https://x.us/s", body: "a={first}"))
        XCTAssertEqual(e.lookupURL(for: pat).absoluteString, "https://x.us/", "a POST search cannot be linked to; open the home page")
        XCTAssertTrue(e.needsManualCheck)
    }
}

final class TermsTextTests: XCTestCase {
    private struct Fixture: Decodable { var domain: String; var input: String; var canonical: String; var hash: String }
    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Python (tools/terms_canon.py) wrote these. Swift must produce byte-identical canonical text and hashes.
    func testSwiftMatchesPythonCanonicalizationFixtures() throws {
        let data = try Data(contentsOf: repo.appendingPathComponent("terms/canonicalization-fixtures.json"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: data)
        XCTAssertGreaterThanOrEqual(fixtures.count, 5)
        for f in fixtures {
            let canon = TermsText.canonical(f.input, domain: f.domain)
            XCTAssertEqual(canon, f.canonical, "canonical text differs for \(f.domain)")
            XCTAssertEqual(TermsText.hash(ofCanonical: canon), f.hash, "hash differs for \(f.domain)")
        }
    }

    func testSameTermsOnDifferentSitesCompareEqual() {
        let a = "Welcome to Alabama Arrests. By using alabamaarrests.org you accept these terms of use in full for the year 2026."
        let b = "Welcome to Ohio Arrests. By using ohioarrests.org you accept these terms of use in full for the year 2025."
        XCTAssertEqual(TermsText.canonical(a, domain: "alabamaarrests.org"), TermsText.canonical(b, domain: "ohioarrests.org"))
    }

    func testAnyOtherChangeBreaksTheMatch() {
        let a = "Welcome to Alabama Arrests. By using alabamaarrests.org you accept these terms of use in full for the year 2026."
        let c = "Welcome to Ohio Arrests. By using ohioarrests.org you accept these terms of use in full and agree to pay a fee."
        XCTAssertNotEqual(TermsText.canonical(a, domain: "alabamaarrests.org"), TermsText.canonical(c, domain: "ohioarrests.org"))
    }

    func testShortLinesAreChromeNotTerms() {
        let doc = "Home\nCourt Records\nTerms\nThis paragraph has plenty of words so it counts as a real clause of the terms of use here.\nPrivacy"
        XCTAssertEqual(TermsText.substantial(doc).count, 1)
    }
}

final class TermsGateTests: XCTestCase {
    private let domain = "alabamaarrests.org"
    private let clause = "You agree to use the information on this site for lawful purposes only and not to harass anyone at any time."
    private func lib(ok: Bool = true, verdict: String? = "ok", flags: [String] = [], version: Int = 7) -> TermsLibrary {
        let h = TermsText.hash(ofCanonical: TermsText.canonical(clause, domain: domain))
        return TermsLibrary(version: version, paragraphs: [TermsParagraph(hash: h, sites: 3, kinds: ["terms"], flags: flags, prefix: "", reviewed: ok, verdict: verdict)])
    }
    private let approved = TermsApproval(libraryVersion: 7)

    func testAcceptsOnlyWhenReviewedMatchingAndApproved() {
        XCTAssertEqual(TermsGate.decide(prompt: clause, documents: [], domain: domain, library: lib(), approval: approved),
                       .accept(paragraphs: 1, libraryVersion: 7))
    }

    func testNeverAcceptsWithoutThePersonsApprovalOrAfterTheListChanged() {
        XCTAssertEqual(TermsGate.decide(prompt: clause, documents: [], domain: domain, library: lib(), approval: nil), .notApproved(paragraphs: 1))
        XCTAssertEqual(TermsGate.decide(prompt: clause, documents: [], domain: domain, library: lib(version: 8), approval: approved), .notApproved(paragraphs: 1))
    }

    func testAnUnreviewedOrNewParagraphBlocksAcceptance() {
        XCTAssertEqual(TermsGate.decide(prompt: clause, documents: [], domain: domain, library: lib(ok: false, verdict: nil), approval: approved), .unreviewed(count: 1))
        let extra = "A brand new clause appeared in these terms of use that nobody on our team has ever read or approved for acceptance."
        XCTAssertEqual(TermsGate.decide(prompt: clause, documents: [extra], domain: domain, library: lib(), approval: approved), .unreviewed(count: 1))
    }

    func testExcludedAndAutomationParagraphsAreNeverAcceptedEvenIfMarkedOk() {
        XCTAssertEqual(TermsGate.decide(prompt: clause, documents: [], domain: domain, library: lib(verdict: "exclude"), approval: approved), .excluded(flags: ["excluded by reviewer"]))
        XCTAssertEqual(TermsGate.decide(prompt: clause, documents: [], domain: domain, library: lib(flags: ["automation"]), approval: approved), .excluded(flags: ["automation"]))
    }

    func testNoTextMeansNothingIsAccepted() {
        XCTAssertEqual(TermsGate.decide(prompt: "I agree", documents: ["Home"], domain: domain, library: lib(), approval: approved), .nothingToJudge)
    }

    func testApprovalAndConsentLogLiveInTheHouseholdAndSurviveEncoding() throws {
        var h = Household()
        h.approveTerms(libraryVersion: 7)
        h.logConsent(ConsentLogEntry(domain: domain, paragraphs: 3, libraryVersion: 7))
        let back = try JSONDecoder().decode(Household.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(back.termsApproval?.libraryVersion, 7)
        XCTAssertEqual(back.consentLog.count, 1)
        h.revokeTermsApproval()
        XCTAssertNil(h.termsApproval)
        let old = try JSONDecoder().decode(Household.self, from: Data(#"{"people":[],"progress":[]}"#.utf8))
        XCTAssertNil(old.termsApproval, "data saved before this feature still loads")
    }

    func testTheGeneratedLibraryDecodesAndStartsWithNothingReviewed() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("terms/library.yml")
        let library = try TermsLibrary.load(url)
        XCTAssertGreaterThan(library.paragraphs.count, 100)
        XCTAssertEqual(library.reviewedCount, 0, "a person must read paragraphs before any are marked reviewed; this repo ships none")
    }
}

final class TermsGateReportingTests: XCTestCase {
    func testAPageLeftBehindATermsPromptIsInconclusiveNeverRemoved() async {
        let spec = Recheck(searchURL: "https://b.example/{first}-{last}", validPage: ["directory"], noResults: ["no result"], ignoreLocation: true)
        let page = FetchedPage(status: 200, text: "Directory No result \n\(Rechecker.termsGateMarker)")
        let person = Person(displayName: "P", names: [NameEntry(kind: .legal, name: "Pat Example")])
        let r = await Rechecker(fetcher: FakeFetcher(fallback: page)).check(spec: spec, for: person)
        XCTAssertEqual(r, .inconclusive(.termsGate))
    }
}


final class SafetyFlagTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private func born(yearsAgo: Int, daysOffset: Int = 0) -> String {
        let d = Calendar.current.date(byAdding: .year, value: -yearsAgo, to: Date())!.addingTimeInterval(Double(daysOffset) * 86_400)
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    func testFamilyOnlyAndOldFriendsReadBackAsOtherFamily() throws {
        XCTAssertFalse(Relationship.allCases.map(\.rawValue).contains("friend"))
        XCTAssertEqual(try JSONDecoder().decode(Relationship.self, from: Data("\"friend\"".utf8)), .otherFamily)
        XCTAssertEqual(try JSONDecoder().decode(Relationship.self, from: Data("\"other\"".utf8)), .otherFamily)
        XCTAssertEqual(try JSONDecoder().decode(Relationship.self, from: Data("\"parent\"".utf8)), .parent)
    }

    func testBothFlagsDefaultToNoAndAnAdultCanBeSearched() {
        let p = Person(displayName: "P")
        XCTAssertFalse(p.isMinor)
        XCTAssertFalse(p.isPublicFigure)
        XCTAssertTrue(p.canBeSearched())
    }

    func testEitherFlagStopsSearching() {
        XCTAssertFalse(Person(displayName: "K", isMinor: true).canBeSearched())
        XCTAssertFalse(Person(displayName: "F", isPublicFigure: true).canBeSearched())
    }

    func testABirthdateUnderEighteenCountsAsAMinorEvenWithTheFlagOff() {
        var p = Person(displayName: "K")
        p.birthdate = born(yearsAgo: 12)
        XCTAssertTrue(p.isMinorNow())
        XCTAssertFalse(p.canBeSearched())
        p.birthdate = born(yearsAgo: 18, daysOffset: -2)      // turned 18 two days ago
        XCTAssertFalse(p.isMinorNow())
        p.birthdate = born(yearsAgo: 18, daysOffset: 2)       // turns 18 in two days
        XCTAssertTrue(p.isMinorNow())
        p.birthdate = "not a date"
        XCTAssertFalse(p.isMinorNow())
    }

    func testProfilesSavedBeforeTheFlagsExistStillLoadWithBothOff() throws {
        let id = UUID().uuidString
        let json = #"{"id":"\#(id)","displayName":"Old","relationship":"friend","names":[],"addresses":[],"emails":[],"phones":[]}"#
        let p = try JSONDecoder().decode(Person.self, from: Data(json.utf8))
        XCTAssertEqual(p.relationship, .otherFamily)
        XCTAssertFalse(p.isMinor); XCTAssertFalse(p.isPublicFigure)
    }

    func testRechecksAndScansNeverRunForAMinorOrPublicFigure() async {
        let spec = Recheck(searchURL: "https://b.example/{first}-{last}", validPage: ["directory"], noResults: ["no result"], ignoreLocation: true)
        let fetcher = FakeFetcher(fallback: FetchedPage(status: 200, text: "Directory: Pat Example is here"))
        for person in [Person(displayName: "K", names: [NameEntry(kind: .legal, name: "Pat Example")], isMinor: true),
                       Person(displayName: "F", names: [NameEntry(kind: .legal, name: "Pat Example")], isPublicFigure: true)] {
            let r = await Rechecker(fetcher: fetcher).check(spec: spec, for: person)
            XCTAssertEqual(r, .inconclusive(.notSearchable))
            let entry = DirectoryEntry(id: "b_example", domain: "b.example", name: "b.example", bucket: "direct", tier: .B, automation: .guided,
                                       confidence: nil, optOutURL: nil, optOutForm: nil, family: nil, familyParent: nil, template: nil,
                                       searchCheck: SearchCheck(status: .calibrated, searchURL: spec.searchURL, validPage: ["directory"], noResults: ["no result"], ignoreLocation: true),
                                       signals: nil, profiled: nil)
            let scan = await ExposureScan(fetcher: fetcher, perHostSpacing: 0).run([entry], for: person)
            XCTAssertTrue(scan.isEmpty, "no site may be searched for \(person.displayName)")
        }
    }

    func testAutomaticRechecksSkipFlaggedPeopleButNotOthers() {
        let broker = Broker(id: "b", name: "B", tier: .A, covers: nil, signals: nil, fields: nil, steps: [Step(say: "x")], recheckDays: 30,
                            verified: nil, processingDays: 3,
                            recheck: Recheck(searchURL: "https://b.example/{first}-{last}", validPage: ["d"], ignoreLocation: true))
        var h = Household()
        let adult = Person(displayName: "A"), kid = Person(displayName: "K", isMinor: true)
        h.add(adult); h.add(kid)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for p in [adult, kid] { h.mutateProgress(for: p.id) { $0.complete(broker, step: 0, now: t0) } }
        let due = CheckRunner.due(in: h, brokers: [broker], now: t0 + 5 * day)
        XCTAssertEqual(due.map(\.person.displayName), ["A"], "the opt-out is submitted for both, but only the adult is searched")
    }
}


final class PaywallAnswerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testBlockedByPaymentEarnsPointsButIsNeverAVerdict() {
        var p = OptOutKitCore.Progress()
        p.recordSiteCheck(.paywalled, site: "a", source: .selfReported, on: t0)
        XCTAssertEqual(Score.compute(p, brokers: []).points, 2)
        XCTAssertFalse(CheckResult.paywalled.isConclusive)
        XCTAssertNotNil(p.latestSiteCheck("a"), "it counts as a look, so the site is not asked about again soon")
    }

    func testAPaywalledLookCannotVerifyOrRelistAnOptOut() {
        let b = Broker(id: "b", name: "B", tier: .A, covers: nil, signals: nil, fields: nil, steps: [Step(say: "x")], recheckDays: 30, verified: nil, processingDays: 3)
        var p = OptOutKitCore.Progress()
        p.complete(b, step: 0, now: t0)
        p.record(.removed, for: "b", on: t0 + 4 * 86_400)
        p.record(.paywalled, for: "b", on: t0 + 5 * 86_400)
        p.record(.paywalled, for: "b", on: t0 + 6 * 86_400)
        XCTAssertEqual(p.verification(for: "b"), .unverified, "one real result plus two paywalled looks is still one result")
    }

    func testAnOlderFileWithoutThePaywallCaseStillDecodes() throws {
        let r = try JSONDecoder().decode(CheckRecord.self, from: Data(#"{"date":0,"result":"removed"}"#.utf8))
        XCTAssertEqual(r.result, .removed)
        XCTAssertEqual(try JSONDecoder().decode(CheckResult.self, from: Data("\"paywalled\"".utf8)), .paywalled)
    }
}

final class AutoOptOutTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func form(_ fields: [(String, String, String)], hops: Int = 1) -> OptOutForm {
        OptOutForm(page: URL(string: "https://x.example/optout")!, method: "post", action: URL(string: "https://x.example/optout")!,
                   fields: fields.map { FormField(type: $0.0, name: $0.1, label: $0.2) }, hops: hops)
    }
    private func entry(_ id: String, form: OptOutForm?, signals: [String]? = nil) -> DirectoryEntry {
        DirectoryEntry(id: id, domain: "\(id).example", name: id, bucket: "direct", tier: .B, automation: .guided, confidence: nil,
                       optOutURL: nil, optOutForm: form, family: nil, familyParent: nil, template: nil, searchCheck: nil, signals: signals, profiled: nil)
    }
    private let pat = Person(displayName: "Pat", names: [NameEntry(kind: .legal, name: "Pat Example")],
                            addresses: [Address(street: "1 Main St", city: "Springfield", state: "IL")], emails: ["pat@example.com"])

    // MARK: field mapping

    func testMapsAProfileOntoACommonOptOutForm() {
        let f = form([("text", "firstname", "First Name*"), ("text", "lastname", "Last Name*"), ("email", "email", "Email"),
                      ("text", "city", "City"), ("select", "state", "State"), ("hidden", "token", "")])
        let plan = FormFiller.plan(for: f, signals: nil, person: pat)
        XCTAssertEqual(plan.verdict, .ready)
        XCTAssertEqual(plan.values.first { $0.name == "firstname" }?.candidates, ["Pat"])
        XCTAssertEqual(plan.values.first { $0.name == "lastname" }?.candidates, ["Example"])
        XCTAssertEqual(plan.values.first { $0.name == "email" }?.candidates, ["pat@example.com"])
        XCTAssertEqual(plan.values.first { $0.name == "state" }?.candidates, ["IL", "Illinois"], "a dropdown gets the code and the full name to match")
        XCTAssertNil(plan.values.first { $0.name == "token" }, "hidden fields are left as the site set them")
    }

    func testAskForWhatIsMissingInsteadOfGuessing() {
        let noEmail = Person(displayName: "P", names: [NameEntry(kind: .legal, name: "Pat Example")])
        let plan = FormFiller.plan(for: form([("email", "email", "Email")]), signals: nil, person: noEmail)
        XCTAssertEqual(plan.verdict, .needsData(["email address"]))
    }

    func testAttestationBoxesAreNeverTickedForAnyone() {
        let f = form([("email", "email", "Email"), ("checkbox", "ack", "I acknowledge that I am the person making this request*")])
        let plan = FormFiller.plan(for: f, signals: nil, person: pat)
        guard case .needsYou(let why) = plan.verdict else { return XCTFail("expected needsYou, got \(plan.verdict)") }
        XCTAssertTrue(why.contains("confirm or certify"))
    }

    func testFlowsThatNeedAPersonAreLeftToThem() {
        let f = form([("email", "email", "Email")])
        for tag in ["login_required", "id_required", "phone_verify", "file_upload", "account_hint"] {
            guard case .needsYou = FormFiller.plan(for: f, signals: [tag], person: pat).verdict else { return XCTFail("\(tag) must stop automation") }
        }
        let agent = form([("text", "agentfirstname", "Agent First Name*"), ("email", "email", "Email")])
        guard case .needsYou = FormFiller.plan(for: agent, signals: nil, person: pat).verdict else { return XCTFail("agent forms are on-behalf flows") }
    }

    func testABotCheckSignalDoesNotBlockPlanningBecauseItIsDecidedWhenThePageLoads() {
        let plan = FormFiller.plan(for: form([("email", "email", "Email")]), signals: ["captcha_turnstile", "email_input"], person: pat)
        XCTAssertEqual(plan.verdict, .ready)
    }

    // MARK: the engine's rules

    private struct Recording: FormSubmitter {
        var outcome: SubmitOutcome
        let log = SendBox()
        func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome {
            log.calls.append((form.page.absoluteString, dryRun)); return dryRun ? .filledNotSubmitted : outcome
        }
    }
    private final class SendBox: @unchecked Sendable { var calls: [(String, Bool)] = [] }

    func testSubmitsEligibleSitesAndSkipsSitesWithoutAForm() async {
        let ok = entry("ok", form: form([("email", "email", "Email")]))
        let none = entry("none", form: nil)
        let sub = Recording(outcome: .submitted(awaitingEmail: true))
        let results = await AutoOptOut(submitter: sub, spacing: 0).run(entries: [ok, none], person: pat, progress: OptOutKitCore.Progress(), now: t0)
        XCTAssertEqual(results.count, 1, "a site with no form is not part of the run")
        XCTAssertEqual(results[0].1, .submitted(awaitingEmail: true))
    }

    func testNothingIsSentToASiteARecentLookSaysDoesNotHoldYou() async {
        let e = entry("clean", form: form([("email", "email", "Email")]))
        var p = OptOutKitCore.Progress()
        p.recordSiteCheck(.removed, site: "clean", source: .automatic, on: t0 - 3 * day)
        let sub = Recording(outcome: .submitted(awaitingEmail: false))
        let results = await AutoOptOut(submitter: sub, spacing: 0).run(entries: [e], person: pat, progress: p, now: t0)
        XCTAssertEqual(results[0].1, .skippedNotListed)
        XCTAssertTrue(sub.log.calls.isEmpty, "no details were sent")
        // An old look no longer counts: the person may have been re-listed.
        p = OptOutKitCore.Progress(); p.recordSiteCheck(.removed, site: "clean", source: .automatic, on: t0 - 40 * day)
        let again = await AutoOptOut(submitter: sub, spacing: 0).run(entries: [e], person: pat, progress: p, now: t0)
        XCTAssertEqual(again[0].1, .submitted(awaitingEmail: false))
    }

    func testEachSiteIsSentAtMostOncePerWeek() async {
        let e = entry("x", form: form([("email", "email", "Email")]))
        var p = OptOutKitCore.Progress()
        p.recordOptOutAttempt(OptOutAttempt(date: t0 - 2 * day, outcome: "submitted"), site: "x")
        let sub = Recording(outcome: .submitted(awaitingEmail: false))
        let soon = await AutoOptOut(submitter: sub, spacing: 0).run(entries: [e], person: pat, progress: p, now: t0)
        guard case .tooSoon = soon[0].1 else { return XCTFail("expected tooSoon, got \(soon[0].1)") }
        let later = await AutoOptOut(submitter: sub, spacing: 0).run(entries: [e], person: pat, progress: p, now: t0 + 6 * day)
        XCTAssertEqual(later[0].1, .submitted(awaitingEmail: false), "a week after the last send it goes again")
        // a failed or challenged attempt does not count as sent
        var q = OptOutKitCore.Progress(); q.recordOptOutAttempt(OptOutAttempt(date: t0 - day, outcome: "challenged"), site: "x")
        let retry = await AutoOptOut(submitter: sub, spacing: 0).run(entries: [e], person: pat, progress: q, now: t0)
        XCTAssertEqual(retry[0].1, .submitted(awaitingEmail: false))
    }

    func testDryRunFillsButNeverSends() async {
        let e = entry("x", form: form([("email", "email", "Email")]))
        let sub = Recording(outcome: .submitted(awaitingEmail: false))
        let results = await AutoOptOut(submitter: sub, spacing: 0).run(entries: [e], person: pat, progress: OptOutKitCore.Progress(), now: t0, dryRun: true)
        XCTAssertEqual(results[0].1, .dryRunReady)
        XCTAssertEqual(sub.log.calls.count, 1)
        XCTAssertTrue(sub.log.calls[0].1, "the submitter was told it is a dry run")
        XCTAssertNil(AutoOptOut.attempt(for: .dryRunReady, now: t0), "a dry run is never recorded as sent")
    }

    func testOnlyAttemptsThatReachedTheSiteAreRemembered() {
        XCTAssertEqual(AutoOptOut.attempt(for: .submitted(awaitingEmail: true), now: t0)?.outcome, "submitted_email")
        XCTAssertEqual(AutoOptOut.attempt(for: .challenged("bot check"), now: t0)?.outcome, "challenged")
        XCTAssertNil(AutoOptOut.attempt(for: .needsYou("login"), now: t0))
        XCTAssertNil(AutoOptOut.attempt(for: .skippedNotListed, now: t0))
        XCTAssertNil(AutoOptOut.attempt(for: .needsData(["email"]), now: t0))
    }

    func testMinorsAndPublicFiguresCanStillBeOptedOutBecauseThatIsNotASearch() async {
        let kid = Person(displayName: "K", names: [NameEntry(kind: .legal, name: "Kim Example")], emails: ["k@example.com"], isMinor: true)
        let e = entry("x", form: form([("email", "email", "Email")]))
        let sub = Recording(outcome: .submitted(awaitingEmail: false))
        let results = await AutoOptOut(submitter: sub, spacing: 0).run(entries: [e], person: kid, progress: OptOutKitCore.Progress(), now: t0)
        XCTAssertEqual(results[0].1, .submitted(awaitingEmail: false))
    }

    // MARK: schedule

    func testScanIsDailyAndOptOutIsWeeklyAndBothStartOffUntilThePersonDecides() {
        var a = AutoSettings()
        XCTAssertFalse(a.hasDecided)
        XCTAssertFalse(a.scanDue(now: t0)); XCTAssertFalse(a.optOutDue(now: t0), "nothing runs before the person says yes")
        a.turnOnBoth(now: t0)
        XCTAssertTrue(a.hasDecided)
        XCTAssertTrue(a.scanDue(now: t0)); XCTAssertTrue(a.optOutDue(now: t0), "first run is due straight away")
        a.lastScan = t0; a.lastOptOut = t0
        XCTAssertFalse(a.scanDue(now: t0 + 23 * 3600)); XCTAssertTrue(a.scanDue(now: t0 + day))
        XCTAssertFalse(a.optOutDue(now: t0 + 6 * day)); XCTAssertTrue(a.optOutDue(now: t0 + 7 * day))
        a.optOutEnabled = false
        XCTAssertFalse(a.optOutDue(now: t0 + 30 * day), "switching it off stops it")
    }

    func testDecliningTurnsEverythingOffButRemembersTheAnswer() {
        var a = AutoSettings(); a.turnOnBoth(now: t0); a.declineForNow(now: t0)
        XCTAssertTrue(a.hasDecided); XCTAssertFalse(a.scanEnabled); XCTAssertFalse(a.optOutEnabled)
    }

    func testSettingsAndAttemptsSurviveEncodingAndOldDataStillLoads() throws {
        var h = Household()
        let p = Person(displayName: "P"); h.add(p)
        h.updateAuto { $0.turnOnBoth(now: self.t0) }
        h.mutateProgress(for: p.id) { $0.recordOptOutAttempt(OptOutAttempt(date: self.t0, outcome: "submitted"), site: "x") }
        let back = try JSONDecoder().decode(Household.self, from: JSONEncoder().encode(h))
        XCTAssertTrue(back.autoSettings.optOutEnabled)
        XCTAssertEqual(back.progress(for: p.id).optOutAttempts["x"]?.count, 1)
        let old = try JSONDecoder().decode(Household.self, from: Data(#"{"people":[],"progress":[]}"#.utf8))
        XCTAssertFalse(old.autoSettings.hasDecided)
    }
}

/// How much of the real directory the form filler can handle for a complete profile. Prints the breakdown.
final class DirectoryEligibilityTests: XCTestCase {
    func testHowManyRealFormsAreReadyToFillForACompleteProfile() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("directory")
        let entries = try Registry.loadDirectory(dir).filter { $0.optOutForm != nil }
        let person = Person(displayName: "Pat", names: [NameEntry(kind: .legal, name: "Pat Example")], addresses: [Address(street: "1 Main St", city: "Springfield", state: "IL")],
                            emails: ["pat@example.com"], phones: ["555-0100"], birthdate: "1980-01-01")
        var ready = 0, needsData = 0, why: [String: Int] = [:], readyWithCaptcha = 0
        var readyList: [String] = []
        for e in entries {
            let plan = FormFiller.plan(for: e.optOutForm!, signals: e.signals, person: person)
            switch plan.verdict {
            case .ready:
                ready += 1; readyList.append(e.domain)
                if (e.signals ?? []).contains(where: { $0.hasPrefix("captcha_") }) { readyWithCaptcha += 1 }
            case .needsData: needsData += 1
            case .needsYou(let r):
                let key = r.contains("confirm or certify") ? "attestation checkbox" : r.contains("login") || r.contains("account") ? "login/account" : r.contains("could not match") ? "no matching fields (search form)" : r.contains("do not have") ? "asks for something we lack" : "other"
                why[key, default: 0] += 1
            }
        }
        print("ELIGIBILITY forms=\(entries.count) ready=\(ready) (with a bot-check widget on the page: \(readyWithCaptcha)) needsData=\(needsData) needsYou=\(why)")
        print("ELIGIBILITY readyDomains=\(readyList.prefix(60).joined(separator: ","))")
        XCTAssertGreaterThan(entries.count, 100)
    }
}


final class FormFillerRealWorldTests: XCTestCase {
    private let pat = Person(displayName: "Pat", names: [NameEntry(kind: .legal, name: "Pat Example")],
                            addresses: [Address(city: "Springfield", state: "IL")], emails: ["pat@example.com"])
    private func form(_ f: [(String, String, String)]) -> OptOutForm {
        OptOutForm(page: URL(string: "https://x.example/optout")!, method: "post", action: nil, fields: f.map { FormField(type: $0.0, name: $0.1, label: $0.2) }, hops: 1)
    }

    func testAMiddleNameFieldIsLeftEmptyNotFilledWithTheFullName() {
        let plan = FormFiller.plan(for: form([("text", "subject_fn", "First Name"), ("text", "subject_mn", "Middle Name"),
                                              ("text", "subject_ln", "Last Name"), ("text", "subject_email", "Subject Email Address")]), signals: nil, person: pat)
        XCTAssertEqual(plan.verdict, .ready)
        XCTAssertNil(plan.values.first { $0.name == "subject_mn" }, "the middle name field must stay empty")
        XCTAssertEqual(plan.values.first { $0.name == "subject_fn" }?.candidates, ["Pat"])
        XCTAssertEqual(plan.values.first { $0.name == "subject_ln" }?.candidates, ["Example"])
    }

    func testAFormThatNeedsTheLinkToYourListingIsLeftToYou() {
        let plan = FormFiller.plan(for: form([("url", "url", "Enter URL here"), ("email", "email", "Enter email address here")]), signals: nil, person: pat)
        guard case .needsYou(let why) = plan.verdict else { return XCTFail("expected needsYou, got \(plan.verdict)") }
        XCTAssertTrue(why.contains("link to your listing"))
    }
}

final class GuidedFlowTests: XCTestCase {
    private let u1 = URL(string: "https://x.example/start")!, u2 = URL(string: "https://x.example/confirm")!
    private func plan(_ steps: [GuidedStep], email: Bool = false) -> GuidedPlan {
        GuidedPlan(siteID: "x", siteName: "x.example", steps: steps, addsEmailStepAfterSend: email)
    }

    func testShowsStepNOfMAndAdvancesWhenTheFlowSeesTheStepDone() {
        var f = GuidedFlow(plan: plan([
            GuidedStep(id: 0, title: "Open", action: .openPage(u1), rule: .pageLoaded),
            GuidedStep(id: 1, title: "Submit the form", action: .instruction, rule: .urlContains("confirm")),
            GuidedStep(id: 2, title: "Done", action: .confirm),
        ]))
        XCTAssertEqual(f.progressLabel, "Step 1 of 3")
        XCTAssertEqual(f.apply(.pageLoaded(u1)), 0)
        XCTAssertEqual(f.progressLabel, "Step 2 of 3")
        XCTAssertNil(f.apply(.url(u1)), "the address has not reached the confirmation page yet")
        XCTAssertEqual(f.apply(.url(u2)), 1, "navigating to the confirmation page finished the step by itself")
        XCTAssertTrue(f.autoCompleted.contains(1))
        XCTAssertEqual(f.progressLabel, "Step 3 of 3")
    }

    func testAStepWithNoRuleOnlyMovesOnWhenTheNextButtonIsTapped() {
        var f = GuidedFlow(plan: plan([GuidedStep(id: 0, title: "Do a thing", action: .instruction), GuidedStep(id: 1, title: "Then this", action: .instruction)]))
        XCTAssertFalse(f.current!.isAutomatic)
        XCTAssertNil(f.apply(.url(u2)), "page changes mean nothing for a manual step")
        XCTAssertNil(f.apply(.text("anything")))
        XCTAssertEqual(f.apply(.nextTapped), 0)
        XCTAssertFalse(f.autoCompleted.contains(0), "it was finished by the person, not detected")
        XCTAssertEqual(f.current?.id, 1)
    }

    func testNextAlwaysWorksEvenOnAnAutomaticStepSoThePersonIsNeverStuck() {
        var f = GuidedFlow(plan: plan([GuidedStep(id: 0, title: "Open", action: .openPage(u1), rule: .pageLoaded), GuidedStep(id: 1, title: "Next", action: .confirm)]))
        XCTAssertEqual(f.apply(.nextTapped), 0)
        XCTAssertEqual(f.current?.id, 1)
    }

    func testAnyNavigationRuleFiresOnlyOnAChangeFromWhereTheStepStarted() {
        var f = GuidedFlow(plan: plan([GuidedStep(id: 0, title: "Open", action: .openPage(u1), rule: .pageLoaded),
                                       GuidedStep(id: 1, title: "Enter your email and continue", action: .instruction, rule: .urlChanged),
                                       GuidedStep(id: 2, title: "End", action: .confirm)]))
        f.apply(.pageLoaded(u1))
        XCTAssertNil(f.apply(.url(u1)), "same address: not done")
        XCTAssertEqual(f.apply(.url(u2)), 1)
    }

    func testTextRuleMatchesWithoutCaringAboutCase() {
        var f = GuidedFlow(plan: plan([GuidedStep(id: 0, title: "Submit", action: .instruction, rule: .textContains("check your email")), GuidedStep(id: 1, title: "End", action: .confirm)]))
        XCTAssertNil(f.apply(.text("Please wait")))
        XCTAssertEqual(f.apply(.text("Thanks! CHECK YOUR EMAIL for a link.")), 0)
    }

    func testBackReopensTheLastStep() {
        var f = GuidedFlow(plan: plan([GuidedStep(id: 0, title: "A", action: .instruction), GuidedStep(id: 1, title: "B", action: .instruction)]))
        f.apply(.nextTapped); XCTAssertEqual(f.progressLabel, "Step 2 of 2")
        f.apply(.backTapped)
        XCTAssertEqual(f.progressLabel, "Step 1 of 2")
        XCTAssertFalse(f.completed.contains(0))
        f.apply(.backTapped); XCTAssertEqual(f.index, 0, "cannot go back past the start")
    }

    func testTheFlowFinishesAndStopsReportingProgress() {
        var f = GuidedFlow(plan: plan([GuidedStep(id: 0, title: "Only", action: .instruction)]))
        f.apply(.nextTapped)
        XCTAssertTrue(f.isFinished); XCTAssertNil(f.progressLabel); XCTAssertNil(f.current)
        XCTAssertNil(f.apply(.nextTapped))
    }

    func testAConfirmationEmailStepIsAddedOnlyWhenSendingSaysOneIsNeeded() {
        let steps = [GuidedStep(id: 0, title: "We send it", action: .send, rule: .formSent)]
        var withEmail = GuidedFlow(plan: plan(steps, email: true))
        XCTAssertEqual(withEmail.total, 1)
        withEmail.apply(.formSent(awaitingEmail: true))
        XCTAssertEqual(withEmail.total, 2, "the total grows to include the email step")
        XCTAssertEqual(withEmail.progressLabel, "Step 2 of 2")
        var without = GuidedFlow(plan: plan(steps, email: true))
        without.apply(.formSent(awaitingEmail: false))
        XCTAssertEqual(without.total, 1)
        XCTAssertTrue(without.isFinished)
    }

    func testABrokerFlowBecomesAGuideWithCopyStepsAndAutoRulesFromDoneWhen() {
        let b = Broker(id: "pc", name: "PeopleConnect", tier: .C, covers: nil, signals: nil, fields: nil, steps: [
            Step(open: URL(string: "https://suppression.example/login")!),
            Step(copy: "email"),
            Step(say: "Enter your email and tap Continue.", doneWhen: .init(urlContains: "verify")),
            Step(waitForEmail: .init(subject: "Confirm your email address", withinMinutes: 15)),
            Step(say: "Check the birthdate.", confirm: true),
        ], recheckDays: 30, verified: nil)
        let p = GuidedPlanner.plan(for: b)
        XCTAssertEqual(p.steps.count, 5)
        XCTAssertEqual(p.steps[0].rule, .pageLoaded)
        XCTAssertEqual(p.steps[1].action, .copy(field: "email")); XCTAssertEqual(p.steps[1].rule, .copied)
        XCTAssertEqual(p.steps[2].rule, .urlContains("verify"), "the contributor's done_when becomes an automatic rule")
        XCTAssertNil(p.steps[3].rule, "we cannot read the inbox, so the person says when the link is clicked")
        XCTAssertTrue(p.steps[3].detail!.contains("15 minutes") && p.steps[3].detail!.contains("Confirm your email address"))
        XCTAssertEqual(p.steps[4].action, .confirm)
    }

    func testADirectorySiteWithAFormGetsFillClearSendSteps() {
        let form = OptOutForm(page: URL(string: "https://x.example/optout")!, method: "post", action: nil, fields: [FormField(type: "email", name: "e", label: "Email")], hops: 1)
        let e = DirectoryEntry(id: "x", domain: "x.example", name: "x.example", bucket: "direct", tier: .B, automation: .guided, optOutForm: form)
        let p = GuidedPlanner.plan(for: e)
        XCTAssertEqual(p.steps.map(\.action), [.openPage(form.page), .autofill, .clearBlockers, .send])
        XCTAssertTrue(p.addsEmailStepAfterSend)
        let plain = DirectoryEntry(id: "y", domain: "y.example", name: "y.example", bucket: "direct", tier: .C, automation: .guided)
        XCTAssertEqual(GuidedPlanner.plan(for: plain).steps.count, 4, "no form found: manual steps, with a stated total")
    }

    func testReportedProblemsHideASiteForAWhileThenReturn() {
        var p = OptOutKitCore.Progress()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        p.reportIssue(.brokenLink, site: "x", on: t0)
        XCTAssertEqual(p.activeIssue(for: "x", now: t0 + 5 * 86_400)?.kind, .brokenLink)
        XCTAssertNil(p.activeIssue(for: "x", now: t0 + 31 * 86_400), "a month later it is worth trying again")
        XCTAssertNil(p.activeIssue(for: "other", now: t0))
        let form = OptOutForm(page: URL(string: "https://x.example/optout")!, method: "post", action: nil, fields: [FormField(type: "email", name: "e", label: "Email")], hops: 1)
        let e = DirectoryEntry(id: "x", domain: "x.example", name: "x.example", bucket: "direct", tier: .B, automation: .guided, optOutForm: form)
        let person = Person(displayName: "P", names: [NameEntry(kind: .legal, name: "Pat Example")], emails: ["pat@example.com"])
        let pre = AutoOptOut.precheck(entry: e, person: person, progress: p, now: t0 + day(5))
        guard case .needsYou(let why)? = pre.result else { return XCTFail("a reported site must not be sent to") }
        XCTAssertTrue(why.contains("not working"))
        XCTAssertNil(AutoOptOut.precheck(entry: e, person: person, progress: p, now: t0 + day(31)).result)
    }

    private func day(_ n: Double) -> TimeInterval { n * 86_400 }

    func testBrokerYAMLCanDeclareHowAStepIsDone() throws {
        let b = try Registry.decode(yaml: """
        id: t
        name: T
        tier: C
        steps:
          - say: Enter your email and continue.
            done_when: { url_contains: verify }
        recheck_days: 30
        """)
        XCTAssertEqual(b.steps[0].doneWhen?.urlContains, "verify")
    }
}

final class LinkFinderTests: XCTestCase {
    private func u(_ s: String) -> URL { URL(string: s)! }
    private func link(_ href: String, _ text: String) -> LinkSnapshot { LinkSnapshot(href: u(href), text: text) }
    private func f(_ type: String, _ name: String, _ label: String = "") -> FormField { FormField(type: type, name: name, label: label) }

    private struct Site: PageInspector {
        var pages: [String: PageSnapshot]
        let log = VisitLog()
        func snapshot(_ url: URL) async -> PageSnapshot? {
            log.urls.append(url.absoluteString)
            return pages[url.absoluteString] ?? PageSnapshot(url: url, status: 404, title: "Page not found", text: "Sorry, nothing here.")
        }
    }
    private final class VisitLog: @unchecked Sendable { var urls: [String] = [] }

    private let portalForm = FormSnapshot(action: URL(string: "https://x.example/request-portal/")!, method: "post",
                                          fields: [FormField(type: "text", name: "first", label: "First"), FormField(type: "email", name: "email", label: "Email")], hasSubmit: true)

    // MARK: judging pages

    func testErrorPagesAreRecognisedByStatusAndByWording() {
        XCTAssertTrue(LinkRules.isErrorPage(PageSnapshot(url: u("https://x.example/a"), status: 404)))
        XCTAssertTrue(LinkRules.isErrorPage(PageSnapshot(url: u("https://x.example/a"), status: 200, title: "Oops! That page can't be found.")))
        XCTAssertTrue(LinkRules.isErrorPage(PageSnapshot(url: u("https://x.example/a"), status: 200, text: "Error 404. Sorry, the page you are looking for doesn't exist.")))
        XCTAssertFalse(LinkRules.isErrorPage(PageSnapshot(url: u("https://x.example/a"), status: 200, title: "Request Portal", text: "Welcome to the privacy request portal.")))
    }

    func testAnOptOutLinkOutranksAPrivacyLink() {
        XCTAssertGreaterThan(LinkRules.score(href: "/optout", text: "Opt out of sale"), LinkRules.score(href: "/privacy", text: "Privacy"))
        XCTAssertEqual(LinkRules.score(href: "/blog", text: "News"), 0)
        XCTAssertGreaterThanOrEqual(LinkRules.score(href: "/do-not-sell", text: "Do Not Sell My Info"), 8)
    }

    func testARealPortalFormIsAcceptedOnAnOptOutPage() {
        let page = PageSnapshot(url: u("https://x.example/request-portal/"), title: "Request Portal", text: "Welcome to the Privacy Request Portal. Right to Opt Out and Right to Delete.", forms: [portalForm])
        XCTAssertGreaterThanOrEqual(LinkRules.bestForm(on: page)?.score ?? 0, 3)
    }

    func testASearchBoxOnAnErrorStylePageIsNotAnOptOutForm() {
        let search = FormSnapshot(action: u("https://x.example/search"), method: "get", fields: [f("email", "emailaddress", "Enter an Email Address")], hasSubmit: true)
        let page = PageSnapshot(url: u("https://x.example/optout"), status: 200, title: "Oops! That page can't be found.", text: "It looks like nothing was found. Maybe try searching?", forms: [search])
        XCTAssertNil(LinkRules.bestForm(on: page), "a soft-404 shows a search box, which is not an opt-out form")
    }

    func testAnAffiliateBoxOnAPrivacyPolicyIsRejected() {
        let affiliate = FormSnapshot(action: u("https://htrk1.beenverified.com/aff_c"), method: "get", fields: [f("text", "emailaddress", "Enter an Email Address")], hasSubmit: true)
        let page = PageSnapshot(url: u("https://x.example/privacy-policy/"), title: "Privacy Policy", text: "Privacy policy. You can opt out of marketing emails at any time.", forms: [affiliate])
        XCTAssertNil(LinkRules.bestForm(on: page), "a form that posts to another company is not this site's opt-out form")
    }

    func testAFormThatPostsToARemovalPortalOnAnotherDomainIsAccepted() {
        let removal = FormSnapshot(action: u("https://members.vendor.example/removeMyData/"), method: "post",
                                   fields: [f("text", "fname", "First Name"), f("text", "lname", "Last Name"), f("select", "state", "State"), f("text", "city", "City")], hasSubmit: true)
        let page = PageSnapshot(url: u("https://x.example/do-not-sell-share-my-personal-information/"), title: "Do Not Sell Or Share My Personal Information", text: "Do not sell my information.", forms: [removal])
        XCTAssertNotNil(LinkRules.bestForm(on: page))
    }

    func testTheHomePageNeverCountsEvenWithAnEmailBox() {
        let page = PageSnapshot(url: u("https://x.example/"), title: "Opt out of everything", text: "Opt out", forms: [portalForm])
        XCTAssertNil(LinkRules.bestForm(on: page))
    }

    // MARK: healing a moved link by crawling

    func testHealsABrokenLinkByFollowingHomeToPrivacyToThePortal() async {
        let site = Site(pages: [
            "https://x.example/": PageSnapshot(url: u("https://x.example/"), title: "X", text: "Welcome", links: [link("https://x.example/privacy-rights", "Your Privacy Rights"), link("https://x.example/blog", "Blog")]),
            "https://x.example/privacy-rights": PageSnapshot(url: u("https://x.example/privacy-rights"), title: "Privacy Rights", text: "Your privacy rights. Right to opt out.", links: [link("https://x.example/request-portal/", "Privacy Request Portal")]),
            "https://x.example/request-portal/": PageSnapshot(url: u("https://x.example/request-portal/"), title: "Request Portal", text: "Privacy Request Portal. Right to opt out and delete.", forms: [portalForm]),
        ])
        let result = await OptOutLinkFinder(inspector: site).find(from: u("https://x.example/"))
        XCTAssertEqual(result.form?.page.absoluteString, "https://x.example/request-portal/")
        XCTAssertEqual(result.form?.fields.map(\.name), ["first", "email"])
        XCTAssertNil(result.reason)
        XCTAssertEqual(result.form?.hops, 2, "home, then privacy rights, then the portal")
        XCTAssertLessThanOrEqual(result.visited.count, 3, "it followed the real links, not blind guesses")
    }

    func testFollowsTheBestLinkFirstAndSkipsUselessOnes() async {
        let site = Site(pages: [
            "https://x.example/": PageSnapshot(url: u("https://x.example/"), title: "X", text: "Hi", links: [link("https://x.example/blog", "Blog"), link("https://x.example/optout-center", "Opt out center")]),
            "https://x.example/optout-center": PageSnapshot(url: u("https://x.example/optout-center"), title: "Opt out center", text: "Opt out here.", forms: [portalForm]),
        ])
        let result = await OptOutLinkFinder(inspector: site).find(from: u("https://x.example/"))
        XCTAssertNotNil(result.form)
        XCTAssertFalse(site.log.urls.contains("https://x.example/blog"), "the blog link scored zero and was never visited")
    }

    func testStopsAtThePageLimitAndSaysWhyNothingWasFound() async {
        let site = Site(pages: ["https://x.example/": PageSnapshot(url: u("https://x.example/"), title: "X", text: "Hi")])
        let result = await OptOutLinkFinder(inspector: site, maxPages: 3).find(from: u("https://x.example/"))
        XCTAssertNil(result.form)
        XCTAssertLessThanOrEqual(result.visited.count, 3)
        XCTAssertNotNil(result.reason)
    }

    func testDoesNotWanderOffToUnrelatedSitesOrSocialLinks() async {
        let site = Site(pages: ["https://x.example/": PageSnapshot(url: u("https://x.example/"), title: "X", text: "Hi", links: [
            link("https://www.linkedin.com/legal/privacy-policy", "Privacy"), link("https://other.example/privacy", "Privacy policy"),
        ])])
        _ = await OptOutLinkFinder(inspector: site, maxPages: 12).find(from: u("https://x.example/"))
        XCTAssertFalse(site.log.urls.contains { $0.contains("linkedin") })
        XCTAssertFalse(site.log.urls.contains { $0.contains("other.example") }, "a weak link to another company is not followed")
    }

    func testAStrongOptOutLinkToAnotherDomainIsFollowedForSharedPortals() async {
        let site = Site(pages: [
            "https://x.example/": PageSnapshot(url: u("https://x.example/"), title: "X", text: "Hi", links: [link("https://parent.example/do-not-sell-my-info", "Do Not Sell My Info")]),
            "https://parent.example/do-not-sell-my-info": PageSnapshot(url: u("https://parent.example/do-not-sell-my-info"), title: "Do Not Sell", text: "Do not sell my information.",
                forms: [FormSnapshot(action: u("https://parent.example/optout/submit"), method: "post", fields: [f("email", "email", "Email")], hasSubmit: true)]),
        ])
        let result = await OptOutLinkFinder(inspector: site).find(from: u("https://x.example/"))
        XCTAssertEqual(result.form?.page.host, "parent.example")
    }

    func testHealedLinksAreStoredOnTheDeviceAndSurviveEncoding() throws {
        var h = Household()
        let form = OptOutForm(page: u("https://x.example/request-portal/"), method: "post", action: nil, fields: [f("email", "email")], hops: 2)
        h.saveHealedLink(HealedLink(siteID: "x", form: form))
        let back = try JSONDecoder().decode(Household.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(back.healedLink(for: "x")?.form.page.absoluteString, "https://x.example/request-portal/")
        var h2 = back; h2.forgetHealedLink("x")
        XCTAssertNil(h2.healedLink(for: "x"))
    }
}


final class OptOutMethodTests: XCTestCase {
    private func entry(signals: [String], form: Bool = true, url: Bool = true, automation: Automation = .guided, fields: [FormField]? = nil) -> DirectoryEntry {
        let page = URL(string: "https://x.example/optout")!
        let f = OptOutForm(page: page, method: "post", action: nil,
                           fields: fields ?? [FormField(type: "text", name: "first", label: "First name"), FormField(type: "text", name: "last", label: "Last name"), FormField(type: "email", name: "email", label: "Email")], hops: 1)
        return DirectoryEntry(id: "x", domain: "x.example", name: "x.example", bucket: "direct", tier: .B, automation: automation,
                              optOutURL: url ? page : nil, optOutForm: form ? f : nil, signals: signals)
    }

    func testOnlyAFormLoadedOnARealPageWithNothingBlockingItIsAutomatic() {
        var measured = entry(signals: ["email_input"])
        measured.liveCheck = LiveCheck(checked: "2026-10-22", blockers: [])
        XCTAssertEqual(OptOutMethods.classify(measured).method, .semiAutomatic, "clean at load is not proof: only a confirmed real run makes a site automatic")
        measured.runCheck = RunCheck(date: "2026-10-23", result: "confirmed")
        XCTAssertEqual(OptOutMethods.classify(measured).method, .automatic)
        measured.runCheck = nil
        XCTAssertEqual(OptOutMethods.classify(entry(signals: ["email_input"])).method, .semiAutomatic,
                       "never loaded: a check might appear, and anything a person might have to solve is not fully automated")
        measured.liveCheck = LiveCheck(checked: "2026-10-22", blockers: ["check:recaptcha"])
        XCTAssertEqual(OptOutMethods.classify(measured).method, .semiAutomatic)
    }

    func testAPlainFormIsAutomaticAndABotCheckMakesItSemiAutomated() {
        XCTAssertEqual(OptOutMethods.classify(entry(signals: ["captcha_recaptcha"])).method, .semiAutomatic)
        XCTAssertEqual(OptOutMethods.classify(entry(signals: ["captcha_turnstile"])).method, .semiAutomatic)
    }

    func testThingsOnlyAPersonCanDoMakeItGuided() {
        XCTAssertEqual(OptOutMethods.classify(entry(signals: ["login_required"])).method, .guided)
        XCTAssertEqual(OptOutMethods.classify(entry(signals: ["id_required"])).method, .guided)
        let listing = [FormField(type: "text", name: "listing_url", label: "Link to your listing"), FormField(type: "email", name: "email", label: "Email")]
        XCTAssertEqual(OptOutMethods.classify(entry(signals: [], fields: listing)).method, .guided)
    }

    func testAPageWithoutAFormIsGuidedAndNothingFoundIsManual() {
        XCTAssertEqual(OptOutMethods.classify(entry(signals: [], form: false)).method, .guided)
        for a in [Automation.blocked, .needsBrowser, .unreachable, .unknown, .robotsDisallowed] {
            let v = OptOutMethods.classify(entry(signals: [], form: false, url: false, automation: a))
            XCTAssertEqual(v.method, .manual, "\(a)")
            XCTAssertFalse(v.reason.isEmpty)
        }
    }

    func testEveryDirectorySiteGetsAMethodAndAReason() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("directory")
        let entries = try Registry.loadDirectory(dir)
        var counts: [OptOutMethod: Int] = [:]
        for e in entries {
            let v = OptOutMethods.classify(e)
            XCTAssertFalse(v.reason.isEmpty, e.domain)
            counts[v.method, default: 0] += 1
        }
        print("METHODS \(OptOutMethod.allCases.map { "\($0.rawValue)=\(counts[$0] ?? 0)" }.joined(separator: " "))")
        XCTAssertEqual(counts.values.reduce(0, +), entries.count)
        XCTAssertGreaterThan(entries.count, 200)
    }
}

final class SelfIdentityConfirmationTests: XCTestCase {
    private let box = "I confirm that I am the person associated with this email address and consent to receive an email from Example. The information I provided is accurate."
    private func form(_ label: String) -> OptOutForm {
        OptOutForm(page: URL(string: "https://x.example/optout")!, method: "post", action: nil, fields: [
            FormField(type: "email", name: "email", label: "Email *"),
            FormField(type: "checkbox", name: "confirm", label: label + " *"),
        ], hops: 1)
    }
    private func person(_ rel: Relationship, allowed: Bool = true, minor: Bool = false) -> Person {
        Person(displayName: "P", relationship: rel, names: [NameEntry(kind: .legal, name: "Pat Example")], emails: ["pat@example.com"],
               isMinor: minor, confirmsOwnIdentity: allowed)
    }
    private func isSentinel(_ v: FieldValue) -> Bool { v.type == FormFiller.confirmIdentityType }

    func testTheOwnerWhoAllowedItGetsTheBoxTickedAndTheFormIsReady() {
        let plan = FormFiller.plan(for: form(box), signals: nil, person: person(.me))
        XCTAssertEqual(plan.verdict, .ready)
        XCTAssertTrue(plan.values.contains(where: isSentinel))
    }

    func testFamilyProfilesAreNeverConfirmedEvenIfTheFlagIsSet() {
        for rel in Relationship.allCases where rel != .me {
            let plan = FormFiller.plan(for: form(box), signals: nil, person: person(rel))
            guard case .needsYou(let why) = plan.verdict else { return XCTFail("\(rel) should need the person") }
            XCTAssertTrue(why.contains("account owner"))
            XCTAssertFalse(plan.values.contains(where: isSentinel), "\(rel)")
        }
    }

    func testTheOwnerIsConfirmedWhateverAnOldSavedSettingSays() {
        XCTAssertEqual(FormFiller.plan(for: form(box), signals: nil, person: person(.me, allowed: false)).verdict, .ready)
    }

    func testAMinorOwnerProfileIsNeverConfirmed() {
        if case .needsYou = FormFiller.plan(for: form(box), signals: nil, person: person(.me, minor: true)).verdict {} else { XCTFail("minor") }
    }

    func testLegalCertificationsAgentStatementsAndTermsAreNeverTicked() {
        for text in ["I certify under penalty of perjury that I am the person named in this request",
                     "I am the owner of this email and an authorized agent acting on behalf of the person",
                     "I confirm that I am the person associated with this email and agree to the terms of service",
                     "I acknowledge and attest that the information is true"] {
            XCTAssertFalse(FormFiller.isSelfIdentityBox(text), text)
            if case .needsYou = FormFiller.plan(for: form(text), signals: nil, person: person(.me)).verdict {} else { XCTFail(text) }
        }
    }

    func testThePlainSelfStatementsAreRecognised() {
        for text in [box, "I confirm I am the person associated with this email address", "I verify that I am the owner of this account"] {
            XCTAssertTrue(FormFiller.isSelfIdentityBox(text), text)
        }
    }

    func testOldProfilesLoadAndOnlyTheOwnerGetsTheirBoxTicked() throws {
        let old = #"{"id":"\#(UUID().uuidString)","displayName":"Me","relationship":"me"}"#
        let p = try JSONDecoder().decode(Person.self, from: Data(old.utf8))
        XCTAssertTrue(p.mayConfirmOwnIdentity(), "the owner needs no setting: their own box is always ticked")
        XCTAssertFalse(Person(displayName: "Mom", relationship: .parent, confirmsOwnIdentity: true).mayConfirmOwnIdentity())
        XCTAssertTrue(Person(displayName: "Me", relationship: .me).mayConfirmOwnIdentity())
    }

    func testTheSiteIsAutomaticForTheOwnerWhoAllowedItAndGuidedOtherwise() {
        var e = DirectoryEntry(id: "x", domain: "x.example", name: "x", bucket: "direct", tier: .B, automation: .guided,
                               optOutURL: URL(string: "https://x.example/optout"), optOutForm: form(box), signals: [])
        e.liveCheck = LiveCheck(checked: "2026-10-22", blockers: [])
        e.runCheck = RunCheck(date: "2026-10-23", result: "confirmed")
        XCTAssertEqual(OptOutMethods.classify(e, confirmingIdentity: true).method, .automatic)
        XCTAssertEqual(OptOutMethods.classify(e).method, .guided)
    }
}

final class MeasuredMethodTests: XCTestCase {
    private func entry(_ signals: [String], live: LiveCheck?) -> DirectoryEntry {
        let page = URL(string: "https://x.example/optout")!
        let f = OptOutForm(page: page, method: "post", action: nil, fields: [FormField(type: "email", name: "email", label: "Email *")], hops: 1)
        return DirectoryEntry(id: "x", domain: "x.example", name: "x", bucket: "direct", tier: .B, automation: .guided,
                              optOutURL: page, optOutForm: f, liveCheck: live, signals: signals)
    }
    private let selfBox = "certify: I confirm that I am the person associated with this email address and consent to receive an email."

    func testACaptchaScriptAloneDoesNotMakeASiteSemiAutomatedOnceItWasMeasured() {
        var measured = entry(["captcha_recaptcha", "captcha_turnstile"], live: LiveCheck(checked: "2026-10-21", blockers: []))
        measured.runCheck = RunCheck(date: "2026-10-23", result: "confirmed")
        XCTAssertEqual(OptOutMethods.classify(measured).method, .automatic)
        XCTAssertEqual(OptOutMethods.classify(entry(["captcha_recaptcha"], live: nil)).method, .semiAutomatic, "unmeasured stays cautious")
    }

    func testAVisibleCheckOrAHandledBoxMakesItSemiAutomated() {
        XCTAssertEqual(OptOutMethods.classify(entry([], live: LiveCheck(checked: "d", blockers: ["check: a reCAPTCHA checkbox"]))).method, .semiAutomatic)
        XCTAssertEqual(OptOutMethods.classify(entry([], live: LiveCheck(checked: "d", blockers: ["terms"]))).method, .semiAutomatic)
        XCTAssertEqual(OptOutMethods.classify(entry([], live: LiveCheck(checked: "d", blockers: ["certify: I certify under penalty of perjury"])), confirmingIdentity: true).method, .semiAutomatic)
    }

    func testTheSelfStatementBoxIsAutomaticOnlyForAnOwnerWhoAllowedIt() {
        var e = entry([], live: LiveCheck(checked: "d", blockers: [selfBox]))
        e.runCheck = RunCheck(date: "2026-10-23", result: "confirmed")
        XCTAssertEqual(OptOutMethods.classify(e, confirmingIdentity: true).method, .automatic)
        XCTAssertEqual(OptOutMethods.classify(e, confirmingIdentity: false).method, .semiAutomatic, "family profiles and owners who did not allow it")
    }

    func testASendThatFailedOrWasRefusedMovesTheSiteToAGuide() {
        var e = entry([], live: LiveCheck(checked: "d", blockers: []))
        e.runCheck = RunCheck(date: "2026-10-23", result: "confirmed")
        XCTAssertEqual(OptOutMethods.classify(e).method, .automatic)
        XCTAssertEqual(OptOutMethods.classify(e, failedBefore: true).method, .guided)
    }

    func testASendThatWasChallengedMovesTheSiteToSemiAutomated() {
        let e = entry([], live: LiveCheck(checked: "d", blockers: []))
        XCTAssertEqual(OptOutMethods.classify(e, challengedBefore: true).method, .semiAutomatic)
    }

    func testTheMeasuredDirectoryLoadsAndMostMeasuredFormsAreClear() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("directory")
        let entries = try Registry.loadDirectory(dir)
        let measured = entries.compactMap { $0.liveCheck }
        XCTAssertGreaterThan(measured.count, 50)
        XCTAssertGreaterThan(measured.filter { $0.blockers.isEmpty }.count, measured.count / 2)
    }
}


final class SiteOwnerTests: XCTestCase {
    private func entry(_ domain: String) -> DirectoryEntry {
        DirectoryEntry(id: domain.replacingOccurrences(of: ".", with: "_"), domain: domain, name: domain, bucket: "direct", tier: nil, automation: .unknown)
    }

    func testASiteIsOwnedByItsOwnFlowOrTheOneThatClearsIt() {
        let spokeo = Broker(id: "spokeo", name: "Spokeo", tier: .A, covers: ["freepeopledirectory.com"], signals: nil, fields: nil, steps: [Step(say: "x")], recheckDays: 30, verified: nil)
        XCTAssertEqual(Directory.owner(of: entry("spokeo.com"), brokers: [spokeo])?.id, "spokeo")
        XCTAssertEqual(Directory.owner(of: entry("freepeopledirectory.com"), brokers: [spokeo])?.id, "spokeo")
        XCTAssertNil(Directory.owner(of: entry("other.com"), brokers: [spokeo]))
    }

    func testTheShippedSpokeoFlowClearsFreePeopleDirectoryAndNothingIsListedTwice() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let brokers = try Registry.load(directory: root.appendingPathComponent("brokers"))
        let entries = try Registry.loadDirectory(root.appendingPathComponent("directory"))
        XCTAssertFalse(brokers.contains { $0.id == "freepeopledirectory" }, "folded into Spokeo")
        XCTAssertEqual(brokers.first { $0.id == "spokeo" }?.covers, ["freepeopledirectory.com"])
        let listedAsOwn = Directory.unguided(entries, brokers: brokers).map(\.domain)
        XCTAssertFalse(listedAsOwn.contains("spokeo.com")); XCTAssertFalse(listedAsOwn.contains("freepeopledirectory.com"))
    }
}

final class ListingFlowTests: XCTestCase {
    private let search = URL(string: "https://www.spokeo.com/pat-example")!
    private func entry(search: Bool = true) -> DirectoryEntry {
        let form = OptOutForm(page: URL(string: "https://www.spokeo.com/optout")!, method: "get", action: nil,
                              fields: [FormField(type: "url", name: "url", label: "Enter URL here"), FormField(type: "email", name: "email", label: "Enter email address here")], hops: 1)
        let check = search ? SearchCheck(status: .calibrated, searchURL: "https://www.spokeo.com/{first}-{last}", validPage: ["Spokeo"], noResults: nil,
                                         ignoreLocation: nil, calibration: nil, method: nil, body: nil, needsBrowser: nil, candidate: nil, checked: nil) : nil
        return DirectoryEntry(id: "spokeo_com", domain: "spokeo.com", name: "spokeo.com", bucket: "direct", tier: .A, automation: .guided,
                              optOutURL: form.page, optOutForm: form, searchCheck: check, signals: ["captcha_recaptcha", "listing_url_input"])
    }
    private let pat = Person(displayName: "Pat", names: [NameEntry(kind: .legal, name: "Pat Example")], emails: ["pat@example.com"])

    func testAFormThatNeedsYourListingIsLeftToYouUnlessYouPickedOne() {
        let form = entry().optOutForm!
        XCTAssertTrue(FormFiller.needsListing(form))
        if case .needsYou = FormFiller.plan(for: form, signals: nil, person: pat).verdict {} else { XCTFail() }
        let listing = URL(string: "https://www.spokeo.com/Pat-Example/Chicago-IL/p123")!
        let plan = FormFiller.plan(for: form, signals: nil, person: pat, listingURL: listing)
        XCTAssertEqual(plan.verdict, .ready)
        XCTAssertEqual(plan.values.first { $0.name == "url" }?.candidates, [listing.absoluteString])
        XCTAssertEqual(plan.values.first { $0.name == "email" }?.candidates, ["pat@example.com"])
    }

    func testTheSearchAddressIsBuiltFromTheProfileAndNeverForPeopleWhoMayNotBeSearched() {
        XCTAssertEqual(entry().listingSearchURL(for: pat)?.absoluteString, "https://www.spokeo.com/Pat-Example")
        var minor = pat; minor.isMinor = true
        XCTAssertNil(entry().listingSearchURL(for: minor))
        var star = pat; star.isPublicFigure = true
        XCTAssertNil(entry().listingSearchURL(for: star))
        XCTAssertNil(entry(search: false).listingSearchURL(for: pat))
    }

    func testThePlanSearchesPicksFillsClearsAndSends() {
        let plan = GuidedPlanner.listingPlan(for: entry(), search: search)
        XCTAssertEqual(plan.steps.map(\.title), ["Open your own listing", "Open the opt-out page", "We fill in your details", "Clear the check", "We send it"])
        XCTAssertEqual(plan.listingFields, ["url"])
        if case .pickListing = plan.steps[0].action {} else { XCTFail() }
        XCTAssertNil(plan.steps[0].rule, "never guessed: only the person's tap finishes it")
    }

    func testOnlyAnExplicitTapOnAPageThatIsNotTheResultsPicksTheListing() {
        var flow = GuidedFlow(plan: GuidedPlanner.listingPlan(for: entry(), search: search))
        flow.apply(.pageLoaded(search)); flow.apply(.searchLanded(search))
        XCTAssertNil(flow.apply(.nextTapped), "still on the results")
        XCTAssertEqual(flow.index, 0)
        flow.apply(.url(URL(string: "https://www.spokeo.com/Pat-Example")!))
        XCTAssertNil(flow.apply(.nextTapped), "same page as the results, different case")
        flow.apply(.url(URL(string: "https://www.other.com/x")!))
        XCTAssertNil(flow.apply(.nextTapped), "another site")
        let mine = URL(string: "https://www.spokeo.com/Pat-Example/Chicago-IL/p123")!
        flow.apply(.url(mine))
        XCTAssertNil(flow.apply(.text("anything")), "navigating alone never picks it")
        XCTAssertEqual(flow.index, 0)
        XCTAssertEqual(flow.apply(.nextTapped), 0)
        XCTAssertEqual(flow.chosenListing, mine)
        XCTAssertEqual(flow.index, 1)
    }

    func testListingSitesAreSemiAutomatedOnlyWhenTheyCanBeSearched() {
        XCTAssertEqual(OptOutMethods.classify(entry()).method, .semiAutomatic)
        XCTAssertEqual(OptOutMethods.classify(entry(search: false)).method, .guided)
        let spokeo = Broker(id: "spokeo", name: "Spokeo", tier: .A, covers: nil, signals: nil, fields: nil, steps: [Step(say: "x")], recheckDays: 30, verified: nil)
        let other = Broker(id: "peopleconnect", name: "PC", tier: .C, covers: nil, signals: nil, fields: nil, steps: [Step(say: "x")], recheckDays: 30, verified: nil)
        XCTAssertEqual(OptOutMethods.classify(spokeo, in: [entry()]).method, .semiAutomatic)
        XCTAssertEqual(OptOutMethods.classify(other, in: [entry()]).method, .guided)
    }
}

final class RequiredDetailsTests: XCTestCase {
    func testAProfileNeedsALegalFirstAndLastNameAndACurrentAddress() {
        var p = Person(displayName: "Pat", names: [NameEntry(kind: .legal, name: "Pat")])
        XCTAssertEqual(p.missingRequiredDetails, ["legal last name", "current street address", "current city", "current state", "current zip code"])
        XCTAssertFalse(p.isComplete)
        p.names = [NameEntry(kind: .legal, name: "Pat Example")]
        p.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL")]
        XCTAssertEqual(p.missingRequiredDetails, ["current zip code"], "a ZIP code is required too")
        p.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")]
        XCTAssertTrue(p.isComplete); XCTAssertEqual(p.missingRequiredDetails, [])
        p.addresses.append(Address(street: "1 Old Rd", city: "Peoria", state: "IL"))
        XCTAssertEqual(p.missingRequiredDetails, ["zip code for a previous address"], "a previous address that was started needs its ZIP too")
        p.addresses[1].zip = "61602"
        XCTAssertTrue(p.isComplete)
    }

    func testANicknameOrAPreviousAddressDoesNotMakeAProfileComplete() {
        let p = Person(displayName: "Pat", names: [NameEntry(kind: .legal, name: ""), NameEntry(kind: .nickname, name: "Patty Example")],
                       addresses: [Address(city: "", state: ""), Address(street: "1 Old Rd", city: "Springfield", state: "IL", zip: "62701")])
        XCTAssertTrue(p.missingRequiredDetails.contains("legal first name"))
        XCTAssertTrue(p.missingRequiredDetails.contains("current street address"), "only the first address is the current one")
    }

    func testBlankSpacesDoNotCount() {
        let p = Person(displayName: "P", names: [NameEntry(kind: .legal, name: "Pat Example")], addresses: [Address(street: "  ", city: " ", state: "IL", zip: " ")])
        XCTAssertEqual(p.missingRequiredDetails, ["current street address", "current city", "current zip code"])
    }
}


final class ContactEmailTests: XCTestCase {
    func testGmailAddressesGetTheTrackingTagBeforeTheAtSign() {
        XCTAssertEqual(ContactEmail.forForms("pat@gmail.com"), "pat@gmail.com")
        XCTAssertEqual(ContactEmail.forForms("Pat.Example@GMAIL.com"), "Pat.Example@GMAIL.com")
        XCTAssertEqual(ContactEmail.forForms("pat@googlemail.com"), "pat@googlemail.com")
        XCTAssertEqual(ContactEmail.forForms("pat+news@gmail.com"), "pat+news@gmail.com")
        XCTAssertEqual(ContactEmail.forForms("  pat@gmail.com "), "pat@gmail.com")
    }

    func testTheTagIsNeverAddedTwiceOrToOtherProviders() {
        XCTAssertEqual(ContactEmail.forForms("pat+optoutkit@gmail.com"), "pat+optoutkit@gmail.com")
        XCTAssertEqual(ContactEmail.forForms("pat@example.com"), "pat@example.com")
        XCTAssertEqual(ContactEmail.forForms("pat@icloud.com"), "pat@icloud.com")
        XCTAssertEqual(ContactEmail.forForms("pat@notgmail.com"), "pat@notgmail.com")
    }

    func testValidation() {
        for ok in ["pat@example.com", "a.b+c@sub.example.org"] { XCTAssertTrue(ContactEmail.isValid(ok), ok) }
        for bad in ["", "pat", "pat@", "@example.com", "pat@example", "pat @example.com", "a@b@c.com", "pat@.com", "pat@example."] { XCTAssertFalse(ContactEmail.isValid(bad), bad) }
    }

    func testTheHouseholdKeepsOneAddressAndOnlyAValidOneReachesForms() throws {
        var h = Household()
        XCTAssertNil(h.formEmail)
        h.setContactEmail("pat@gmail.com")
        XCTAssertEqual(h.formEmail, "pat@gmail.com", "unaltered: many forms look the person up by that exact address")
        h.setContactEmail("not an email")
        XCTAssertNil(h.formEmail, "an invalid address is never put on a form")
        h.setContactEmail("  ")
        XCTAssertNil(h.contactEmail)
        h.setContactEmail("pat@example.com")
        let again = try JSONDecoder().decode(Household.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(again.contactEmail, "pat@example.com")
    }

    func testTheLegalNameSplitsIntoFirstMiddleAndLast() {
        var p = Person(displayName: "P", names: [NameEntry(kind: .legal, name: "Pat Q. Example")])
        XCTAssertEqual([p.legalFirst, p.legalMiddle, p.legalLast], ["Pat", "Q.", "Example"])
        p.names = [NameEntry(kind: .legal, name: "Pat Example")]
        XCTAssertEqual([p.legalFirst, p.legalMiddle, p.legalLast], ["Pat", "", "Example"])
        p.names = [NameEntry(kind: .legal, name: "Pat")]
        XCTAssertEqual([p.legalFirst, p.legalLast], ["Pat", ""], "a single word is a first name only")
        XCTAssertEqual(Person.composeLegalName(first: " Pat ", middle: "", last: "Example"), "Pat Example")
        XCTAssertEqual(Person.composeLegalName(first: "Pat", middle: "Q", last: "Example"), "Pat Q Example")
    }
}

final class PlatformTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func drop() throws -> Platform {
        try XCTUnwrap(try PlatformLoader.load(directory: root.appendingPathComponent("platforms")).first { $0.id == "ca-drop" })
    }

    func testTheCaliforniaPlatformLoadsWithItsStepsRegistryAndCoverage() throws {
        let p = try drop()
        XCTAssertEqual(p.states, ["CA"]); XCTAssertEqual(p.holdDays, 90); XCTAssertTrue(p.live)
        XCTAssertGreaterThan(p.registered, 500, "the full registry is known")
        XCTAssertGreaterThan(p.coverage.count, 500)
        XCTAssertTrue(p.walkthrough.steps.count >= 5)
        XCTAssertEqual(p.walkthrough.steps.first?.open?.host, "privacy.ca.gov")
    }

    func testOurSitesThatAreRegisteredBrokersAreCoveredAndTheRestAreNot() throws {
        let p = try drop()
        XCTAssertEqual(p.covers(domain: "spokeo.com")?.match, .domain)
        XCTAssertNotNil(p.covers(domain: "www.spokeo.com"), "a subdomain of a registered site counts")
        XCTAssertNotNil(p.covers(domain: "truthfinder.com"))
        XCTAssertNil(p.covers(domain: "not-a-broker.example"))
        let entries = try Registry.loadDirectory(root.appendingPathComponent("directory"))
        let covered = entries.filter { p.covers(domain: $0.domain) != nil }
        print("DROP covers \(covered.count) of \(entries.count) directory sites")
        XCTAssertGreaterThan(covered.count, 500)
    }

    func testOnlyResidentsOfTheStateCanUseIt() throws {
        let p = try drop()
        func person(_ state: String?, _ rel: Relationship = .otherFamily) -> Person {
            Person(displayName: "P", relationship: rel, addresses: state.map { [Address(street: "1 A St", city: "X", state: $0)] } ?? [])
        }
        XCTAssertTrue(p.eligible(person("CA"))); XCTAssertTrue(p.eligible(person("California"))); XCTAssertTrue(p.eligible(person(" ca ")))
        XCTAssertFalse(p.eligible(person("IL"))); XCTAssertFalse(p.eligible(person("Illinois")))
        XCTAssertFalse(p.eligible(person(nil)), "no address and no claim")
        XCTAssertTrue(p.eligible(person(nil, .me), ownerState: "CA"), "the owner chose California")
        XCTAssertFalse(p.eligible(person(nil, .me), ownerState: "IL"))
        XCTAssertFalse(p.eligible(person(nil, .parent), ownerState: "CA"), "the walkthrough choice is the owner's only")
        XCTAssertFalse(p.eligible(person("IL", .me), ownerState: "CA"), "once there is an address, it decides")
    }

    func testAHeldSiteIsLeftAloneUntilTheHoldEnds() throws {
        let now = Date()
        let form = OptOutForm(page: URL(string: "https://x.example/o")!, method: "post", action: nil,
                              fields: [FormField(type: "email", name: "email", label: "Email")], hops: 1)
        let e = DirectoryEntry(id: "x", domain: "x.example", name: "x", bucket: "direct", tier: .A, automation: .guided, optOutForm: form)
        let pat = Person(displayName: "P", names: [NameEntry(kind: .legal, name: "Pat Example")], emails: ["pat@example.com"])
        let p = try drop()
        let until = p.holdUntil(submitted: now)
        XCTAssertEqual(until.timeIntervalSince(now), 90 * 86_400, accuracy: 1)
        let hold = PlatformHold(name: p.name, until: until)
        let held = AutoOptOut.precheck(entry: e, person: pat, progress: Progress(), now: now, hold: hold)
        XCTAssertEqual(held.result, .coveredByPlatform(name: p.name, until: until))
        XCTAssertTrue(held.result?.label.hasPrefix("Covered by") == true)
        XCTAssertNil(AutoOptOut.precheck(entry: e, person: pat, progress: Progress(), now: until.addingTimeInterval(1), hold: hold).result, "after the hold it is asked directly again")
        XCTAssertNil(AutoOptOut.precheck(entry: e, person: pat, progress: Progress(), now: now).result, "no hold, no skip")
    }

    func testTheOwnersStateIsKept() throws {
        var h = Household()
        XCTAssertNil(h.ownerState)
        h.setOwnerState("CA")
        let again = try JSONDecoder().decode(Household.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(again.ownerState, "CA")
    }
}

final class RegistryCompletenessTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private struct Known: Decodable { struct B: Decodable { var domain: String; var names: [String]; var registeredIn: [String]
        enum CodingKeys: String, CodingKey { case domain, names, registeredIn = "registered_in" } }; var count: Int; var brokers: [B] }

    func testEveryBrokerRegisteredInAnyStateWeReadIsOnOurList() throws {
        let file = try JSONDecoder().decode(Known.self, from: Data(contentsOf: root.appendingPathComponent("registries/all-brokers.json")))
        XCTAssertEqual(file.brokers.count, file.count)
        XCTAssertGreaterThan(file.brokers.count, 600)
        let entries = try Registry.loadDirectory(root.appendingPathComponent("directory"))
        let ours = Set(entries.map { LinkRules.registrable($0.domain) })
        let missing = file.brokers.filter { !ours.contains($0.domain) }
        XCTAssertTrue(missing.isEmpty, "known brokers with no entry: \(missing.prefix(10).map(\.domain)) (\(missing.count) in all)")
        print("REGISTRY \(file.brokers.count) known broker sites from \(Set(file.brokers.flatMap(\.registeredIn)).sorted()), all on our list (\(entries.count) directory entries)")
    }

    func testEntriesSayWhichStatesTheyAreRegisteredIn() throws {
        let file = try JSONDecoder().decode(Known.self, from: Data(contentsOf: root.appendingPathComponent("registries/all-brokers.json")))
        let byDomain = Dictionary(uniqueKeysWithValues: file.brokers.map { ($0.domain, $0.registeredIn) })
        let entries = try Registry.loadDirectory(root.appendingPathComponent("directory"))
        let wrong = entries.filter { e in byDomain[LinkRules.registrable(e.domain)].map { Set($0) != Set(e.registeredIn ?? []) } ?? false }
        XCTAssertTrue(wrong.isEmpty, "stale registered_in on \(wrong.prefix(5).map(\.domain)); re-run tools/profile_brokers.py")
    }

    func testTheCoverageFileReachesEveryCaliforniaRegisteredBroker() throws {
        let drop = try XCTUnwrap(PlatformLoader.load(directory: root.appendingPathComponent("platforms")).first)
        let file = try JSONDecoder().decode(Known.self, from: Data(contentsOf: root.appendingPathComponent("registries/all-brokers.json")))
        let unreached = file.brokers.filter { $0.registeredIn.contains("CA") && drop.covers(domain: $0.domain) == nil }
        XCTAssertTrue(unreached.isEmpty, "\(unreached.count) California brokers are not reached: \(unreached.prefix(5).map(\.domain))")
    }
}

final class MultilingualRulesTests: XCTestCase {
    private let pat = Person(displayName: "Pat", names: [NameEntry(kind: .legal, name: "Pat Example")],
                             addresses: [Address(street: "1 Main St", city: "Springfield", state: "IL")], emails: ["pat@example.com"])
    private func form(_ fields: [(String, String, String)]) -> OptOutForm {
        OptOutForm(page: URL(string: "https://x.example/optout")!, method: "post", action: nil,
                   fields: fields.map { FormField(type: $0.0, name: $0.1, label: $0.2) }, hops: 1)
    }
    private func names(_ plan: FillPlan) -> [String: String] { Dictionary(uniqueKeysWithValues: plan.values.map { ($0.name, $0.candidates[0]) }) }

    func testOptOutLinksAreRecognisedInFrenchSpanishAndGerman() {
        for (href, text) in [("/desinscription", "Se désinscrire"), ("/privacidad", "No vender mi información"), ("/datenschutz", "Widerspruch und Löschung"),
                             ("/vos-droits", "Vos droits en matière de données"), ("/baja", "Darse de baja")] {
            XCTAssertGreaterThan(LinkRules.score(href: href, text: text), 0, "\(href) \(text)")
        }
        XCTAssertEqual(LinkRules.score(href: "/a-propos", text: "À propos de nous"), 0)
        XCTAssertGreaterThan(LinkRules.guessPaths.filter { ["/desinscription", "/privacidad", "/datenschutz"].contains($0) }.count, 2)
    }

    func testErrorPagesAreRecognisedInEveryLanguage() {
        for text in ["Page introuvable", "Erreur 404", "Página no encontrada", "No se encontró la página", "Seite nicht gefunden", "Fehler 404"] {
            XCTAssertTrue(LinkRules.isErrorPage(PageSnapshot(url: URL(string: "https://x.example/a")!, status: 200, title: text, text: "")), text)
        }
        XCTAssertFalse(LinkRules.isErrorPage(PageSnapshot(url: URL(string: "https://x.example/a")!, status: 200, title: "Se désinscrire", text: "Formulaire de désinscription")))
    }

    func testAFrenchOptOutFormIsRecognisedAsTheRealForm() {
        let page = PageSnapshot(url: URL(string: "https://x.example/desinscription")!, title: "Se désinscrire", text: "Demande de désinscription. Vos droits sur vos données.",
                                forms: [FormSnapshot(action: nil, method: "post", fields: [FormField(type: "text", name: "p", label: "Prénom"), FormField(type: "text", name: "n", label: "Nom"),
                                                                                           FormField(type: "email", name: "c", label: "Courriel")], hasSubmit: true)])
        XCTAssertNotNil(LinkRules.bestForm(on: page))
    }

    func testFormsInFrenchSpanishAndGermanAreFilledFromTheProfile() {
        let fr = FormFiller.plan(for: form([("text", "p", "Prénom *"), ("text", "n", "Nom *"), ("email", "c", "Courriel *"), ("text", "v", "Ville"), ("text", "e", "État"), ("text", "z", "Code postal")]), signals: nil, person: pat)
        XCTAssertEqual(names(fr), ["p": "Pat", "n": "Example", "c": "pat@example.com", "v": "Springfield", "e": "IL"], "Nom is the family name when there is a Prénom")
        let es = FormFiller.plan(for: form([("text", "a", "Nombre *"), ("text", "b", "Apellido *"), ("email", "c", "Correo electrónico *"), ("text", "d", "Ciudad"), ("text", "e", "Estado")]), signals: nil, person: pat)
        XCTAssertEqual(names(es), ["a": "Pat", "b": "Example", "c": "pat@example.com", "d": "Springfield", "e": "IL"], "Nombre is the first name when there is an Apellido")
        let de = FormFiller.plan(for: form([("text", "a", "Vorname *"), ("text", "b", "Nachname *"), ("email", "c", "E-Mail-Adresse *"), ("text", "d", "Stadt"), ("text", "e", "Bundesland"), ("text", "t", "Telefon")]), signals: nil, person: pat)
        XCTAssertEqual(names(de), ["a": "Pat", "b": "Example", "c": "pat@example.com", "d": "Springfield", "e": "IL"])
        let single = FormFiller.plan(for: form([("text", "n", "Nom complet *"), ("email", "c", "Courriel *")]), signals: nil, person: pat)
        XCTAssertEqual(names(single)["n"], "Pat Example", "a lone Nom is the full name")
    }

    func testWhatIsMissingIsNamedInTheChosenLanguage() {
        let noEmail = Person(displayName: "P", names: [NameEntry(kind: .legal, name: "Pat Example")])
        L10n.language = "fr"; defer { L10n.language = "en" }
        let plan = FormFiller.plan(for: form([("email", "c", "Courriel")]), signals: nil, person: noEmail)
        XCTAssertEqual(plan.verdict, .needsData(["adresse e-mail"]))
    }

    func testTermsParagraphsRememberTheirLanguageAndTheListCountsPerLanguage() {
        let lib = TermsLibrary(version: 1, paragraphs: [
            TermsParagraph(hash: "a", sites: 3, kinds: ["terms"], flags: [], prefix: "x", reviewed: true, verdict: "ok"),
            TermsParagraph(hash: "b", sites: 1, kinds: ["terms"], flags: [], prefix: "y", reviewed: false, verdict: nil, lang: "fr"),
            TermsParagraph(hash: "c", sites: 1, kinds: ["terms"], flags: [], prefix: "z", reviewed: true, verdict: "ok", lang: "fr")])
        XCTAssertEqual(lib.languages["en"]?.total, 1)
        XCTAssertEqual(lib.languages["fr"]?.total, 2); XCTAssertEqual(lib.languages["fr"]?.reviewed, 1)
        XCTAssertEqual(lib.paragraphs[0].language, "en")
    }

    func testTheTermsCanonicalizerAgreesWithPythonOnFrenchSpanishAndGermanText() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        struct Fixture: Decodable { var domain: String; var input: String; var canonical: String; var hash: String }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("terms/canonicalization-fixtures.json")))
        XCTAssertGreaterThanOrEqual(fixtures.count, 8)
        for f in fixtures {
            XCTAssertEqual(TermsText.canonical(f.input, domain: f.domain), f.canonical, f.domain)
            XCTAssertEqual(TermsText.hash(ofCanonical: f.canonical), f.hash, f.domain)
        }
    }
}


final class CountryTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func everything() throws -> [Jurisdiction] { try JurisdictionLoader.load(directory: root.appendingPathComponent("jurisdictions")) }
    private func country(_ code: String) throws -> Jurisdiction { try XCTUnwrap(try everything().first { $0.kind == "country" && $0.code == code }) }
    private var summary: RegistrySummary? { JurisdictionLoader.loadSummary(root.appendingPathComponent("registries/summary.json")) }
    private func platforms() throws -> [Platform] { try PlatformLoader.load(directory: root.appendingPathComponent("platforms")) }
    override func tearDown() { L10n.language = "en" }

    func testTheCountriesLoadWithTheEUAndEveryMemberAndAreUniqueByID() throws {
        let all = try everything()
        let countries = all.filter { $0.kind == "country" }
        XCTAssertGreaterThanOrEqual(countries.count, 50)
        XCTAssertEqual(all.filter { $0.kind == "bloc" }.map(\.code), ["EU"])
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        let eu = countries.filter { $0.bloc == "eu" }.map(\.code)
        XCTAssertEqual(eu.count, 27, "all 27 EU members")
        XCTAssertEqual(countries.filter { $0.bloc == "eea" }.map(\.code).sorted(), ["IS", "LI", "NO"])
        XCTAssertTrue(countries.allSatisfy { !$0.reviewed.isEmpty && ($0.regulator?.name.isEmpty == false) && ($0.sources?.isEmpty == false) })
    }

    func testRightsAreRecordedInOneVocabularyForStatesAndCountries() throws {
        XCTAssertEqual(try country("FR").privacyLaw?.deletionRight, .yes)
        XCTAssertEqual(try country("SG").privacyLaw?.deletionRight, .no)
        XCTAssertEqual(try country("HK").privacyLaw?.deletionRight, .unclear)
        XCTAssertEqual(try country("AU").privacyLaw?.deletionRight, .limited)
        let ca = try XCTUnwrap(try everything().first { $0.id == "us-ca" })
        XCTAssertEqual(ca.privacyLaw?.deletionRight, .yes, "a US entry written as true still reads")
        XCTAssertEqual(try country("IN").privacyLaw?.status, "enacted")
        XCTAssertEqual(try country("CL").privacyLaw?.effective, "2026-12-01")
        XCTAssertNil(try country("MX").privacyLaw?.effective, "not clear in the sources, so not guessed")
    }

    func testOnlyRegistriesOfBrokersCountAsBrokerRegistries() throws {
        XCTAssertFalse(try country("AR").registryIsLive, "a registry of databases is not a broker registry")
        XCTAssertFalse(try country("CA").registryIsLive, "Quebec's registers agents, not brokers in general")
        XCTAssertTrue(try country("IL").registryIsLive)
    }

    func testAFrenchResidentIsToldTheGDPRAndTheirRegulatorInFrench() throws {
        L10n.language = "fr"
        let lines = try country("FR").statements(summary: summary, platforms: platforms(), others: everything()).map(\.text)
        XCTAssertTrue(lines[0].hasPrefix("France a une loi sur la protection des données : Règlement général sur la protection des données"), lines[0])
        XCTAssertTrue(lines.contains { $0.contains("Loi Informatique et Libertés") })
        XCTAssertTrue(lines.contains { $0.contains("cnil.fr") })
        XCTAssertTrue(lines.contains { $0.contains("absolue") }, "the marketing objection is absolute")
    }

    func testEachCountryIsToldItsOwnRulesAndStrongPlacesAreOfferedAsExamples() throws {
        let all = try everything(), ps = try platforms()
        let sg = try country("SG").statements(summary: summary, platforms: ps, others: all).map(\.text)
        XCTAssertTrue(sg.contains { $0.contains("no general right to have your data deleted") })
        XCTAssertTrue(sg.contains { $0.contains("In California, one free request") }, "limited places are shown what stronger rules look like")
        let hk = try country("HK").statements(summary: summary, platforms: ps, others: all).map(\.text)
        XCTAssertTrue(hk.contains { $0.contains("could not confirm a general right") })
        let ca = try country("CA").statements(summary: summary, platforms: ps, others: all).map(\.text)
        XCTAssertTrue(ca.contains { $0.contains("Quebec") && $0.contains("no general data broker registry") })
        let ar = try country("AR").statements(summary: summary, platforms: ps, others: all).map(\.text)
        XCTAssertTrue(ar.contains { $0.contains("not data brokers") })
    }

    func testCountryNamesComeFromTheSystemInTheChosenLanguage() throws {
        XCTAssertEqual(try country("DE").displayName, "Germany")
        L10n.language = "de"; XCTAssertEqual(try country("DE").displayName, "Deutschland")
        L10n.language = "es"; XCTAssertEqual(try country("DE").displayName, "Alemania")
        L10n.language = "fr"; XCTAssertEqual(try country("JP").displayName, "Japon")
    }
}

final class LawSourcesAndPendingTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func everything() throws -> [Jurisdiction] { try JurisdictionLoader.load(directory: root.appendingPathComponent("jurisdictions")) }
    private func place(_ id: String) throws -> Jurisdiction { try XCTUnwrap(try everything().first { $0.id == id }) }
    override func tearDown() { L10n.language = "en" }

    func testEveryPlaceLinksToTheRealPagesItsFactsCameFrom() throws {
        for j in try everything() {
            XCTAssertFalse(j.sourceLinks.isEmpty, "\(j.id) has no source")
            for l in j.sourceLinks {
                let u = try XCTUnwrap(URL(string: l.url), "\(j.id): \(l.url)")
                XCTAssertEqual(u.scheme, "https", "\(j.id): \(l.url)")
                XCTAssertNotNil(u.host, l.url)
            }
        }
    }

    func testALawThatHasPassedButNotTakenEffectIsSaidSo() throws {
        let al = try place("us-al")
        XCTAssertFalse(try XCTUnwrap(al.privacyLaw).isInEffect(on: Jurisdiction.day("2026-10-22")!))
        XCTAssertTrue(try XCTUnwrap(al.privacyLaw).isInEffect(on: Jurisdiction.day("2027-05-01")!))
        let text = al.statements(summary: nil, platforms: []).map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("takes effect"), text)
    }

    func testLawsBeingConsideredAreShownWithTheirStageAndALink() throws {
        let ma = try place("us-ma").statements(summary: nil, platforms: [])
        let line = try XCTUnwrap(ma.first { $0.text.contains("Massachusetts Data Privacy Act") })
        XCTAssertTrue(line.text.hasPrefix("Moving through the legislature, not law yet"), line.text)
        XCTAssertEqual(line.url, "https://malegislature.gov/Bills/194/S2619")
        let il = try place("us-il").statements(summary: nil, platforms: []).filter { $0.text.hasPrefix("Being considered") }
        XCTAssertEqual(il.count, 2, "a privacy bill and a data broker bill")
        let ct = try place("us-ct").statements(summary: nil, platforms: []).map(\.text)
        XCTAssertTrue(ct.contains { $0.hasPrefix("Passed but not in effect yet (takes effect 2027-01-01)") })
        XCTAssertTrue(try place("country-ca").countryStatements(summary: nil, platforms: [], others: []).contains { $0.text.contains("Bill C-36") })
    }

    func testAPendingLawDisappearsOnceItTakesEffect() throws {
        let ct = try place("us-ct")
        XCTAssertEqual(ct.pendingStatements(now: Jurisdiction.day("2026-10-22")!).count, 1)
        XCTAssertEqual(ct.pendingStatements(now: Jurisdiction.day("2027-01-02")!).count, 0)
    }

    func testEveryPendingLawSaysWhenItWasChecked() throws {
        for j in try everything() { for p in j.pending ?? [] {
            XCTAssertTrue(["proposed", "advancing", "passed"].contains(p.stage), "\(j.id): \(p.stage)")
            XCTAssertNotNil(p.asOf, "\(j.id): \(p.name)")
        } }
    }
}

final class PlanTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func plan(withPlatforms: Bool) throws -> (steps: [PlanStep], entries: [DirectoryEntry]) {
        let entries = try Registry.loadDirectory(root.appendingPathComponent("directory"))
        let brokers = try Registry.load(directory: root.appendingPathComponent("brokers"))
        let platforms = withPlatforms ? try PlatformLoader.load(directory: root.appendingPathComponent("platforms")).filter(\.live) : []
        let steps = OptOutPlan.build(entries: entries, brokers: brokers, platforms: platforms,
                                     classifyEntry: { OptOutMethods.classify($0) }, classifyBroker: { OptOutMethods.classify($0, in: entries) })
        return (steps, entries)
    }

    func testEverySiteIsInExactlyOneStepAndNoneIsMissing() throws {
        for withPlatforms in [true, false] {
            let (steps, entries) = try plan(withPlatforms: withPlatforms)
            let all = steps.flatMap { $0.tasks.flatMap(\.domains) }
            XCTAssertEqual(all.count, Set(all).count, "a site is listed twice (platforms: \(withPlatforms))")
            // Closed sites are not tasks, and sites with no route yet are "locked" (listed apart): nothing else may be missing.
            let locked = OptOutPlan.locked(steps, entries: entries).map(\.domain)
            let missing = Set(entries.filter { $0.closed == nil && $0.excluded == nil }.map(\.domain)).subtracting(all).subtracting(locked)
            XCTAssertEqual(missing.sorted(), [], "platforms: \(withPlatforms)")
            XCTAssertTrue(OptOutPlan.locked(steps, entries: entries).allSatisfy { OptOutMethods.classify($0).method == .manual },
                          "only sites with no route are locked")
            XCTAssertFalse(steps.contains { $0.kind == .method(.manual) }, "there is no manual step: no route means locked")
        }
    }

    func testStepsRunInPriorityOrderWithTheOfficialServiceFirst() throws {
        let (steps, _) = try plan(withPlatforms: true)
        XCTAssertEqual(steps.first?.kind, .platform("ca-drop"))
        let methods = steps.compactMap { s -> OptOutMethod? in if case .method(let m) = s.kind { return m } else { return nil } }
        XCTAssertEqual(methods, OptOutMethod.allCases.filter { methods.contains($0) }, "automatic, semi-automated, guided, manual")
        XCTAssertGreaterThan(steps[0].siteCount, 500, "DROP handles hundreds of sites in one task")
        XCTAssertEqual(steps[0].tasks.count, 1)
    }

    func testAutomaticOptOutIsOneTaskAndSitesSharingAFormAreOneTask() throws {
        let (steps, entries) = try plan(withPlatforms: false)
        let auto = try XCTUnwrap(steps.first { $0.kind == .method(.automatic) })
        XCTAssertEqual(auto.tasks.count, 1)
        XCTAssertEqual(auto.tasks[0].kind, .automatic)
        XCTAssertGreaterThanOrEqual(auto.siteCount, 3, "only sites a reviewed real run confirmed")
        let tasks = steps.flatMap(\.tasks)
        for key in [\DirectoryEntry.template, \DirectoryEntry.family] as [KeyPath<DirectoryEntry, String?>] {
            for (k, members) in Dictionary(grouping: entries.filter { $0[keyPath: key] != nil }, by: { $0[keyPath: key]! }) where members.count > 1 {
                let holding = Set(members.compactMap { m in tasks.first { $0.domains.contains(m.domain) }?.id })
                XCTAssertEqual(holding.count, 1, "\(k) is split across tasks: \(holding)")
            }
        }
        for (u, members) in Dictionary(grouping: entries.filter { $0.optOutURL != nil }, by: { $0.optOutURL!.absoluteString }) where members.count > 1 {
            let holding = Set(members.compactMap { m in tasks.first { $0.domains.contains(m.domain) }?.id })
            XCTAssertEqual(holding.count, 1, "\(u) is split across tasks")
        }
    }

    func testSitesSharingOneRequestAreOneTaskThatNamesThemAll() throws {
        let (steps, _) = try plan(withPlatforms: false)
        let tasks = steps.flatMap(\.tasks)
        let spokeo = try XCTUnwrap(tasks.first { $0.kind == .flow("spokeo") })
        XCTAssertTrue(spokeo.domains.contains("freepeopledirectory.com"))
        XCTAssertTrue(spokeo.isShared)
        XCTAssertEqual(tasks.filter { $0.domains.contains("freepeopledirectory.com") }.count, 1)
        XCTAssertLessThan(tasks.count, steps.reduce(0) { $0 + $1.siteCount }, "fewer tasks than sites")
    }

    private func task(_ id: String, _ method: OptOutMethod?, sites: Int = 1, states: Set<String> = [], kind: PlanTask.Kind? = nil) -> PlanTask {
        PlanTask(kind: kind ?? .site(id), title: id, domains: (0..<sites).map { "\(id)\($0).com" }, reason: "", method: method, registeredIn: states)
    }

    func testTheQueueRanksTasksInTheOrderTheUserAsked() {
        let tasks = [
            task("global-manual", .manual), task("local-manual-small", .guided, sites: 2, states: ["TX"]), task("global-semi", .semiAutomatic),
            task("local-manual-big", .guided, sites: 12, states: ["TX"]), task("country-semi", .semiAutomatic, states: ["OH"]),
            task("local-semi", .semiAutomatic, states: ["TX"]), task("auto", .automatic, sites: 40, kind: .automatic),
            task("drop", nil, sites: 600, kind: .platform("ca-drop")), task("country-manual-big", .manual, sites: 11, states: ["OH"]),
        ]
        let steps = [PlanStep(kind: .method(.guided), title: "", explanation: "", tasks: tasks)]
        let queue = OptOutPlan.queue(steps, local: ["TX"], countryHasRegistries: true)
        XCTAssertEqual(queue.flatMap { $0.tasks.map(\.title) },
                       ["drop", "auto", "local-semi", "country-semi", "local-manual-big", "country-manual-big", "global-semi", "local-manual-small", "global-manual"])
        XCTAssertEqual(queue.map(\.rank), [.localOfficial, .ourAutomatic, .localSemi, .countrySemi, .localManualBig, .globalSemi, .localManualRest, .globalManual])
    }

    func testOutsideACountryWithRegistriesNothingIsLocalOrCountryLevel() {
        let steps = [PlanStep(kind: .method(.guided), title: "", explanation: "", tasks: [task("a", .semiAutomatic, states: ["TX"]), task("b", .guided, sites: 20, states: ["TX"])])]
        let queue = OptOutPlan.queue(steps, local: [], countryHasRegistries: false)
        XCTAssertEqual(queue.map(\.rank), [.globalSemi, .globalManual])
    }

    func testEveryTaskIsInExactlyOneBandOfTheRealQueue() throws {
        let (steps, _) = try plan(withPlatforms: true)
        let queue = OptOutPlan.queue(steps, local: ["CA"], countryHasRegistries: true)
        XCTAssertEqual(queue.flatMap(\.tasks).count, steps.flatMap(\.tasks).count)
        XCTAssertEqual(queue.first?.rank, .localOfficial)
        XCTAssertEqual(queue.map(\.rank), queue.map(\.rank).sorted())
    }
}

final class RequestAcknowledgementTests: XCTestCase {
    func testTheDataAxleFamilyNoteAboutVerifyingIdentityCountsAsTheOwnersOwnBox() {
        let note = "By submitting, I understand that I may be required to verify my identity to complete this request, and I authorize Data Axle to contact me if needed."
        XCTAssertTrue(FormFiller.isSelfIdentityBox(note))
        XCTAssertFalse(FormFiller.isSelfIdentityBox("I agree to the terms of use and I authorize you to contact me about offers."))
        XCTAssertFalse(FormFiller.isSelfIdentityBox("I may be required to verify my identity and I authorize you to contact me and share my data with third parties."))
        XCTAssertFalse(FormFiller.isSelfIdentityBox("I agree to ROQAD emailing me the newsletter."))
    }
}

final class MeasuredAutomaticTests: XCTestCase {
    func testDataAxleOwnNoteIsNotABlockerForTheOwner() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("directory")
        let entries = try Registry.loadDirectory(dir)
        let axle = try XCTUnwrap(entries.first { $0.domain == "data-axle.com" })
        XCTAssertNotNil(axle.liveCheck)
        XCTAssertEqual(OptOutMethods.classify(axle, confirmingIdentity: true).method, .semiAutomatic, "unproven by a real run, so a person confirms")
        XCTAssertFalse(OptOutMethods.classify(axle, confirmingIdentity: true).reason.contains("page shows"), "its identity note is not a blocker for the owner")
        // Sites with a visible bot check never count as automatic.
        let withCheck = entries.filter { $0.liveCheck?.blockers.contains { $0.hasPrefix("check") } == true }
        XCTAssertFalse(withCheck.isEmpty)
        for e in withCheck { XCTAssertNotEqual(OptOutMethods.classify(e, confirmingIdentity: true).method, .automatic, e.domain) }
    }
}

final class EvidenceTests: XCTestCase {
    private func store() -> EvidenceStore {
        EvidenceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ook-evidence-\(UUID())"), keys: FixedKey())
    }

    func testAScreenshotIsKeptSealedAndComesBackIntact() throws {
        let s = store(), who = UUID()
        let image = Data((0..<2000).map { UInt8($0 % 251) })
        try s.save(image, person: who, site: "example.com")
        XCTAssertEqual(s.load(person: who, site: "example.com"), image)
        let raw = try Data(contentsOf: s.directory.appendingPathComponent(who.uuidString).appendingPathComponent("example.com.jpg.sealed"))
        XCTAssertNil(raw.range(of: image.prefix(64)), "the file does not hold the picture in the clear")
        XCTAssertNil(s.load(person: UUID(), site: "example.com"), "another person's screenshots are separate")
        s.removeAll(person: who)
        XCTAssertFalse(s.exists(person: who, site: "example.com"))
    }

    func testOldScreenshotsArePruned() throws {
        let s = store(), who = UUID()
        try s.save(Data([1, 2, 3]), person: who, site: "a.com")
        s.prune(olderThan: 90, now: Date().addingTimeInterval(30 * 86_400)); XCTAssertTrue(s.exists(person: who, site: "a.com"))
        s.prune(olderThan: 90, now: Date().addingTimeInterval(120 * 86_400)); XCTAssertFalse(s.exists(person: who, site: "a.com"))
    }

    func testTheRunHandsEachSitesScreenshotToTheCallerAndNeverForAPreview() async throws {
        struct Shot: FormSubmitter {
            func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome { .submitted(awaitingEmail: false) }
            func submitCapturing(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitEvidence {
                SubmitEvidence(outcome: .submitted(awaitingEmail: false), screenshot: Data([9, 9]))
            }
        }
        final class Got: @unchecked Sendable { var sites: [String] = [] }
        let form = OptOutForm(page: URL(string: "https://x.example/optout")!, method: "post", action: nil,
                              fields: [FormField(type: "email", name: "email", label: "Email")], hops: 1)
        let entry = DirectoryEntry(id: "x", domain: "x.example", name: "x", bucket: "direct", tier: .B, automation: .guided,
                                   optOutURL: form.page, optOutForm: form, signals: [])
        let person = Person(displayName: "Pat", names: [NameEntry(kind: .legal, name: "Pat Example")],
                            addresses: [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")], emails: ["pat@example.com"])
        let got = Got()
        _ = await AutoOptOut(submitter: Shot(), spacing: 0).run(entries: [entry], person: person, progress: Progress(), dryRun: false, evidence: { e, _ in got.sites.append(e.id) })
        XCTAssertEqual(got.sites, ["x"])
        let preview = Got()
        _ = await AutoOptOut(submitter: Shot(), spacing: 0).run(entries: [entry], person: person, progress: Progress(), dryRun: true, evidence: { e, _ in preview.sites.append(e.id) })
        XCTAssertTrue(preview.sites.isEmpty)
    }
}

final class RunCheckTests: XCTestCase {
    private func clean(_ run: RunCheck?) -> DirectoryEntry {
        let f = OptOutForm(page: URL(string: "https://x.example/optout")!, method: "post", action: nil,
                           fields: [FormField(type: "email", name: "email", label: "Email")], hops: 1)
        var e = DirectoryEntry(id: "x", domain: "x.example", name: "x", bucket: "direct", tier: .B, automation: .guided, optOutURL: f.page, optOutForm: f, signals: [])
        e.liveCheck = LiveCheck(checked: "2026-10-22", blockers: []); e.runCheck = run
        return e
    }

    func testAReviewedRealRunOutranksEveryGuess() {
        XCTAssertEqual(OptOutMethods.classify(clean(nil)).method, .semiAutomatic, "clean at load, nothing proven by a real run")
        XCTAssertEqual(OptOutMethods.classify(clean(RunCheck(date: "2026-10-23", result: "failed", note: "a cookie banner covered the form"))).method, .guided)
        XCTAssertEqual(OptOutMethods.classify(clean(RunCheck(date: "2026-10-23", result: "confirmed"))).method, .automatic)
        XCTAssertEqual(OptOutMethods.classify(clean(RunCheck(date: "2026-10-23", result: "confirmed")), challengedBefore: true).method, .semiAutomatic,
                       "a later check still moves it")
    }

    func testTheReviewedRunIsInTheDirectory() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("directory")
        let entries = try Registry.loadDirectory(dir)
        let confirmed = entries.filter { $0.runCheck?.result == "confirmed" }.map(\.domain).sorted()
        XCTAssertEqual(confirmed, ["abovedata.io", "acronymix.com", "advancedbackgroundchecks.com", "apollo.io", "attribits.com", "donorbureau.com", "draup.com", "everleads.com", "gatewaydata.io", "getliminal.com", "inmar.com", "lionsharemarketing.com", "liveintent.com", "marketingarchitects.com", "networx.com", "scileads.com", "semantiqhealth.com", "statsocial.com", "stirista.com", "subgraph.tech", "torusvotersystems.com"])
        // The failed marks from the first reviewed run were cleared: most of those failures were the app's own (wrong form, cookie prompt,
        // unticked choices) and were fixed, so the next real run decides.
        XCTAssertEqual(entries.filter { $0.runCheck?.result == "failed" }.count, 6, "only what a reviewed redo showed is blocked by a bot check")
    }
}

final class SharedTargetTests: XCTestCase {
    func testSitesSharingOneOptOutPageAreSentOnceAndShareTheResult() async {
        final class Count: @unchecked Sendable { var calls = 0 }
        struct Counting: FormSubmitter {
            let c: Count
            func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome { c.calls += 1; return .submitted(awaitingEmail: false) }
        }
        let f = OptOutForm(page: URL(string: "https://privacy.shared.example/optout")!, method: "post", action: URL(string: "https://privacy.shared.example/submit"),
                           fields: [FormField(type: "email", name: "email", label: "Email")], hops: 1)
        func entry(_ id: String) -> DirectoryEntry {
            DirectoryEntry(id: id, domain: id + ".com", name: id, bucket: "direct", tier: .B, automation: .guided, optOutURL: f.page, optOutForm: f, signals: [])
        }
        let person = Person(displayName: "Pat", names: [NameEntry(kind: .legal, name: "Pat Example")],
                            addresses: [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")], emails: ["pat@example.com"])
        let c = Count()
        let out = await AutoOptOut(submitter: Counting(c: c), spacing: 0).run(entries: [entry("a"), entry("b"), entry("c")], person: person, progress: Progress())
        XCTAssertEqual(c.calls, 1, "one request for the three sites that share a page")
        XCTAssertEqual(out.map(\.0.id), ["a", "b", "c"])
        XCTAssertTrue(out.allSatisfy { $0.1 == .submitted(awaitingEmail: false) })
    }
}

final class EmailOnlyAndAddressTests: XCTestCase {
    func testASiteThatTakesOptOutsByEmailIsAGuideWithTheAddress() {
        var e = DirectoryEntry(id: "x", domain: "x.example", name: "x", bucket: "direct", tier: .B, automation: .guided,
                               optOutURL: URL(string: "https://x.example/dnsmi"), signals: [])
        e.contactEmail = "privacy@x.example"
        let v = OptOutMethods.classify(e)
        XCTAssertEqual(v.method, .guided)
        XCTAssertTrue(v.reason.contains("privacy@x.example"), v.reason)
    }

    func testASecondAddressLineStaysEmptyAndCountryIsFilledForAUSAddress() {
        let form = OptOutForm(page: URL(string: "https://x.example/o")!, method: "post", action: nil, fields: [
            FormField(type: "text", name: "a1", label: "Address 1 *"), FormField(type: "text", name: "a2", label: "Address 2"),
            FormField(type: "text", name: "apt", label: "Apt / Suite / Unit"), FormField(type: "select", name: "c", label: "Country"),
            FormField(type: "text", name: "z", label: "ZIP *")], hops: 1)
        let p = Person(displayName: "P", names: [NameEntry(kind: .legal, name: "Pat Example")],
                       addresses: [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")], emails: ["pat@example.com"])
        let plan = FormFiller.plan(for: form, signals: nil, person: p)
        let byName = Dictionary(uniqueKeysWithValues: plan.values.map { ($0.name, $0.candidates) })
        XCTAssertEqual(byName["a1"], ["1 Main St"])
        XCTAssertNil(byName["a2"]); XCTAssertNil(byName["apt"])
        XCTAssertEqual(byName["c"]?.first, "United States")
        XCTAssertEqual(byName["z"], ["62701"])
    }
}

final class EmailBatchTests: XCTestCase {
    func testSitesThatTakeEmailAreOneTaskAndAMessageListsEverySiteForItsAddress() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let entries = try Registry.loadDirectory(dir.appendingPathComponent("directory"))
        let brokers = try Registry.load(directory: dir.appendingPathComponent("brokers"))
        let steps = OptOutPlan.build(entries: entries, brokers: brokers, platforms: [], classifyEntry: { OptOutMethods.classify($0, confirmingIdentity: true) },
                                     classifyBroker: { OptOutMethods.classify($0, in: entries) })
        let tasks = steps.flatMap(\.tasks)
        let mail = try XCTUnwrap(tasks.first { $0.kind == .emails })
        XCTAssertGreaterThanOrEqual(mail.siteCount, 50)
        XCTAssertEqual(mail.method, .guided, "email is not part of the semi-automated step")
        XCTAssertTrue(entries.filter { mail.domains.contains($0.domain) }.allSatisfy { !OptOutPlan.hasForm($0) }, "only sites with no form")
        XCTAssertEqual(tasks.filter { $0.kind == .emails }.count, 1)
        let all = tasks.flatMap(\.domains); XCTAssertEqual(all.count, Set(all).count, "still listed once")
        let mine = entries.filter { mail.domains.contains($0.domain) }
        let single = EmailBatch.single(entries: mine)
        XCTAssertEqual(single.count, 1, "one message for everything")
        XCTAssertEqual(single[0].domains.count, mail.siteCount)
        XCTAssertEqual(single[0].addresses.count, Set(single[0].addresses).count, "each address once")
        XCTAssertGreaterThan(single[0].addresses.count, 20)
        XCTAssertEqual(EmailBatch.single(entries: mine, maxRecipients: 10).count, Int((Double(single[0].addresses.count) / 10).rounded(.up)), "a limit splits it")
        XCTAssertEqual(EmailBatch.single(entries: mine, maxRecipients: 10).flatMap(\.domains).count, mail.siteCount)
        let body = single[0].body(name: "Pat Example", email: "pat+optoutkit@gmail.com", address: "1 Main St, Springfield, IL 62701")
        XCTAssertTrue(body.contains("Pat Example") && body.contains("pat+optoutkit@gmail.com"))
        XCTAssertFalse(body.contains(single[0].domains[0]), "generic: it names no site")
    }
}

final class VerifyTaskTests: XCTestCase {
    func testFormsThatOnlyNeedABotCheckTickedAreOneTaskWithTheEmailTaskAlongside() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let entries = try Registry.loadDirectory(dir.appendingPathComponent("directory"))
        let brokers = try Registry.load(directory: dir.appendingPathComponent("brokers"))
        let steps = OptOutPlan.build(entries: entries, brokers: brokers, platforms: [], classifyEntry: { OptOutMethods.classify($0, confirmingIdentity: true) },
                                     classifyBroker: { OptOutMethods.classify($0, in: entries) })
        let tasks = steps.flatMap(\.tasks)
        XCTAssertNil(tasks.first { $0.kind == .verify }, "no mega-task: each site or shared-form group is its own task")
        let semi = try XCTUnwrap(steps.first { $0.kind == .method(.semiAutomatic) }).tasks
        XCTAssertGreaterThan(semi.count, 100)
        XCTAssertTrue(semi.allSatisfy { $0.kind != .emails })
        XCTAssertTrue(semi.contains { $0.domains.count > 1 }, "shared-form groups such as data-axle stay one task")
        XCTAssertGreaterThan(OptOutPlan.verifyQueue(steps, entries: entries).count, 50)
        let all = tasks.flatMap(\.domains); XCTAssertEqual(all.count, Set(all).count)
    }
}

final class GenericEmailAndMailAppTests: XCTestCase {
    func testTheMessageIsTheSameForEveryCompanyAndNamesNeitherTheCompanyNorItsSites() {
        let a = EmailBatch(address: "a@x.com", addresses: ["a@x.com"], domains: ["x.com"], entryIDs: ["x"])
        let b = EmailBatch(address: "b@y.com", addresses: ["b@y.com", "c@z.com"], domains: ["y.com", "z.com"], entryIDs: ["y", "z"])
        let ba = a.body(name: "Pat Example", email: "pat@gmail.com", address: "1 Main St"), bb = b.body(name: "Pat Example", email: "pat@gmail.com", address: "1 Main St")
        XCTAssertEqual(ba, bb)
        XCTAssertFalse(ba.contains("x.com") || ba.contains("y.com"))
        for need in ["Pat Example", "pat@gmail.com", "1 Main St", "Opt me out", "Delete"] { XCTAssertTrue(ba.contains(need), need) }
    }

    func testEveryMailAppGetsALinkCarryingTheBccListSubjectAndBody() throws {
        for app in MailApp.allCases {
            let url = try XCTUnwrap(app.composeURL(to: "me@gmail.com", bcc: ["a@x.com", "b@y.com"], subject: "Opt-out request", body: "Hello"), app.name)
            let text = url.absoluteString.removingPercentEncoding ?? ""
            XCTAssertTrue(text.contains("a@x.com") && text.contains("b@y.com"), "\(app.name): \(text)")
            XCTAssertTrue(text.contains("Opt-out request") && text.contains("Hello"), app.name)
        }
        XCTAssertEqual(MailApp.gmail.composeURL(to: "", bcc: ["a@x.com"], subject: "s", body: "b")?.scheme, "googlegmail")
        XCTAssertEqual(MailApp.other.composeURL(to: "", bcc: ["a@x.com"], subject: "s", body: "b")?.scheme, "mailto")
        XCTAssertEqual(Set(MailApp.probeSchemes), ["googlegmail", "ms-outlook", "ymail", "readdle-spark", "protonmail"])
    }
}

final class DailyGoalsTests: XCTestCase {
    private func site(_ i: Int, email: Bool = true) -> DirectoryEntry {
        var e = DirectoryEntry(id: "s\(i)", domain: "s\(i).com", name: "s\(i)", bucket: "direct", tier: .B, automation: .guided, signals: [])
        if email { e.contactEmail = "privacy@s\(i).com" }
        return e
    }

    func testTodayIsTheNext25SitesAndTheirEmailsAndAnEarlierDayIsLeftBehind() {
        let entries = (0..<60).map { site($0) }
        let queue = entries.map(\.domain)
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        var g = DailyGoals.build(queue: queue, entries: entries, attempts: [:], now: now, calendar: cal)
        XCTAssertEqual(g.verify.count, 25)
        XCTAssertEqual(g.verify.first, "s0.com")
        XCTAssertEqual(g.email?.domains.count, 25)
        XCTAssertEqual(g.verifyDone, 0); XCTAssertFalse(g.allComplete)

        // Ten finished today stay in today's list and count.
        var attempts: [String: [OptOutAttempt]] = [:]
        for i in 0..<10 { attempts["s\(i)"] = [OptOutAttempt(date: now, outcome: "submitted")] }
        g = DailyGoals.build(queue: queue, entries: entries, attempts: attempts, now: now, calendar: cal)
        XCTAssertEqual(g.verify.count, 25); XCTAssertEqual(g.verify.first, "s0.com"); XCTAssertEqual(g.verifyDone, 10)

        // Finished yesterday: tomorrow's list starts after them.
        let tomorrow = now.addingTimeInterval(86_400)
        g = DailyGoals.build(queue: queue, entries: entries, attempts: attempts, now: tomorrow, calendar: cal)
        XCTAssertEqual(g.verify.first, "s10.com"); XCTAssertEqual(g.verifyDone, 0)
    }

    func testEmailingTheBatchCompletesTheSecondGoalAndAnotherBatchAddsTwentyFiveMore() {
        let entries = (0..<60).map { site($0) }
        let queue = entries.map(\.domain), now = Date(), cal = Calendar(identifier: .gregorian)
        var attempts: [String: [OptOutAttempt]] = [:]
        for i in 0..<25 { attempts["s\(i)"] = [OptOutAttempt(date: now, outcome: "submitted"), OptOutAttempt(date: now, outcome: "emailed")] }
        var g = DailyGoals.build(queue: queue, entries: entries, attempts: attempts, now: now, calendar: cal)
        XCTAssertTrue(g.verifyComplete && g.emailComplete && g.allComplete)
        g = DailyGoals.build(queue: queue, entries: entries, attempts: attempts, now: now, batches: 2, calendar: cal)
        XCTAssertEqual(g.verify.count, 50); XCTAssertFalse(g.allComplete)
        XCTAssertEqual(DailyGoals.daysLeft(remaining: 700), 28)
    }

    func testEverythingFinishedTodayIsEmailedEvenWhenItIsNotInTheListedBatch() {
        let entries = (0..<40).map { site($0) }
        let queue = Array(entries.prefix(30).map(\.domain)), now = Date(), cal = Calendar(identifier: .gregorian)
        let attempts = ["s35": [OptOutAttempt(date: now, outcome: "submitted")]]          // done by the automatic run, not in the queue
        let g = DailyGoals.build(queue: queue, entries: entries, attempts: attempts, now: now, calendar: cal)
        XCTAssertEqual(g.verify.count, 25)
        XCTAssertEqual(g.email?.domains.count, 26, "the batch plus the site done another way")
        XCTAssertTrue(g.email?.domains.contains("s35.com") ?? false)
    }

    func testEachBatchIsOneKindOfBrokerAndAnotherBatchTakesTheNextKind() {
        func kinded(_ i: Int, _ k: String) -> DirectoryEntry {
            var e = site(i); e.about = BrokerAbout(category: k, summary: "s"); return e
        }
        // Interleaved kinds in queue order: 40 ad tech and 30 people search.
        let entries = (0..<70).map { kinded($0, $0 % 7 < 4 ? "people_search" : "adtech") }
        let queue = entries.map(\.domain), cal = Calendar(identifier: .gregorian), now = Date()
        var g = DailyGoals.build(queue: queue, entries: entries, attempts: [:], now: now, calendar: cal)
        XCTAssertEqual(g.themes, ["people_search"])
        XCTAssertEqual(g.verify.count, 25)
        let byDomain = Dictionary(entries.map { ($0.domain, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertTrue(g.verify.allSatisfy { byDomain[$0]?.about?.category == "people_search" }, "a batch is one kind")
        XCTAssertEqual(g.verify.first, "s0.com", "queue order within the kind")
        g = DailyGoals.build(queue: queue, entries: entries, attempts: [:], now: now, batches: 2, calendar: cal)
        XCTAssertEqual(g.themes, ["people_search", "people_search"], "people search has 40, so the next 15 are still ad tech")
        XCTAssertEqual(g.verify.count, 40)
    }

    func testThePersonChoosesTheKindForEachBatchAndSeesHowManyAreLeft() {
        func kinded(_ i: Int, _ k: String) -> DirectoryEntry { var e = site(i); e.about = BrokerAbout(category: k, summary: "s"); return e }
        let entries = (0..<60).map { kinded($0, $0 < 30 ? "people_search" : "adtech") }      // ad tech first in the queue
        let queue = entries.map(\.domain), cal = Calendar(identifier: .gregorian), now = Date()
        let left = DailyGoals.remainingByKind(queue: queue, entries: entries, attempts: [:], now: now, calendar: cal)
        XCTAssertEqual(left.map(\.count), [30, 30]); XCTAssertEqual(Set(left.map(\.kind)), ["people_search", "adtech"])
        // Default: the best-ranked kind with sites left (people search), even though ad tech is first in the queue. Chosen: ad tech.
        XCTAssertEqual(DailyGoals.build(queue: queue, entries: entries, attempts: [:], now: now, calendar: cal).themes, ["people_search"])
        let g = DailyGoals.build(queue: queue, entries: entries, attempts: [:], now: now, chosen: ["adtech"], calendar: cal)
        XCTAssertEqual(g.themes, ["adtech"])
        XCTAssertTrue(g.verify.allSatisfy { Int($0.dropFirst().dropLast(4))! >= 30 })
        // A second batch of a chosen kind: people search then ad tech.
        let two = DailyGoals.build(queue: queue, entries: entries, attempts: [:], now: now, chosen: ["adtech", "people_search"], calendar: cal)
        XCTAssertEqual(two.themes, ["adtech", "people_search"]); XCTAssertEqual(two.verify.count, 50)
        // A chosen kind with nothing left falls back instead of an empty batch.
        let none = DailyGoals.build(queue: queue, entries: entries, attempts: [:], now: now, chosen: ["political"], calendar: cal)
        XCTAssertEqual(none.themes, ["people_search"])
    }

    func testASiteWithNoEmailAddressStillCountsForTheFirstGoal() {
        let entries = [site(0, email: false), site(1)]
        let g = DailyGoals.build(queue: entries.map(\.domain), entries: entries, attempts: [:])
        XCTAssertEqual(g.verify.count, 2); XCTAssertEqual(g.email?.domains, ["s1.com"])
    }
}

final class CoverageReportTests: XCTestCase {
    func testPrintTheCoverage() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let entries = try Registry.loadDirectory(dir.appendingPathComponent("directory"))
        var counts: [String: Int] = [:]; var reasons: [String: Int] = [:]
        for e in entries {
            let v = OptOutMethods.classify(e, confirmingIdentity: true)
            var tag = "\(v.method)"
            if e.optOutForm == nil { tag += e.contactEmail != nil ? "+emailonly" : (e.optOutURL != nil ? "+pageNoForm" : "+nopage") }
            counts[tag, default: 0] += 1
            if v.method == .guided || v.method == .manual { reasons[String(v.reason.prefix(90)), default: 0] += 1 }
        }
        print("COVERAGE", counts.sorted { $0.key < $1.key })
        for (r, n) in reasons.sorted(by: { $0.value > $1.value }).prefix(40) { print("REASON \(n) \(r)") }
    }
}

final class TypedCodeTests: XCTestCase {
    func testACaptchaTextBoxIsLeftForThePersonAndTheSiteGoesLastInTheVerifyTask() throws {
        let plain = OptOutForm(page: URL(string: "https://a.example/o")!, method: "post", action: nil,
                               fields: [FormField(type: "text", name: "first", label: "First *"), FormField(type: "email", name: "em", label: "Email *")], hops: 1)
        let coded = OptOutForm(page: URL(string: "https://b.example/o")!, method: "post", action: nil,
                               fields: plain.fields + [FormField(type: "text", name: "cap", label: "Captcha *")], hops: 1)
        XCTAssertTrue(FormFiller.hasTypedCode(coded)); XCTAssertFalse(FormFiller.hasTypedCode(plain))
        let p = Person(displayName: "P", names: [NameEntry(kind: .legal, name: "Pat Example")], addresses: [Address(street: "1 Main", city: "X", state: "IL", zip: "60601")], emails: ["pat@example.com"])
        let plan = FormFiller.plan(for: coded, signals: nil, person: p)
        XCTAssertEqual(plan.verdict, .ready, "the code is not something we lack: the person types it")
        XCTAssertNil(plan.values.first { $0.name == "cap" })
        func entry(_ id: String, _ f: OptOutForm) -> DirectoryEntry { DirectoryEntry(id: id, domain: id + ".example", name: id, bucket: "direct", tier: .B, automation: .guided, optOutURL: f.page, optOutForm: f, signals: []) }
        let entries = [entry("b", coded), entry("a", plain)]            // the coded one is listed first
        let steps = OptOutPlan.build(entries: entries, brokers: [], platforms: [], classifyEntry: { OptOutMethods.classify($0) }, classifyBroker: { OptOutMethods.classify($0) })
        XCTAssertEqual(steps.flatMap(\.tasks).map(\.title), ["a.example", "b.example"], "typed-code forms come last")
        XCTAssertEqual(OptOutPlan.verifyQueue(steps, entries: entries), ["a.example", "b.example"])
    }
}


final class BrokerAboutTests: XCTestCase {
    func testAnAboutBlockAndPriorityDecodeFromTheDirectoryFormat() throws {
        let yaml = """
        id: "x_com"
        domain: "x.com"
        name: "X"
        bucket: "registry"
        automation: "guided"
        priority: 72
        about: {"category": "people_search", "summary": "X is a people-search site.", "tracks": ["phone numbers"], "sells_to": ["advertisers and marketers"], "sells_note": "We sell to advertisers.", "source": "https://x.com/privacy"}
        """
        let e = try YAMLDecoder().decode(DirectoryEntry.self, from: yaml)
        XCTAssertEqual(e.priority, 72)
        XCTAssertEqual(e.about?.sellsTo, ["advertisers and marketers"])
        XCTAssertEqual(e.about?.category, "people_search")
        XCTAssertEqual(BrokerPriority.tier(72), "High priority"); XCTAssertEqual(BrokerPriority.tier(50), "Medium priority"); XCTAssertEqual(BrokerPriority.tier(10), "Lower priority")
    }

    func testWithinABandTheHighestPriorityBrokersComeFirst() {
        func site(_ d: String, _ p: Int) -> DirectoryEntry {
            var e = DirectoryEntry(id: d, domain: d + ".com", name: d, bucket: "direct", tier: .B, automation: .guided, optOutURL: URL(string: "https://\(d).com/optout"), signals: [])
            e.priority = p; return e
        }
        let entries = [site("a", 10), site("b", 90), site("c", 50)]
        let steps = OptOutPlan.build(entries: entries, brokers: [], platforms: [], classifyEntry: { _ in MethodVerdict(method: .semiAutomatic, reason: "r") }, classifyBroker: { _ in MethodVerdict(method: .semiAutomatic, reason: "r") })
        let band = OptOutPlan.queue(steps, local: [], countryHasRegistries: false).flatMap(\.tasks).map(\.title)
        XCTAssertEqual(band, ["b.com", "c.com", "a.com"])
    }
}


final class BrokerKindsTests: XCTestCase {
    func testEveryIdTheDescriberWritesIsAKnownKindAndFiltersMatchOnIt() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let entries = try Registry.loadDirectory(dir.appendingPathComponent("directory"))
        let described = entries.filter { $0.about != nil }
        XCTAssertGreaterThan(described.count, 500)
        for e in described {
            XCTAssertNotNil(e.brokerCategory, "\(e.domain): unknown category \(e.about?.category ?? "")")
            XCTAssertEqual(e.dataKinds.count, e.about?.tracks.count, "\(e.domain): unknown data kind")
            XCTAssertEqual(e.buyerKinds.count, e.about?.sellsTo.count, "\(e.domain): unknown buyer kind")
        }
        let people = described.first { $0.brokerCategory == .people_search && $0.dataKinds.contains(.relatives) }
        let p = try XCTUnwrap(people)
        XCTAssertTrue(p.matches(category: .people_search, data: .relatives, buyer: nil))
        XCTAssertFalse(p.matches(category: .adtech, data: nil, buyer: nil))
        XCTAssertTrue(p.matches(category: nil, data: nil, buyer: nil))
    }
}


final class BrokerRankTests: XCTestCase {
    func testTheEighteenKindsHaveOneRankEachAndHarmScoresStayInRange() {
        XCTAssertEqual(BrokerCategory.allCases.count, 18)
        XCTAssertEqual(BrokerCategory.ranked.map(\.rank), Array(1...18))
        XCTAssertEqual(BrokerCategory.ranked.first, .people_search)
        XCTAssertEqual(BrokerCategory.ranked.last, .other)
        for c in BrokerCategory.allCases {
            let h = c.harm
            XCTAssertTrue([h.safety, h.money, h.reputation, h.annoyance].allSatisfy { (0...3).contains($0) }, c.rawValue)
            XCTAssertFalse(c.rankReason.isEmpty); XCTAssertFalse(c.bestCase.isEmpty); XCTAssertFalse(c.worstCase.isEmpty)
        }
        // The default order puts physical-safety harms ahead of annoyances.
        XCTAssertLessThan(BrokerCategory.people_search.rank, BrokerCategory.b2b.rank)
        XCTAssertLessThan(BrokerCategory.location_data.rank, BrokerCategory.adtech.rank)
    }
}


final class DailyResetAndSummaryTests: XCTestCase {
    private func entry(_ i: Int, _ kind: String) -> DirectoryEntry {
        var e = DirectoryEntry(id: "s\(i)", domain: "s\(i).com", name: "s\(i)", bucket: "direct", tier: .B, automation: .guided, signals: [])
        e.about = BrokerAbout(category: kind, summary: "s"); return e
    }

    func testEachDayStartsAtTheBestRankedKindUnlessTodaysWorkIsUnderway() {
        // Queue order puts ad tech first; people search outranks it.
        let entries = (0..<20).map { entry($0, $0 < 10 ? "adtech" : "people_search") }
        let queue = entries.map(\.domain), cal = Calendar(identifier: .gregorian), now = Date(), yesterday = now.addingTimeInterval(-86_400)
        // Nothing done: the best-ranked kind.
        XCTAssertEqual(DailyGoals.build(queue: queue, entries: entries, attempts: [:], now: now, calendar: cal).themes, ["people_search"])
        // Ad tech finished YESTERDAY does not pull today toward ad tech: the day resets.
        let past = ["s0": [OptOutAttempt(date: yesterday, outcome: "submitted")]]
        XCTAssertEqual(DailyGoals.build(queue: queue, entries: entries, attempts: past, now: now, calendar: cal).themes, ["people_search"])
        // Ad tech started TODAY and still unfinished: stay on it.
        let today = ["s0": [OptOutAttempt(date: now, outcome: "submitted")]]
        let g = DailyGoals.build(queue: queue, entries: entries, attempts: today, now: now, calendar: cal)
        XCTAssertEqual(g.themes, ["adtech"]); XCTAssertEqual(g.verifyDone, 1)
        // The chooser counts only sites still unfinished.
        let left = DailyGoals.remainingByKind(queue: queue, entries: entries, attempts: today, now: now, calendar: cal)
        XCTAssertEqual(left.first?.kind, "people_search"); XCTAssertEqual(left.first(where: { $0.kind == "adtech" })?.count, 9)
    }

    func testTheSummaryCountsSitesEmailsAndTheMostRecentDay() {
        let entries = [entry(0, "people_search"), entry(1, "people_search"), entry(2, "adtech"), entry(3, "adtech")]
        let cal = Calendar(identifier: .gregorian), now = Date(), d1 = now.addingTimeInterval(-3 * 86_400), d2 = now.addingTimeInterval(-86_400)
        let attempts: [String: [OptOutAttempt]] = [
            "s0": [OptOutAttempt(date: d1, outcome: "submitted"), OptOutAttempt(date: d1, outcome: "emailed")],
            "s1": [OptOutAttempt(date: d2, outcome: "submitted")],
            "s2": [OptOutAttempt(date: d2, outcome: "submitted_email")],
            "s3": [OptOutAttempt(date: d2, outcome: "failed")],
        ]
        let s = ActivitySummary.build(entries: entries, attempts: attempts, calendar: cal)
        XCTAssertEqual(s.sites, 3); XCTAssertEqual(s.emails, 1); XCTAssertEqual(s.activeDays, 2)
        XCTAssertEqual(s.lastDay, cal.startOfDay(for: d2)); XCTAssertEqual(s.lastDaySites, 2)
        XCTAssertEqual(Set(s.lastDayKinds.map(\.kind)), ["people_search", "adtech"])
        XCTAssertEqual(s.byKind.first, KindCount(kind: "people_search", count: 2), "most first")
        XCTAssertFalse(s.isEmpty)
        XCTAssertTrue(ActivitySummary.build(entries: entries, attempts: [:], calendar: cal).isEmpty)
        // Streak: sent yesterday, the day before and three days ago is not unbroken (two days ago is missing); yesterday alone counts as 1 so far.
        XCTAssertEqual(s.streak, 1, "yesterday only: the gap before it ends the streak, and today has not started")
        let run: [String: [OptOutAttempt]] = ["s0": [OptOutAttempt(date: now, outcome: "submitted")], "s1": [OptOutAttempt(date: now.addingTimeInterval(-86_400), outcome: "submitted")],
                                              "s2": [OptOutAttempt(date: now.addingTimeInterval(-2 * 86_400), outcome: "submitted")]]
        XCTAssertEqual(ActivitySummary.build(entries: entries, attempts: run, now: now, calendar: cal).streak, 3)
        for c in BrokerCategory.allCases { XCTAssertFalse(c.protects.isEmpty) }
    }
}


final class RenewalTests: XCTestCase {
    private func entry(_ id: String, _ kind: String, _ persistence: PersistenceInfo?) -> DirectoryEntry {
        var e = DirectoryEntry(id: id, domain: id + ".com", name: id, bucket: "direct", tier: .B, automation: .guided, signals: [])
        e.about = BrokerAbout(category: kind, summary: "s"); e.persistence = persistence; return e
    }

    func testAnOptOutIsRepeatedAfterSixToTwelveMonthsUnlessItLasts() {
        let cal = Calendar(identifier: .gregorian), now = Date()
        let sent = cal.date(byAdding: .month, value: -7, to: now)!
        let attempts = ["ps": [OptOutAttempt(date: sent, outcome: "submitted")], "ad": [OptOutAttempt(date: sent, outcome: "submitted")],
                        "keep": [OptOutAttempt(date: sent, outcome: "submitted")], "pol": [OptOutAttempt(date: sent, outcome: "submitted")]]
        let people = entry("ps", "people_search", nil)                                              // unknown: people search comes back in 6 months
        let ad = entry("ad", "marketing_data", nil)                                                 // unknown: 12 months
        let keep = entry("keep", "b2b", PersistenceInfo(result: "permanent"))                       // the policy says it lasts
        let pol = entry("pol", "b2b", PersistenceInfo(result: "temporary", reupMonths: 6))          // the policy says repeat
        XCTAssertEqual(people.reupMonths, 6); XCTAssertEqual(ad.reupMonths, 12); XCTAssertNil(keep.reupMonths); XCTAssertEqual(pol.reupMonths, 6)
        XCTAssertTrue(people.isDueToRenew(attempts: attempts, now: now, calendar: cal))
        XCTAssertTrue(ad.isCurrent(attempts: attempts, now: now, calendar: cal), "7 months is inside 12")
        XCTAssertTrue(keep.isCurrent(attempts: attempts, now: now, calendar: cal), "permanent never comes due")
        XCTAssertTrue(pol.isDueToRenew(attempts: attempts, now: now, calendar: cal))
        XCTAssertFalse(people.isCurrent(attempts: [:], now: now, calendar: cal), "never sent")
        // A site that is due is back in the daily queue; one that still holds stays out (yesterday's work is behind us either way).
        let entries = [people, ad, keep, pol]
        let g = DailyGoals.build(queue: entries.map(\.domain), entries: entries, attempts: attempts, now: now, calendar: cal)
        XCTAssertEqual(g.verify, ["ps.com"], "people search ranks first, and only the due one is queued")
        XCTAssertEqual(DailyGoals.build(queue: entries.map(\.domain), entries: entries, attempts: attempts, now: now, chosen: ["b2b"], calendar: cal).verify, ["pol.com"], "the permanent one stays out")
        let s = ActivitySummary.build(entries: entries, attempts: attempts, now: now, calendar: cal)
        XCTAssertEqual(s.dueToRenew, 2)
    }
}


final class FormFillerMoreFieldsTests: XCTestCase {
    private let pat = Person(displayName: "Pat", relationship: .me, names: [NameEntry(kind: .legal, name: "Pat Example")],
                             addresses: [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")], emails: ["pat@example.com"], birthdate: "1980-03-09")
    private func plan(_ f: [(String, String, String)], person: Person? = nil) -> FillPlan {
        FormFiller.plan(for: OptOutForm(page: URL(string: "https://x.example/o")!, method: "post", action: nil, fields: f.map { FormField(type: $0.0, name: $0.1, label: $0.2) }, hops: 1), signals: nil, person: person ?? pat)
    }
    private func v(_ p: FillPlan, _ name: String) -> [String]? { p.values.first { $0.name == name }?.candidates }

    func testAgeBirthPartsTodaysDateAndTheStateOfResidenceAreFilled() {
        let p = plan([("text", "age", "Age*"), ("text", "m", "Birth month *"), ("text", "d", "Day *"), ("text", "y", "Year *"), ("text", "td", "Today's Date"),
                      ("select", "res", "Resident of (required)"), ("text", "first", "First / Middle Name(s) *")])
        XCTAssertEqual(p.verdict, .ready)
        XCTAssertEqual(v(p, "age"), [String(pat.age()!)])
        XCTAssertEqual(v(p, "m")?.first, "3"); XCTAssertTrue(v(p, "m")?.contains("March") ?? false)
        XCTAssertEqual(v(p, "d")?.first, "9"); XCTAssertEqual(v(p, "y"), ["1980"])
        XCTAssertEqual(v(p, "td")?.count, 3, "date in three common formats")
        XCTAssertTrue(v(p, "res")?.contains("IL") ?? false, "Resident of is the state")
        XCTAssertEqual(v(p, "first"), ["Pat"], "First / Middle Name(s) is the first name, not a middle-name field to skip")
    }

    func testAOneBoxAddressAndARelationshipFieldAreFilled() {
        let p = plan([("text", "a", "Street Address, City, State, Zip *"), ("text", "r", "Data subject's relationship with Lob"), ("text", "fn", "First Name"), ("email", "e", "Email")])
        XCTAssertEqual(v(p, "a"), ["1 Main St, Springfield, IL 62701"])
        XCTAssertEqual(v(p, "r"), ["Consumer, no business relationship"])
    }

    func testATypedSignatureIsTheLegalNameAndAFileUploadIsNot() {
        let p = plan([("text", "sig", "* Signature"), ("text", "es", "E-Signature"), ("file", "f", "Select a File"), ("text", "fn", "First Name"), ("email", "e", "Email")])
        XCTAssertEqual(v(p, "sig"), ["Pat Example"]); XCTAssertEqual(v(p, "es"), ["Pat Example"])
        XCTAssertNil(v(p, "f"), "a file is never filled")
    }

    func testASubjectAndAMessageBoxGetThePlainRequestAndABusinessFormIsNotPersonal() {
        let p = plan([("text", "s", "Subject*"), ("textarea", "m", "Message (required)"), ("text", "fn", "First Name"), ("email", "e", "Email")])
        XCTAssertEqual(v(p, "s"), ["Privacy opt-out and deletion request"])
        XCTAssertTrue(v(p, "m")?.first?.contains("resident of Illinois") ?? false)
        XCTAssertTrue(v(p, "m")?.first?.contains("stop selling or sharing") ?? false)
        let biz = plan([("text", "fn", "First Name"), ("email", "e", "Email"), ("text", "c", "Company *"), ("text", "t", "Job Title*")])
        guard case .needsYou(let why) = biz.verdict else { return XCTFail("a company and job title make it a business form") }
        XCTAssertTrue(why.contains("business"))
        // A name prefix menu called "Title" is not a job title.
        XCTAssertEqual(plan([("text", "fn", "First Name"), ("email", "e", "Email"), ("select", "t", "Title")]).verdict, .ready)
        // Age needs a birthdate the profile does not have: asked for, not invented.
        var nobirth = pat; nobirth.birthdate = nil
        if case .needsData(let what) = plan([("text", "age", "Age*"), ("text", "fn", "First Name"), ("email", "e", "Email")], person: nobirth).verdict { XCTAssertFalse(what.isEmpty) } else { XCTFail("needs the birthdate") }
    }
}


final class UnlockLaterNotInTheQueueTests: XCTestCase {
    func testASiteWithNoFormNoEmailAndNoPageIsNeverATaskAndSitesWithRealBlockersAreGuided() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let entries = try Registry.loadDirectory(dir.appendingPathComponent("directory")).filter { $0.closed == nil && $0.excluded == nil }
        let brokers = try Registry.load(directory: dir.appendingPathComponent("brokers"))
        let steps = OptOutPlan.build(entries: entries, brokers: brokers, platforms: [], classifyEntry: { OptOutMethods.classify($0, confirmingIdentity: true) },
                                     classifyBroker: { OptOutMethods.classify($0, in: entries) })
        let planned = Set(steps.flatMap { $0.tasks.flatMap(\.domains) })
        let covered = Set(brokers.flatMap { $0.covers ?? [] })
        let nothing = entries.filter { $0.optOutForm == nil && $0.liveForm?.found != true && $0.contactEmail == nil && $0.optOutURL == nil && $0.family == nil && $0.template == nil && !covered.contains($0.domain) }        // a family or template member is handled by its group
        XCTAssertGreaterThan(nothing.count, 50)
        XCTAssertTrue(nothing.allSatisfy { !planned.contains($0.domain) }, "sites with no route yet must not be tasks: \(nothing.filter { planned.contains($0.domain) }.map(\.domain))")
        XCTAssertTrue(OptOutPlan.locked(steps, entries: entries).contains { nothing.map(\.domain).contains($0.domain) })
        // A live form whose real page asked only a person's business details is guided, not semi-automated.
        let business = entries.filter { $0.liveForm?.found == true && ($0.liveForm?.blockers.contains("business") ?? false) }
        XCTAssertFalse(business.isEmpty)
        XCTAssertTrue(business.allSatisfy { OptOutMethods.classify($0, confirmingIdentity: true).method == .guided })
    }
}


final class CautionTests: XCTestCase {
    func testClearviewIsFlaggedAndNeverAutomated() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let entries = try Registry.loadDirectory(dir.appendingPathComponent("directory"))
        let cv = try XCTUnwrap(entries.first { $0.domain == "clearview.ai" })
        XCTAssertEqual(cv.caution?.kind, "biometric")
        XCTAssertFalse(cv.caution?.sources.isEmpty ?? true)
        XCTAssertEqual(OptOutMethods.classify(cv, confirmingIdentity: true).method, .guided, "a face photo is never uploaded for the person")
        XCTAssertTrue(cv.caution?.summary.contains("never uploads a photo") ?? false)
    }
}


final class LiveFormAutomaticTests: XCTestCase {
    func testALiveFormWithAReviewedConfirmedRunIsAutomaticUnlessAPersonMustClearSomething() {
        var e = DirectoryEntry(id: "x_com", domain: "x.com", name: "X", bucket: "direct", tier: .B, automation: .guided, signals: [])
        e.liveForm = LiveFormCheck(checked: "2026-10-26", found: true, page: "https://x.com/optout", blockers: [])
        XCTAssertEqual(OptOutMethods.classify(e, confirmingIdentity: true).method, .semiAutomatic, "no reviewed run yet")
        e.runCheck = RunCheck(date: "2026-10-26", result: "confirmed", note: "it said thank you")
        XCTAssertEqual(OptOutMethods.classify(e, confirmingIdentity: true).method, .automatic)
        e.liveForm?.blockers = ["check:a bot check"]
        XCTAssertEqual(OptOutMethods.classify(e, confirmingIdentity: true).method, .semiAutomatic, "a bot check on the page keeps it with the person")
        e.liveForm?.blockers = []
        XCTAssertEqual(OptOutMethods.classify(e, confirmingIdentity: true, challengedBefore: true).method, .semiAutomatic)
    }

    func testTheBackgroundRunPicksUpLiveFormSites() async {
        struct Recorder: FormSubmitter {
            func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome { .submitted(awaitingEmail: false) }
        }
        var e = DirectoryEntry(id: "x_com", domain: "x.com", name: "X", bucket: "direct", tier: .B, automation: .guided, signals: [])
        e.liveForm = LiveFormCheck(checked: "2026-10-26", found: true, page: "https://x.com/optout", blockers: [])
        let person = Person(displayName: "Pat", relationship: .me, names: [NameEntry(kind: .legal, name: "Pat Example")], addresses: [Address(street: "1 Main", city: "X", state: "IL", zip: "60601")], emails: ["pat@example.com"])
        let results = await AutoOptOut(submitter: Recorder(), minInterval: 0, spacing: 0).run(entries: [e], person: person, progress: Progress())
        XCTAssertEqual(results.count, 1)
        if case .submitted = results[0].1 {} else { XCTFail("a live-form site is sent by the background run: \(results[0].1)") }
    }
}
