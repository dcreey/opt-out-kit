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
        var p = Progress()
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
        for r: Relationship in [.parent, .sibling, .cousin, .friend] { XCTAssertTrue(Relationship.allCases.contains(r)) }
        XCTAssertEqual(Relationship.me.label, "Me")
        XCTAssertEqual(Relationship.auntUncle.label, "Aunt or uncle")
    }

    func testNoGenderSpecificDuplicates() {
        let labels = Relationship.allCases.map(\.rawValue)
        for banned in ["mother", "father", "sister", "brother", "son", "daughter"] {
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
        XCTAssertEqual(h.summary(for: b), .complete)
    }

    func testSingleProfileNeverReadsAsPartial() {
        let b = broker(1)
        var h = Household()
        let a = Person(displayName: "A")
        h.add(a)
        h.mutateProgress(for: a.id) { $0.complete(b, step: 0) }
        XCTAssertEqual(h.summary(for: b), .complete)
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
