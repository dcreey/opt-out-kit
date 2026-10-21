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
