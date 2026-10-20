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
        me.addresses = [Address(city: "Springfield", state: "IL", fromYear: 2015)]
        first.update(me)

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
        let before = try Data(contentsOf: url)

        let locked = makeModel(url: url, keys: FixedKey())   // different key: cannot decrypt
        XCTAssertNotNil(locked.storageProblem)
        locked.addPerson(named: "Dad")                       // must not write over the original
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
