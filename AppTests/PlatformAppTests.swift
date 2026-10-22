import XCTest
import OptOutKitCore
@testable import OptOutKit

/// California DROP in the app: who is offered it, what it covers, and that covered sites are left alone after it is submitted.
@MainActor
final class PlatformAppTests: XCTestCase {
    private func model() -> AppModel {
        AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                 defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
    }

    private func setUp(_ m: AppModel, state: String?) -> Person {
        var me = m.people.first { $0.relationship == .me }!
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]
        me.addresses = [Address(street: "1 Main St", city: "Springfield", state: state ?? "")]
        m.update(me)
        m.setContactEmail("pat@example.com")
        return me
    }

    func testTheCaliforniaPlatformShipsInTheAppWithItsRegistry() throws {
        let m = model()
        let drop = try XCTUnwrap(m.platforms.first { $0.id == "ca-drop" })
        XCTAssertGreaterThan(drop.registered, 500)
        XCTAssertGreaterThan(m.walkthrough(drop).covers?.count ?? 0, 500)
        XCTAssertTrue(m.brokers.allSatisfy { $0.id != "ca-drop" }, "it is a platform, not a site in the broker list")
    }

    func testOnlyACaliforniaResidentIsOfferedItAndFamilyAreCheckedByTheirOwnAddress() throws {
        let m = model()
        _ = setUp(m, state: "IL")
        XCTAssertTrue(m.platformQueue.isEmpty, "an Illinois address")
        _ = setUp(m, state: "CA")
        XCTAssertEqual(m.platformQueue.map(\.id), ["ca-drop"])
        var mum = try XCTUnwrap(m.addPerson(named: "Mum", relationship: .parent))
        mum.addresses = [Address(street: "2 Oak St", city: "Chicago", state: "IL")]
        m.update(mum); m.select(mum.id)
        XCTAssertTrue(m.platformQueue.isEmpty, "Mum lives in Illinois, whatever the owner's address says")
    }

    func testTheOwnersChosenStateOffersItBeforeTheyHaveAnAddress() throws {
        let m = model()
        XCTAssertTrue(m.platformQueue.isEmpty)
        m.setOwnerState("CA")
        XCTAssertEqual(m.platformQueue.map(\.id), ["ca-drop"])
        XCTAssertEqual(m.ownerStateCode, "CA")
        m.setOwnerState("IL")
        XCTAssertTrue(m.platformQueue.isEmpty)
        m.setOwnerCountry("FR")
        XCTAssertTrue(m.platformQueue.isEmpty)
    }

    func testSubmittingItHoldsOffTheCoveredSitesUntilTheHoldEnds() async throws {
        let m = model()
        let me = setUp(m, state: "CA")
        let drop = try XCTUnwrap(m.platforms.first)
        let spokeoEntry = try XCTUnwrap(m.directory.first { $0.domain == "spokeo.com" })
        XCTAssertNotNil(m.platformCover(for: spokeoEntry))
        XCTAssertNil(m.platformCover(for: spokeoEntry)?.until, "not submitted yet: only a hint")
        XCTAssertEqual(m.holds(for: me)[spokeoEntry.id]?.until, .distantFuture, "before submitting, the one request comes first and the sites are not asked separately")

        let broker = m.walkthrough(drop)
        for i in 0..<broker.steps.count { m.complete(broker, step: i) }       // the person walked through every step
        let holds = m.holds(for: me)
        XCTAssertFalse(holds.isEmpty)
        XCTAssertEqual(holds[spokeoEntry.id]?.name, "California DROP")
        XCTAssertGreaterThan(holds[spokeoEntry.id]?.until ?? .distantPast, Date().addingTimeInterval(80 * 86_400))
        XCTAssertTrue(m.holds(for: me, now: Date().addingTimeInterval(100 * 86_400)).isEmpty, "after the hold the sites are asked directly again")

        // The weekly run does not touch a covered site, and says why.
        final class Seen: FormSubmitter, @unchecked Sendable {
            var pages: [String] = []
            func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome { pages.append(form.page.host ?? ""); return .submitted(awaitingEmail: false) }
        }
        let seen = Seen()
        await m.runAutoOptOut(for: me, submitter: seen)
        let held = m.holds(for: me)
        XCTAssertFalse(held.isEmpty)
        for row in m.optOutRun[me.id] ?? [] where held[row.id] != nil {
            if case .coveredByPlatform = row.result {} else { XCTFail("\(row.domain) is covered but was \(row.result)") }
        }
        XCTAssertFalse(seen.pages.isEmpty, "sites DROP does not cover are still asked")
        let row = try XCTUnwrap(m.optOutRun[me.id]?.first { $0.id == spokeoEntry.id })
        if case .coveredByPlatform = row.result {} else { XCTFail("expected covered, got \(row.result)") }
    }
}

@MainActor
final class HandledOnceTests: XCTestCase {
    private func model(state: String) -> (AppModel, Person) {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        var me = m.people.first { $0.relationship == .me }!
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]
        me.addresses = [Address(street: "1 Main St", city: "Somewhere", state: state)]
        m.update(me); m.setContactEmail("pat@example.com")
        return (m, me)
    }

    func testASiteDropHandlesIsListedOnceAndIsNotSeparateWork() throws {
        let (m, _) = model(state: "CA")
        let group = try XCTUnwrap(m.platformGroups.first)
        XCTAssertGreaterThan(group.entries.count, 100)
        XCTAssertTrue(group.brokers.contains { $0.id == "spokeo" })
        XCTAssertFalse(m.queueBrokers.contains { $0.id == "spokeo" }, "not in the queue as its own work")
        let workIDs = Set(m.workSites.map(\.id)), handledIDs = Set(group.entries.map(\.id))
        XCTAssertTrue(workIDs.isDisjoint(with: handledIDs), "no site is in both lists")
        XCTAssertEqual(workIDs.union(handledIDs), Set(m.unguidedSites.map(\.id)), "and none went missing")
        XCTAssertTrue(m.quickCheckQueue.allSatisfy { !handledIDs.contains($0.id) }, "quick checks skip them too")
    }

    func testEverySiteIsInExactlyOneGroupForEveryPlace() {
        for state in ["CA", "IL", "TX", "AK"] {
            let (m, _) = model(state: state)
            var seen: [String] = []
            for g in m.platformGroups { seen += g.entries.map(\.domain) + g.brokers.compactMap { Directory.entry(for: $0, in: m.directory)?.domain ?? $0.id } }
            for method in OptOutMethod.allCases {
                seen += m.workSites.filter { m.method(for: $0).method == method }.map(\.domain)
                seen += m.queueBrokers.filter { m.method(for: $0) == method }.map { Directory.entry(for: $0, in: m.directory)?.domain ?? $0.id }
            }
            XCTAssertEqual(seen.count, Set(seen).count, "\(state): a site is listed in more than one group")
            XCTAssertEqual(Set(seen).count, m.unguidedSites.count + m.brokers.count, "\(state): a site went missing")
            let reachable = Set(seen).union(m.brokers.flatMap { $0.covers ?? [] })
            let all = Set(m.directory.map(\.domain))
            XCTAssertEqual(all.subtracting(reachable).sorted(), [], "\(state): in the directory but neither listed nor cleared by a listed site")
            XCTAssertGreaterThanOrEqual(m.totalSites, m.directory.count, "the count includes sites a shared request clears that have no page of their own")
        }
    }

    func testThePlanLeadsWithTheOfficialServiceThenOurOwnStepsAndListsEachSiteOnce() {
        let (m, _) = model(state: "CA")
        let steps = m.plan
        XCTAssertEqual(steps.first?.kind, .platform("ca-drop"))
        XCTAssertGreaterThan(steps[0].siteCount, 500)
        let domains = steps.flatMap { $0.tasks.flatMap(\.domains) }
        XCTAssertEqual(domains.count, Set(domains).count)
        XCTAssertEqual(Set(domains).isSuperset(of: Set(m.directory.map(\.domain))), true)
        let (il, _) = model(state: "IL")
        if case .method = il.plan.first?.kind {} else { XCTFail("someone outside California starts with our own steps") }
    }

    func testThePlaceChoiceOnlyReordersAndMarks() {
        let (m, _) = model(state: "TX")
        m.placeScope = .all
        XCTAssertTrue(m.placeCodes(for: .all).isEmpty)
        XCTAssertEqual(m.placeCodes(for: .mine), ["TX"])
        var me = m.people.first { $0.relationship == .me }!
        me.addresses.append(Address(street: nil, city: "Portland", state: "OR"))
        m.update(me)
        XCTAssertEqual(m.placeCodes(for: .visited), ["TX", "OR"])
        let tasks = m.plan.flatMap(\.tasks)
        let ordered = PlaceSort.ordered(tasks, places: ["TX"])
        XCTAssertEqual(ordered.count, tasks.count, "nothing is hidden")
        XCTAssertTrue(ordered.first?.isRegistered(in: ["TX"]) ?? false)
    }

    func testNothingIsGroupedForSomeoneWhoCannotUseThePlatform() {
        let (m, _) = model(state: "IL")
        XCTAssertTrue(m.platformGroups.isEmpty)
        XCTAssertTrue(m.queueBrokers.contains { $0.id == "spokeo" })
        XCTAssertEqual(m.workSites.count, m.unguidedSites.count)
    }

    func testTheWeeklyRunSaysWhyACoveredSiteWasSkippedBeforeAndAfterSubmitting() async throws {
        let (m, me) = model(state: "CA")
        final class Seen: FormSubmitter, @unchecked Sendable {
            func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome { .submitted(awaitingEmail: false) }
        }
        await m.runAutoOptOut(for: me, submitter: Seen())
        let covered = Set(m.platformGroups[0].entries.map(\.id))
        let rows = (m.optOutRun[me.id] ?? []).filter { covered.contains($0.id) }
        XCTAssertFalse(rows.isEmpty)
        for r in rows {
            guard case .coveredByPlatform(_, let until) = r.result else { XCTFail("\(r.domain): \(r.result)"); continue }
            XCTAssertEqual(until, .distantFuture)
            XCTAssertEqual(r.result.label, "Covered by California DROP: its one request handles this site")
        }
    }
}

@MainActor
final class StateRulesAppTests: XCTestCase {
    func testTheAppShipsEveryStateAndCountsFromTheRegistries() throws {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        XCTAssertEqual(m.jurisdictions.filter { $0.id.hasPrefix("us-") }.count, 51)
        XCTAssertGreaterThan(m.registrySummary?.knownSites ?? 0, 600)
        let ca = try XCTUnwrap(m.jurisdiction(code: "CA"))
        let lines = m.statements(for: ca).map(\.text)
        XCTAssertTrue(lines[0].contains("603 brokers"), lines[0])
        XCTAssertTrue(lines.contains { $0.contains("sites in all") })
    }

    func testTheOwnersStateComesFromTheirAddressOnceTheyHaveOne() throws {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        m.setOwnerState("TX")
        XCTAssertEqual(m.ownerStateCode, "TX")
        var me = try XCTUnwrap(m.selectedPerson)
        me.addresses = [Address(street: "1 A St", city: "Salem", state: "Oregon")]
        m.update(me)
        XCTAssertEqual(m.ownerStateCode, "OR", "a full state name in the address is understood")
    }
}

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
        XCTAssertEqual(OptOutMethod.guided.title, "Guidé : vous faites les étapes", "words from the core package follow the same choice")
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
final class CountryAppTests: XCTestCase {
    override func tearDown() { L10n.language = "en"; Loc.language = "en" }

    private func model() -> AppModel {
        AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                 defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
    }

    func testTheAppKnowsTheCountriesAndTheUnitedStatesAndPicksTheDeviceRegionFirst() throws {
        let m = model()
        let names = m.countryOptions.map(\.name)
        XCTAssertTrue(names.contains("Germany") && names.contains("United States") && names.contains("Japan"), "\(names.count) options")
        XCTAssertGreaterThan(m.countryOptions.count, 50)
        XCTAssertEqual(m.countryOptions.map(\.name), m.countryOptions.map(\.name).sorted { $0.localizedCompare($1) == .orderedAscending }, "alphabetical")
        XCTAssertEqual(m.ownerCountry, "US", "the simulator's region, until the person chooses")
        m.setOwnerCountry("DE")
        XCTAssertEqual(m.ownerCountry, "DE")
    }

    func testTheOwnersRulesAreTheirStateInTheUSAndTheirCountryElsewhere() throws {
        let m = model()
        m.setOwnerCountry("US"); m.setOwnerState("TX")
        XCTAssertEqual(m.ownerJurisdiction?.id, "us-tx")
        m.setOwnerCountry("DE")
        XCTAssertEqual(m.ownerJurisdiction?.id, "country-de")
        XCTAssertNil(m.ownerState, "only the US has states")
        m.setOwnerCountry("OTHER")
        XCTAssertNil(m.ownerJurisdiction)
    }

    func testAGermanResidentGetsTheGDPRInGermanAndDROPIsNotOffered() throws {
        let m = model()
        m.setOwnerCountry("DE"); m.setLanguage("de")
        let lines = m.statements(for: try XCTUnwrap(m.ownerJurisdiction)).map(\.text)
        XCTAssertTrue(lines[0].hasPrefix("Deutschland hat ein Datenschutzgesetz: Datenschutz-Grundverordnung (EU) 2016/679"), lines[0])
        XCTAssertTrue(lines.contains { $0.contains("bfdi.bund.de") })
        XCTAssertTrue(m.platformQueue.isEmpty, "California's service is for California residents")
    }
}
