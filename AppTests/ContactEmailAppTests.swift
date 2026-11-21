import XCTest
import OptOutKitCore
@testable import OptOutKit

/// The household's one email address, and that every form for every profile gets it (exactly as typed).
@MainActor
final class ContactEmailAppTests: XCTestCase {
    private func model() -> AppModel {
        AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                 defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
    }

    private final class Capture: FormSubmitter, @unchecked Sendable {
        var emails: [String] = []
        func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome {
            if let e = plan.values.first(where: { $0.type == "email" })?.candidates.first { emails.append(e) }
            return .submitted(awaitingEmail: false)
        }
    }

    private func complete(_ m: AppModel, name: String, relationship: Relationship? = nil) -> Person {
        var p = m.people.first { $0.relationship == .me }!
        if let relationship { p = m.addPerson(named: name, relationship: relationship)! }
        p.names = [NameEntry(kind: .legal, name: "Pat Example")]; p.birthdate = "1985-03-14"
        p.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")]
        m.update(p)
        return p
    }

    func testAGmailAddressIsTaggedAndLeadsEveryProfilesOwnAddresses() throws {
        let m = model()
        let me = complete(m, name: "Me")
        let mum = complete(m, name: "Mum", relationship: .parent)
        var mumWithOwn = mum; mumWithOwn.emails = ["mum@example.com"]
        XCTAssertNil(m.formEmail, "nothing until an address is given")
        m.setContactEmail("pat@gmail.com")
        XCTAssertEqual(m.formEmail, "pat@gmail.com")
        XCTAssertEqual(m.formPerson(me).emails, ["pat@gmail.com"])
        XCTAssertEqual(m.formPerson(mumWithOwn).emails.first, "pat@gmail.com", "family forms lead with the one address too (replies and confirmations arrive there)")
        XCTAssertEqual(m.formPerson(mumWithOwn).emails, ["pat@gmail.com", "mum@example.com"], "the profile's own addresses follow, for forms with more than one email box")
        m.setContactEmail("pat@example.com")
        XCTAssertEqual(m.formEmail, "pat@example.com", "other providers are left alone")
    }

    /// The profile editor writes once, when it is done: the profile and the household email together.
    func testTheProfileEditorsSingleWriteSavesTheProfileAndTheEmailTogether() throws {
        let m = model()
        var me = complete(m, name: "Me")
        me.phones = ["7736331564"]
        m.saveProfile(me, contactEmail: "pat@example.com")
        XCTAssertEqual(m.people.first { $0.id == me.id }?.phones, ["7736331564"])
        XCTAssertEqual(m.formEmail, "pat@example.com")
        var other = me; other.phones = []
        m.saveProfile(other, contactEmail: nil)
        XCTAssertEqual(m.formEmail, "pat@example.com", "no email given: the household's is left alone")
    }

    func testAProfileIsOnlyReadyWithItsDetailsAndTheHouseholdEmail() throws {
        let m = model()
        let me = m.people.first { $0.relationship == .me }!
        XCTAssertFalse(m.isReady(me))
        XCTAssertTrue(m.missingForSelected.contains("email address"))
        let done = complete(m, name: "Me")
        XCTAssertFalse(m.isReady(done), "details alone are not enough")
        m.setContactEmail("pat@example.com")
        XCTAssertTrue(m.isReady(m.people.first { $0.relationship == .me }!))
        XCTAssertNil(m.incompleteReason)
        m.setContactEmail("nonsense")
        XCTAssertNotNil(m.incompleteReason)
    }

    func testTheWeeklyRunSendsTheTaggedAddressForTheOwnerAndForFamily() async throws {
        let m = model()
        let me = complete(m, name: "Me")
        let mum = complete(m, name: "Mum", relationship: .parent)
        m.setContactEmail("pat@gmail.com")
        for person in [me, mum] {
            let capture = Capture()
            await m.runAutoOptOut(for: person, automaticOnly: false, submitter: capture)
            XCTAssertFalse(capture.emails.isEmpty, person.displayName)
            XCTAssertTrue(capture.emails.allSatisfy { $0 == "pat@gmail.com" }, "\(person.displayName): \(Set(capture.emails))")
        }
    }
}

@MainActor
final class BrowserHandoffTests: XCTestCase {
    func testOpeningAsksAtOnceAndYesFinishesNoDoesNot() {
        let h = BrowserHandoff()
        var opened: [URL] = []
        h.open(URL(string: "https://example.com/optout")!) { opened.append($0) }
        XCTAssertTrue(h.asking); XCTAssertEqual(opened.count, 1)
        var finished = 0
        h.answer(completed: false) { finished += 1 }
        XCTAssertFalse(h.asking); XCTAssertEqual(finished, 0)
        h.open(URL(string: "https://example.com/optout")!) { _ in }
        h.answer(completed: true) { finished += 1 }
        XCTAssertEqual(finished, 1)
    }

    func testOnlyWebAddressesOpen() {
        let h = BrowserHandoff()
        h.open(URL(string: "file:///etc/passwd")!) { _ in XCTFail("not a web page") }
        XCTAssertFalse(h.asking)
    }
}

import SwiftUI

final class RowFieldTests: XCTestCase {
    private struct Row { var name: String }

    func testARowDeletedUnderTheBindingGivesTheDefaultAndIgnoresStoresInsteadOfTrapping() {
        var rows = [Row(name: "a"), Row(name: "b")]
        let list = Binding(get: { rows }, set: { rows = $0 })
        let second = RowField.binding(list, 1, \Row.name, default: "")
        XCTAssertEqual(second.wrappedValue, "b")
        second.wrappedValue = "B"; XCTAssertEqual(rows[1].name, "B")
        rows.remove(at: 1)                                        // the row is deleted; SwiftUI still holds its binding
        XCTAssertEqual(second.wrappedValue, "", "no trap: the default")
        second.wrappedValue = "late"; XCTAssertEqual(rows.count, 1, "a late store is ignored")
        rows.removeAll()
        XCTAssertEqual(RowField.binding(list, 0, \Row.name, default: "x").wrappedValue, "x")
    }
}

@MainActor
final class FirstRunResumeTests: XCTestCase {
    private func model(defaults: UserDefaults = UserDefaults(suiteName: "ook.test.\(UUID())")!, url: URL = FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed")) -> AppModel {
        AppModel(store: HouseholdStore(url: url, keys: FixedKey()), defaults: defaults)
    }

    func testAnUnfinishedProfileBringsTheSetupBackAfterTheAppIsReopenedUntilItIsDone() {
        let defaults = UserDefaults(suiteName: "ook.test.\(UUID())")!
        let first = model(defaults: defaults)
        first.finishAnnouncements()                         // the walkthrough was finished; the profile never was (the app closed or crashed)
        first.resumeSetupIfNeeded()
        XCTAssertTrue(first.showProfileGate, "an incomplete profile reopens the setup")
        first.profileGateFinished(completed: false)         // "Not now": not for this launch, but the setup is still not done
        XCTAssertFalse(first.showProfileGate)
        let second = model(defaults: defaults)
        second.finishAnnouncements(); second.resumeSetupIfNeeded()
        XCTAssertTrue(second.showProfileGate, "and again on the next launch")
        second.profileGateFinished(completed: true)
        let third = model(defaults: defaults)
        third.finishAnnouncements(); third.resumeSetupIfNeeded()
        XCTAssertFalse(third.showProfileGate, "once the setup is done it does not come back")
    }

    func testTheSetupDoesNotOpenOverTheWalkthrough() {
        let m = model()                                     // a fresh install: the walkthrough is pending
        m.resumeSetupIfNeeded()
        XCTAssertFalse(m.showProfileGate)
    }

    func testEmptyRowsAreDroppedWhenAProfileIsSaved() {
        var p = Person(displayName: "Me", relationship: .me)
        p.names = [NameEntry(kind: .legal, name: "Pat Example"), NameEntry(kind: .nickname, name: "  "), NameEntry(kind: .nickname, name: "Patty")]
        p.phones = ["(773) 633-1564", ""]; p.emails = ["", "pat@example.com"]
        p.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701"), Address(city: "", state: ""), Address(city: "Peoria", state: "IL")]
        let q = PersonEditorView.pruned(p)
        XCTAssertEqual(q.names.map(\.name), ["Pat Example", "Patty"])
        XCTAssertEqual(q.phones, ["(773) 633-1564"]); XCTAssertEqual(q.emails, ["pat@example.com"])
        XCTAssertEqual(q.addresses.map(\.city), ["Springfield", "Peoria"], "a started earlier address stays; an empty one goes")
    }
}

#if DEBUG
@MainActor
final class SiteReviewTests: XCTestCase {
    private func entries() throws -> [DirectoryEntry] {
        return try Catalog.contents(of: try XCTUnwrap(AppCatalog.url), includeExcluded: true).sites
    }

    func testTheQueueIsTheSitesWithNoReadableFormMostImportantFirst() throws {
        let rows = SiteReview.rows(from: try entries())
        XCTAssertGreaterThan(rows.count, 100)
        XCTAssertFalse(rows.contains { $0.domain == "peoplefinders.com" }, "a site with a readable form is not asked about")
        let all = try entries()
        let pri = rows.compactMap { r in all.first { $0.id == r.id }?.priority ?? 0 }
        XCTAssertEqual(pri, pri.sorted(by: >), "most important first")
    }

    func testTagsFromTheWebPageAreMergedAndTheNewerOneWins() throws {
        let review = SiteReview(entries: try entries())
        let first = try XCTUnwrap(review.rows.first)
        let json = #"[{"d":"\#(first.domain)","tag":"ok","url":"https://x.example/optout","at":"2099-01-01T00:00:00Z"}]"#
        XCTAssertEqual(review.importJSON(json), 1)
        XCTAssertTrue(review.isDone(first)); XCTAssertEqual(review.tags[first.domain]?.url, "https://x.example/optout")
        let older = #"[{"d":"\#(first.domain)","tag":"none","at":"2000-01-01T00:00:00Z"}]"#
        XCTAssertEqual(review.importJSON(older), 0, "an older tag never replaces a newer one")
        XCTAssertNotEqual(review.current?.domain, first.domain, "the queue moves past a site that is done")
        try? FileManager.default.removeItem(at: review.file)
    }
}
#endif
