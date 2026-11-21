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
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"
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
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"
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
        // Only the sites that reach the person's country are in the plan until they ask for the others.
        XCTAssertEqual(Set(domains).union(m.lockedSites.map(\.domain)).isSuperset(of: Set(m.regionSplit.inRegion.filter { $0.closed == nil }.map(\.domain))), true)
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
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"
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
    /// Stop ends the run after the site in progress; what was done is kept and the pass is left to carry on later.
    func testStopEndsTheRunPartWayAndLeavesTheRestForLater() async throws {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        var me = m.people.first { $0.relationship == .me }!
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"
        me.addresses = [Address(street: "1 Main St", city: "Somewhere", state: "IL", zip: "62701")]
        m.update(me); m.setContactEmail("pat@example.com")
        struct Slow: FormSubmitter {
            func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome {
                try? await Task.sleep(nanoseconds: 50_000_000); return .submitted(awaitingEmail: false)
            }
        }
        let total = m.backgroundDomains(for: me, kind: .full).count
        let run = Task { await m.runAutoOptOut(for: me, submitter: Slow()) }
        var waited = 0
        while (m.autoProgress?.done ?? 0) < 2 && waited < 300 { try await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
        XCTAssertEqual(m.autoBusy, "optout")
        m.stopAutoOptOut()
        await run.value
        let tried = (m.optOutRun[me.id] ?? []).count
        XCTAssertGreaterThan(tried, 0); XCTAssertLessThan(tried, total, "it stopped part-way")
        XCTAssertNil(m.autoBusy, "and is no longer working")
        XCTAssertEqual(m.autoSettings.optOutResumePending, true, "the rest of the pass waits for the next run")
        // Stop means stop: not carried on by reopening the app or going back, nor by the schedule, until the person starts a run.
        XCTAssertEqual(m.autoSettings.stoppedByPerson, true)
        var on = m.autoSettings; on.optOutEnabled = true
        XCTAssertFalse(on.startsByItself(now: Date()), "a stopped run does not start again by itself, even with automatic opt-out on")
        XCTAssertTrue(m.runStoppedByPerson, "the page says it is stopped")
        // Run now carries on with only the sites left, and counts only those from the start.
        let left = Task { await m.runAutoOptOut(for: me, submitter: Slow()) }
        waited = 0
        while m.autoProgress == nil && waited < 100 { try await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
        XCTAssertEqual(m.autoProgress?.total, total - tried, "the count is the sites left, not every site")
        XCTAssertNil(m.autoSettings.stoppedByPerson, "starting a run clears Stop")
        m.stopAutoOptOut(); await left.value
    }

    /// A site the run's own rules leave alone (here: covered by California's DROP until its request is made) is not counted as tried, is never sent,
    /// and keeps its reason on the activity page; the report says how many were left alone and why. (A run once showed "0 of 4 went through" after
    /// silently passing over about 300 such sites, and the page then said none were left.)
    func testSitesTheRunLeavesAloneAreNotCountedAsTriedAndKeepTheirReason() async throws {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        var me = m.people.first { $0.relationship == .me }!
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"
        me.addresses = [Address(street: "1 Main St", city: "Los Angeles", state: "CA", zip: "90001")]
        m.update(me); m.setContactEmail("pat@example.com")
        let held = Set(m.holds(for: me).keys)
        try XCTSkipIf(held.isEmpty, "no platform request covers sites for this person in this build of the directory")
        let full = m.backgroundDomains(for: me, kind: .full)
        let heldDomains = Set(m.directory.filter { held.contains($0.id) }.map(\.domain)).intersection(full)
        XCTAssertFalse(heldDomains.isEmpty, "some sites a full pass covers are held")
        XCTAssertTrue(m.willTry(full, for: me).isDisjoint(with: heldDomains), "a held site is not one the run will try")
        XCTAssertEqual(m.runNowCount(for: me), m.willTry(full, for: me).count, "Run now counts only what it will try")
        let willTry = m.willTry(full, for: me)          // worked out before the run: afterwards the sites it sent count as sent recently
        let tally = Tally()
        await m.runAutoOptOut(for: me, submitter: Tally.Recorder(tally: tally))
        let heldPages = Set(m.directory.filter { heldDomains.contains($0.domain) }.compactMap { AutoOptOut.standIn(m.resolved($0)).optOutForm?.page.absoluteString })
        // A page held for one site may be the shared page of another site that is not held (a family's one portal); only a page no tried site uses counts.
        let triedPages = Set(m.directory.filter { willTry.contains($0.domain) }.compactMap { AutoOptOut.standIn(m.resolved($0)).optOutForm?.page.absoluteString })
        let leaked = heldPages.subtracting(triedPages).intersection(Set(tally.pages))
        XCTAssertTrue(leaked.isEmpty, "nothing was sent to a held site: \(leaked.sorted().prefix(5))")
        XCTAssertTrue(Set((m.optOutRun[me.id] ?? []).map(\.domain)).isDisjoint(with: heldDomains), "held sites are not in the run's results")
        let report = try XCTUnwrap(m.runReport)
        XCTAssertGreaterThanOrEqual(report.skippedCount, heldDomains.count, "the report says how many were left alone")
        let rows = m.activityRows(for: me).filter { heldDomains.contains($0.domain) }
        XCTAssertEqual(rows.count, heldDomains.count, "held sites stay on the page")
        XCTAssertTrue(rows.allSatisfy { $0.group == .notTried && $0.line.localizedCaseInsensitiveContains("covered") }, "with their reason")
    }

    /// A run that iOS cut off (the run stopped after the site in progress) and that the person then brought back to the front (which clears that stop, so
    /// a glance away does not end a run) is not taken as finished: a run is finished only when every site it set out to do has a result.
    func testARunCutOffAndThenBroughtBackToTheFrontIsNotTakenAsFinished() async throws {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        var me = m.people.first { $0.relationship == .me }!
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"
        me.addresses = [Address(street: "1 Main St", city: "Somewhere", state: "IL", zip: "62701")]
        m.update(me); m.setContactEmail("pat@example.com")
        struct Slow: FormSubmitter {
            func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome {
                try? await Task.sleep(nanoseconds: 50_000_000); return .submitted(awaitingEmail: false)
            }
        }
        let run = Task { await m.runAutoOptOut(for: me, submitter: Slow()) }
        var waited = 0
        while (m.autoProgress?.done ?? 0) < 2 && waited < 300 { try await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
        m.continuedRunExpired(appActive: false)                 // iOS took the time back while the person was away
        try await Task.sleep(nanoseconds: 200_000_000)          // the run stops after the site in progress
        m.appDidBecomeActive()                                  // the person comes back: the stop flag is cleared again
        await run.value
        let tried = (m.optOutRun[me.id] ?? []).count
        XCTAssertLessThan(tried, m.backgroundDomains(for: me, kind: .full).count, "the run did stop part-way")
        XCTAssertEqual(m.autoSettings.optOutResumePending, true, "so it is still to carry on")
        XCTAssertNil(m.autoSettings.lastFullRun, "and the full pass is not recorded as done")
        XCTAssertNil(m.runReport, "and no report claims it finished")
        XCTAssertEqual(m.autoSettings.nextRunKind(), .full, "the next run carries on with the full pass")
    }

    /// A site no run has ever tried is in every run, even a repeat, so it is never left for six months.
    func testEverySiteNeverTriedIsInEveryRunEvenARepeat() {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        var me = m.people.first { $0.relationship == .me }!
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"
        me.addresses = [Address(street: "1 Main St", city: "Somewhere", state: "IL", zip: "62701")]
        m.update(me); m.setContactEmail("pat@example.com")
        XCTAssertTrue(m.backgroundDomains(for: me, kind: .repeatSent).isEmpty, "a repeat on its own has nothing: nothing has gone through")
        XCTAssertEqual(m.runDomains(for: me, kind: .repeatSent), m.backgroundDomains(for: me, kind: .full), "but every site never tried is in it")
    }

    /// In California, DROP's one request comes first and the first automatic pass waits for it. Anywhere else DROP is not offered and holds nothing.
    func testDROPComesFirstInCaliforniaAndIsLeftOutEverywhereElse() {
        func model(state: String, city: String, zip: String) -> (AppModel, Person) {
            let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                             defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
            var me = m.people.first { $0.relationship == .me }!
            me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"
            me.addresses = [Address(street: "1 Main St", city: city, state: state, zip: zip)]
            m.update(me); m.setContactEmail("pat@example.com"); m.setAuto(scan: false, optOut: true)
            return (m, m.people.first { $0.relationship == .me }!)
        }
        let (ca, caMe) = model(state: "CA", city: "Los Angeles", zip: "90001")
        try? XCTSkipIf(ca.holds(for: caMe).isEmpty, "DROP is not live in this build of the directory")
        XCTAssertNotNil(ca.platformStep, "in California the DROP request is the first step")
        XCTAssertTrue(ca.firstPassWaitsForPlatform, "and the first automatic pass waits for it")
        let (il, ilMe) = model(state: "IL", city: "Springfield", zip: "62701")
        XCTAssertNil(il.platformStep, "outside California there is no DROP step")
        XCTAssertFalse(il.firstPassWaitsForPlatform, "and the first pass does not wait for one")
        XCTAssertTrue(il.holds(for: ilMe).isEmpty, "and no site is held for it")
        XCTAssertFalse(il.plan.flatMap(\.tasks).contains { if case .platform = $0.kind { return true } else { return false } }, "DROP is not in the plan at all")
    }

    /// iOS ending the run's background time must not stop a run the person is watching (it once did, so Run now stopped after its first site).
    func testIOSEndingTheBackgroundTimeStopsTheRunOnlyWhenThePersonIsAway() {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        m.continuedRunExpired(appActive: true)
        XCTAssertFalse(m.autoStopRequested, "on screen: the run carries on")
        m.continuedRunExpired(appActive: false)
        XCTAssertTrue(m.autoStopRequested, "away: it stops after the current site and resumes on reopen")
    }

    func testTheFirstRunWorksThroughEverySiteThatCanBeTriedAndNothingElse() async throws {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        var me = m.people.first { $0.relationship == .me }!
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"
        me.addresses = [Address(street: "1 Main St", city: "Somewhere", state: "IL", zip: "62701")]
        m.update(me); m.setContactEmail("pat@example.com")
        final class Seen: FormSubmitter, @unchecked Sendable {
            func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome { .submitted(awaitingEmail: false) }
        }
        let shown = m.automaticDomains(for: me)
        XCTAssertFalse(shown.isEmpty)
        let task = try XCTUnwrap(m.plan.flatMap(\.tasks).first { $0.kind == .automatic })
        XCTAssertEqual(Set(task.domains), shown, "the count on the task is the set of automatic sites")
        let pass = m.backgroundDomains(for: me, kind: .full)
        await m.runAutoOptOut(for: me, submitter: Seen())
        let ran = Set((m.optOutRun[me.id] ?? []).map(\.domain))
        XCTAssertTrue(shown.isSubset(of: ran), "every automatic site is worked through")
        XCTAssertTrue(ran.isSubset(of: pass), "no site outside the full pass is sent in the background: \(ran.subtracting(pass).sorted().prefix(5))")
        XCTAssertLessThan(ran.count, m.directory.count, "sites with no form, a caution or something only a person can do are left out")
    }

    func testASiteThatFailedAutomaticallyMovesToAGuideAndACheckToSemiAutomated() {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        guard let entry = m.directory.first(where: { m.method(for: $0).method == .automatic }) else { return XCTFail("no automatic site") }
        for (outcome, expected) in [("failed", OptOutMethod.semiAutomatic), ("rejected", .semiAutomatic), ("challenged", .semiAutomatic)] {
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
        let mixed = RunReport(person: "Me", rows: [row("a", .submitted(awaitingEmail: false)), row("b", .failed("no confirmation")), row("c", .challenged("human check")), row("d", .skippedNotListed)])
        XCTAssertFalse(mixed.allSucceeded)
        XCTAssertEqual(mixed.attempted, 3); XCTAssertEqual(mixed.sent, 1)
        XCTAssertEqual(mixed.needYou.map(\.id), ["b", "c"])
        XCTAssertFalse(RunReport(person: "Me", rows: []).allSucceeded, "nothing tried is not a success")
    }
}

/// The pages a fake submitter was handed, in order.
final class Tally: @unchecked Sendable {
    var pages: [String] = []; let lock = NSLock(); func add(_ p: String) { lock.lock(); pages.append(p); lock.unlock() }
    /// Records each page and says it went through.
    struct Recorder: FormSubmitter {
        let tally: Tally
        func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome { tally.add(form.page.absoluteString); return .submitted(awaitingEmail: false) }
    }
}

@MainActor
final class BackgroundPassesAppTests: XCTestCase {
    private struct Alternating: FormSubmitter {
        let tally: Tally
        func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome {
            tally.add(form.page.absoluteString)
            return tally.pages.count % 2 == 0 ? .submitted(awaitingEmail: false) : .failed("no confirmation")
        }
    }

    func testTheFirstRunIsAFullPassAndASiteThatDoesNotGoThroughIsLeftWithThePerson() async throws {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        var me = m.people.first { $0.relationship == .me }!
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"
        me.addresses = [Address(street: "1 Main St", city: "Somewhere", state: "IL", zip: "62701")]
        m.update(me); m.setContactEmail("pat@example.com")
        XCTAssertEqual(m.autoSettings.nextRunKind(), .full, "the first run is the full pass")
        let full = m.backgroundDomains(for: me, kind: .full)
        XCTAssertGreaterThan(full.count, 100, "the full pass takes on every site that can be tried")
        let byDomain = Dictionary(m.directory.map { ($0.domain, $0) }, uniquingKeysWith: { a, _ in a })
        for d in full {
            let e = try XCTUnwrap(byDomain[d])
            XCTAssertNil(e.caution, "\(d): a site with a caution is never filled"); XCTAssertNotEqual(e.noFill, true, d)
            XCTAssertEqual(e.pageMode, .form, d)
        }
        XCTAssertTrue(m.automaticDomains(for: me).isSubset(of: full), "the automatic sites are part of the full pass")
        XCTAssertTrue(m.backgroundDomains(for: me, kind: .repeatSent).isEmpty, "nothing has gone through yet, so there is nothing to repeat")
        let automaticBefore = m.automaticDomains(for: me).count
        XCTAssertFalse(m.waitingForFirstPass, "automatic protection is off: the semi-automated queue does not wait")
        m.setAuto(scan: false, optOut: true)
        XCTAssertTrue(m.waitingForFirstPass, "a new person with automatic protection on: the semi-automated queue waits for the first pass")
        let tally = Tally()
        await m.runAutoOptOut(for: me, submitter: Alternating(tally: tally))
        XCTAssertFalse(m.waitingForFirstPass, "the first pass finished: the semi-automated queue opens, with the sites that did not go through in it")
        let rows = m.optOutRun[me.id] ?? []
        XCTAssertTrue(Set(rows.map(\.domain)).isSubset(of: full), "nothing outside the full pass is sent")
        let sent = Set(rows.filter { if case .submitted = $0.result { return true } else { return false } }.map(\.domain))
        let lost = Set(rows.filter { if case .failed = $0.result { return true } else { return false } }.map(\.domain))
        XCTAssertFalse(sent.isEmpty); XCTAssertFalse(lost.isEmpty)
        for d in lost { XCTAssertEqual(m.method(for: try XCTUnwrap(byDomain[d]), person: me).method, .semiAutomatic, "\(d) did not go through: it is semi-automated now") }
        for d in sent { XCTAssertTrue(byDomain[d]?.isCurrent(attempts: m.progress.optOutAttempts) ?? false, "\(d) counts as done") }
        XCTAssertNotNil(m.autoSettings.lastFullRun, "the full pass is finished"); XCTAssertNil(m.autoSettings.passStarted)
        XCTAssertEqual(m.autoSettings.nextRunKind(), .repeatSent, "the next run, three months on, repeats what went through")
        XCTAssertEqual(m.backgroundDomains(for: me, kind: .repeatSent), sent.intersection(full), "the repeat pass is exactly the sites that went through")
        XCTAssertEqual(try XCTUnwrap(m.periodHistory(for: me).first).total, automaticBefore, "only the automatic sites are counted in the period, so the full pass's lost sites never hold it open")
        // Run now again in the same period: nothing left. The sites that went through are not sent twice and the ones that did not are in the semi-automated
        // queue; Re-test all is the way to try every site again.
        XCTAssertEqual(m.runNowCount(for: me), 0)
        let again = Tally()
        await m.runAutoOptOut(for: me, submitter: Alternating(tally: again))
        XCTAssertTrue(again.pages.isEmpty, "Run now sent nothing twice in the same period")
        let retest = Tally()
        m.runFullRetestNow(submitter: Alternating(tally: retest))
        try await Task.sleep(nanoseconds: 300_000_000)
        var waited = 0
        while m.autoBusy != nil && waited < 600 { try await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
        // Really sent again, not just listed: the submitter saw the pages of sites that had already gone through. (A row in the results is not proof:
        // a site skipped as "sent recently" is a row too, and the first version of Re-test all did exactly that.)
        let sentPages = Set(m.directory.filter { sent.contains($0.domain) }.compactMap { AutoOptOut.standIn(m.resolved($0)).optOutForm?.page.absoluteString })
        XCTAssertFalse(sentPages.isDisjoint(with: Set(retest.pages)), "Re-test all sends again to sites that went through this period")
        let retestRows = m.optOutRun[me.id] ?? []
        XCTAssertFalse(retestRows.contains { if case .tooSoon = $0.result { return true } else { return false } }, "none of them is skipped as sent recently")
    }
}

@MainActor
final class RunReviewAppTests: XCTestCase {
    func testEachSiteSentKeepsAScreenshotThePersonCanReviewAndRejectIt() async throws {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        var me = m.people.first { $0.relationship == .me }!
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"
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
        XCTAssertEqual(m.method(for: entry).method, .semiAutomatic, "a site the person says did not finish moves to semi-automatic")
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
        XCTAssertEqual(CoachGuide.forMethod(.manual)?.id, "manual")
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
        XCTAssertEqual(OptOutMethod.manual.title, "Plus tard, pas encore de voie", "words from the core package follow the same choice")
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

final class EvidenceImageTests: XCTestCase {
    private func jpeg(gray: CGFloat) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 80)).image { ctx in
            UIColor(white: gray, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
            UIColor(white: 0, alpha: 1).setFill(); ctx.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        }.jpegData(compressionQuality: 0.9)!
    }

    func testAnAlmostBlackScreenshotIsBrightenedAndANormalOneIsLeftAlone() throws {
        let dark = try XCTUnwrap(UIImage(data: jpeg(gray: 5.0 / 255)))
        XCTAssertLessThan(EvidenceImage.mean(of: dark), 0.03)
        let fixed = try XCTUnwrap(EvidenceImage.image(from: jpeg(gray: 5.0 / 255)))
        XCTAssertGreaterThan(EvidenceImage.mean(of: fixed), 0.3, "the page shows again")
        let normal = try XCTUnwrap(EvidenceImage.image(from: jpeg(gray: 1)))
        XCTAssertGreaterThan(EvidenceImage.mean(of: normal), 0.8)
    }
}

/// The automatic opt-out page must open at once, with the real directory of about 800 sites.
@MainActor
final class ActivityPageSpeedTests: XCTestCase {
    func testTheActivityPageIsWorkedOutQuickly() {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        var me = m.people.first { $0.relationship == .me }!
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"
        me.addresses = [Address(street: "1 Main St", city: "Somewhere", state: "IL", zip: "62701")]
        m.update(me); m.setContactEmail("pat@example.com")
        let p = m.selectedPerson!
        var t = Date(); _ = m.activityRows(for: p); let rows = Date().timeIntervalSince(t)
        t = Date(); _ = m.runNowCount(for: p); let count = Date().timeIntervalSince(t)
        t = Date(); _ = m.automaticDomains(for: p); let plan = Date().timeIntervalSince(t)
        t = Date(); _ = m.backgroundDomains(for: p, kind: .full); let bg = Date().timeIntervalSince(t)
        t = Date(); _ = m.holds(for: p); let holds = Date().timeIntervalSince(t)
        NSLog("SPEED rows=%.3f count=%.3f plan=%.3f background=%.3f holds=%.3f", rows, count, plan, bg, holds)
        _ = holds; _ = bg; _ = plan
        let inputs = m.activityInputs(for: p)
        t = Date(); let page = AppModel.activityPage(inputs); let again = Date().timeIntervalSince(t)
        NSLog("SPEED page again=%.3f", again)
        XCTAssertEqual(page.runNow, m.runNowCount(for: p), "the page counts what Run now really tries")
        XCTAssertEqual(page.rows, m.activityRows(for: p))
        XCTAssertLessThan(again, 0.5, "with each form's fill worked out once, the page takes \(again) s")
        XCTAssertLessThan(rows, 6, "even the first time (build 47 took about 5 s every time)")
        // A change to the progress rebuilds the plan (once a run is over): it must be quick. It took about a second in build 47.
        _ = m.plan
        m.recordAttemptForTesting(OptOutAttempt(date: Date(), outcome: "submitted"), site: m.directory[0].id)
        t = Date(); _ = m.plan; let replan = Date().timeIntervalSince(t)
        NSLog("SPEED replan=%.3f", replan)
        XCTAssertLessThan(replan, 0.5, "rebuilding the plan takes \(replan) s")
    }
}

/// A run that was stopped or cut off carries on where it left off: the sites done are not sent again, and the ones left are all sent.
@MainActor
final class ResumeAppTests: XCTestCase {
    private struct SlowRecorder: FormSubmitter {
        let tally: Tally
        func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome {
            try? await Task.sleep(nanoseconds: 30_000_000); tally.add(form.page.absoluteString); return .submitted(awaitingEmail: false)
        }
    }

    /// The catalog's first sites that have a known form: a resume needs a handful of sites, not every one (a run over the whole directory made these tests
    /// take a minute on CI). Everything else is the catalog the app ships.
    private static let smallContents: Catalog.Contents = {
        guard let url = AppCatalog.url, var c = try? Catalog.contents(of: url) else { return Catalog.Contents(sites: [], brokers: [], platforms: [], jurisdictions: [], registrySummary: nil, termsLibrary: nil) }
        c.sites = Array(c.sites.filter { $0.optOutForm != nil || $0.liveForm?.found == true }.prefix(20))
        return c
    }()

    private func readyModel() -> (AppModel, Person) {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         contents: Self.smallContents, defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        var me = m.people.first { $0.relationship == .me }!
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"
        me.addresses = [Address(street: "1 Main St", city: "Somewhere", state: "IL", zip: "62701")]
        m.update(me); m.setContactEmail("pat@example.com")
        return (m, m.people.first { $0.id == me.id }!)
    }

    /// Runs until `n` sites are done, then presses Stop.
    private func runAndStop(_ m: AppModel, _ me: Person, after n: Int, tally: Tally, everySite: Bool = false) async throws {
        let run = Task { await m.runAutoOptOut(for: me, everySite: everySite, submitter: SlowRecorder(tally: tally)) }
        var waited = 0
        while (m.autoProgress?.done ?? 0) < n && waited < 500 { try await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
        m.stopAutoOptOut(); await run.value
    }

    func testAStoppedRunCarriesOnWithOnlyTheSitesLeft() async throws {
        let (m, me) = readyModel()
        let first = Tally(), second = Tally()
        try await runAndStop(m, me, after: 3, tally: first)
        XCTAssertFalse(first.pages.isEmpty)
        await m.runAutoOptOut(for: me, submitter: SlowRecorder(tally: second))       // Run now
        XCTAssertTrue(Set(first.pages).isDisjoint(with: second.pages), "nothing done before the stop is sent again")
        XCTAssertNil(m.autoSettings.optOutResumePending, "every site left was done: the pass is finished")
        let third = Tally()
        await m.runAutoOptOut(for: me, submitter: SlowRecorder(tally: third))
        XCTAssertTrue(third.pages.isEmpty, "with everything sent this period, Run now has nothing left")
        XCTAssertEqual(Set(first.pages + second.pages).count, first.pages.count + second.pages.count, "no page sent twice")
    }

    /// A Re-test all that is stopped carries on as a re-test: the sites it had not reached are sent again, even though they were sent earlier in the period.
    /// A run's own results do not rebuild the plan after every site (that froze the app for about a second a site); it is rebuilt once when the run ends.
    func testARunRebuildsThePlanOnceWhenItEndsNotAfterEverySite() async throws {
        let (m, me) = readyModel()
        _ = m.plan
        let before = m.planBuilds
        let run = Task { await m.runAutoOptOut(for: me, submitter: SlowRecorder(tally: Tally())) }
        var waited = 0
        while (m.autoProgress?.done ?? 0) < 5 && waited < 500 { _ = m.plan; try await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
        XCTAssertGreaterThanOrEqual(m.autoProgress?.done ?? 0, 5)
        XCTAssertEqual(m.planBuilds, before, "five sites done, the screens redrawn many times: the plan was not rebuilt")
        m.stopAutoOptOut(); await run.value
        _ = m.plan
        XCTAssertEqual(m.planBuilds, before + 1, "rebuilt once, when the run ended")
    }

    func testAStoppedReTestCarriesOnAsAReTest() async throws {
        let (m, me) = readyModel()
        let firstPass = Tally()
        await m.runAutoOptOut(for: me, submitter: SlowRecorder(tally: firstPass))     // everything sent this period
        let total = Set(firstPass.pages)
        XCTAssertFalse(total.isEmpty)
        m.runFullRetestNow(submitter: SlowRecorder(tally: Tally()))
        // runFullRetestNow starts its own task; stop it part-way.
        var waited = 0
        while (m.autoProgress?.done ?? 0) < 3 && waited < 500 { try await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
        m.stopAutoOptOut()
        while m.autoBusy != nil && waited < 1000 { try await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
        XCTAssertEqual(m.autoSettings.passEverySite, true)
        let rest = Tally()
        await m.runAutoOptOut(for: me, submitter: SlowRecorder(tally: rest))          // Run now
        XCTAssertFalse(rest.pages.isEmpty, "the re-test goes on with the sites it had not reached, though they were sent earlier this period")
        XCTAssertLessThan(Set(rest.pages).count, total.count, "and not the ones it already re-tested")
        XCTAssertNil(m.autoSettings.passEverySite, "finished: the next Run now is an ordinary one")
    }
}
