import XCTest
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
