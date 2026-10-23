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
        me.addresses = [Address(street: "1 Main St", city: "Springfield", state: state ?? "", zip: "62701")]
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
        mum.addresses = [Address(street: "2 Oak St", city: "Chicago", state: "IL", zip: "62701")]
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
        await m.runAutoOptOut(for: me, automaticOnly: false, submitter: seen)
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
        me.addresses = [Address(street: "1 Main St", city: "Somewhere", state: state, zip: "62701")]
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

    func testTheQueueIsRankedByWhereThePersonLivesAndHasLivedAndHidesNothing() {
        let (m, _) = model(state: "TX")
        XCTAssertEqual(m.localStates, ["TX"])
        var me = m.people.first { $0.relationship == .me }!
        me.addresses.append(Address(street: nil, city: "Portland", state: "OR"))
        m.update(me)
        XCTAssertEqual(m.localStates, ["TX", "OR"])
        XCTAssertTrue(m.countryHasRegistries)
        let queue = m.queue
        XCTAssertEqual(queue.map(\.rank), queue.map(\.rank).sorted())
        XCTAssertEqual(queue.first?.rank, .ourAutomatic, "no official service in Texas, so the app's own run leads")
        XCTAssertEqual(queue.flatMap(\.tasks).count, m.plan.flatMap(\.tasks).count, "nothing is hidden")
        let (ca, _) = model(state: "CA")
        XCTAssertEqual(ca.queue.first?.rank, .localOfficial)
        XCTAssertEqual(ca.queue.dropFirst().first?.rank, .ourAutomatic)
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
        await m.runAutoOptOut(for: me, automaticOnly: false, submitter: Seen())
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
final class ProfileGateAppTests: XCTestCase {
    private func model() -> AppModel {
        AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                 defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
    }

    func testNothingRunsUntilTheCurrentAddressIsInThenItRunsOnItsOwn() {
        let m = model()
        var ran = 0
        m.requireProfile { ran += 1 }
        XCTAssertEqual(ran, 0, "no name, address or email yet")
        XCTAssertTrue(m.showProfileGate)
        XCTAssertNil(m.guidedRunner(for: m.brokers[0]))
        XCTAssertTrue(m.assistedItems(for: m.selectedPerson!).isEmpty)
        var me = m.people.first { $0.relationship == .me }!
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]
        me.addresses = [Address(street: "1 Main St", city: "Somewhere", state: "IL", zip: "62701")]
        m.update(me); m.setContactEmail("pat@example.com")
        m.profileGateFinished(completed: true)
        XCTAssertEqual(ran, 1, "carries on with what the person was doing")
        XCTAssertFalse(m.showProfileGate)
        m.requireProfile { ran += 1 }
        XCTAssertEqual(ran, 2, "once complete there is no gate")
    }

    func testCancellingTheGateRunsNothing() {
        let m = model()
        var ran = false
        m.requireProfile { ran = true }
        m.profileGateFinished(completed: false)
        XCTAssertFalse(ran); XCTAssertFalse(m.showProfileGate)
    }
}

@MainActor
final class AutomaticRunAppTests: XCTestCase {
    func testTheRunWorksThroughExactlyTheSitesTheAutomaticTaskShows() async throws {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        var me = m.people.first { $0.relationship == .me }!
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]
        me.addresses = [Address(street: "1 Main St", city: "Somewhere", state: "IL", zip: "62701")]
        m.update(me); m.setContactEmail("pat@example.com")
        final class Seen: FormSubmitter, @unchecked Sendable {
            func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome { .submitted(awaitingEmail: false) }
        }
        let shown = m.automaticDomains(for: me)
        XCTAssertFalse(shown.isEmpty)
        let task = try XCTUnwrap(m.plan.flatMap(\.tasks).first { $0.kind == .automatic })
        XCTAssertEqual(Set(task.domains), shown, "the count on the task is the set the run works through")
        await m.runAutoOptOut(for: me, submitter: Seen())
        let ran = Set((m.optOutRun[me.id] ?? []).map(\.domain))
        XCTAssertFalse(ran.isEmpty)
        XCTAssertTrue(ran.isSubset(of: shown), "no semi-automated or guided site is sent in the background: \(ran.subtracting(shown).sorted().prefix(5))")
        XCTAssertLessThan(ran.count, m.directory.filter { $0.optOutForm != nil }.count)
    }

    func testASiteThatFailedAutomaticallyMovesToAGuideAndACheckToSemiAutomated() {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        guard let entry = m.directory.first(where: { m.method(for: $0).method == .automatic }) else { return XCTFail("no automatic site") }
        for (outcome, expected) in [("failed", OptOutMethod.guided), ("rejected", .guided), ("challenged", .semiAutomatic)] {
            m.resetProgressForTesting()
            m.recordAttemptForTesting(OptOutAttempt(date: Date(), outcome: outcome, detail: "x"), site: entry.id)
            XCTAssertEqual(m.method(for: entry).method, expected, outcome)
        }
    }
}

final class RunReportTests: XCTestCase {
    private func row(_ id: String, _ r: AutoOptOutResult) -> AppModel.AutoOptOutRow { .init(id: id, domain: "\(id).com", result: r) }

    func testAnAllSentRunIsAllSucceededAndAMixedOneListsWhatNeedsThePerson() {
        let ok = RunReport(person: "Me", rows: [row("a", .submitted(awaitingEmail: false)), row("b", .submitted(awaitingEmail: true)), row("c", .tooSoon(until: Date()))])
        XCTAssertTrue(ok.allSucceeded); XCTAssertEqual(ok.sent, 2); XCTAssertEqual(ok.attempted, 2, "a site skipped as recently sent was not tried")
        let mixed = RunReport(person: "Me", rows: [row("a", .submitted(awaitingEmail: false)), row("b", .failed("no confirmation")), row("c", .challenged("bot check")), row("d", .skippedNotListed)])
        XCTAssertFalse(mixed.allSucceeded)
        XCTAssertEqual(mixed.attempted, 3); XCTAssertEqual(mixed.sent, 1)
        XCTAssertEqual(mixed.needYou.map(\.id), ["b", "c"])
        XCTAssertFalse(RunReport(person: "Me", rows: []).allSucceeded, "nothing tried is not a success")
    }
}

@MainActor
final class RunReviewAppTests: XCTestCase {
    func testEachSiteSentKeepsAScreenshotThePersonCanReviewAndRejectIt() async throws {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        var me = m.people.first { $0.relationship == .me }!
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]
        me.addresses = [Address(street: "1 Main St", city: "Somewhere", state: "IL", zip: "62701")]
        m.update(me); m.setContactEmail("pat@example.com")
        struct Shot: FormSubmitter {
            func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome { .submitted(awaitingEmail: false) }
            func submitCapturing(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitEvidence {
                SubmitEvidence(outcome: .submitted(awaitingEmail: false), screenshot: Data([1, 2, 3, 4]))
            }
        }
        await m.runAutoOptOut(for: me, submitter: Shot())
        let items = m.reviewItems(for: me)
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { $0.hasScreenshot && $0.worked })
        let first = try XCTUnwrap(items.first)
        XCTAssertEqual(m.screenshot(for: first, person: me), Data([1, 2, 3, 4]))
        let entry = try XCTUnwrap(m.directory.first { $0.id == first.id })
        m.markLooksWrong(first, for: me)
        XCTAssertEqual(m.method(for: entry).method, .guided, "a site the person says did not finish moves to a guide")
        XCTAssertFalse(m.reviewItems(for: me).first { $0.id == first.id }?.worked ?? true)
    }
}

@MainActor
final class CoachGuideAppTests: XCTestCase {
    func testAGuideIsShownOnceAndOnlyForTasksAPersonTakesPartIn() {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        XCTAssertTrue(m.shouldCoach("sites"))
        m.didCoach("sites")
        XCTAssertFalse(m.shouldCoach("sites"))
        XCTAssertTrue(m.shouldCoach("semi"), "each kind of screen has its own guide")
        m.resetCoaching()
        XCTAssertTrue(m.shouldCoach("sites"))
        XCTAssertNil(CoachGuide.forMethod(.automatic))
        XCTAssertEqual(CoachGuide.forMethod(.semiAutomatic)?.id, "semi")
        XCTAssertEqual(CoachGuide.forMethod(.guided)?.id, "manual")
        XCTAssertEqual(CoachGuide.forMethod(.manual)?.id, "manual")
        XCTAssertTrue(Set(CoachGuide.allIDs).isSuperset(of: ["sites", "semi", "manual"]))
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
        me.addresses = [Address(street: "1 A St", city: "Salem", state: "Oregon", zip: "62701")]
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
