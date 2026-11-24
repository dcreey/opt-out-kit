import XCTest
import OptOutKitCore
@testable import AssistedRunLogic

/// A site that holds data only on one group of people (`only_for`; agile-ed.com: people who work in US schools) is nothing to do for anyone else: it is left out of
/// the queue and the automatic run, counts as done, and says who it is for. And a confirmation box with frightening legal wording gets plain words, never a tick.
@MainActor
final class OnlyForTests: XCTestCase {
    private func model() -> AppModel {
        AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                 defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
    }

    func testASiteOnlyForSomePeopleIsDoneLeftOutOfTheRunAndSaysWhoItIsFor() throws {
        let m = model()
        var me = try XCTUnwrap(m.selectedPerson)
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"
        me.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")]
        m.update(me); m.setContactEmail("pat@example.com")
        let agile = try XCTUnwrap(m.directory.first { $0.domain == "agile-ed.com" }, "the catalog has agile-ed.com")
        let only = try XCTUnwrap(agile.onlyFor, "with who it holds data on")
        XCTAssertTrue(only.who.contains("schools"))
        XCTAssertTrue(agile.isHandled(m.progress), "it counts as done")
        XCTAssertEqual(SiteStatus.of(agile, progress: m.progress, taskDone: false), .done)
        XCTAssertFalse(AutoOptOut.backgroundAttemptable(agile, person: me, progress: m.progress), "the run never sends it")
        XCTAssertFalse(m.automaticSites(for: me).contains { $0.id == agile.id })
        XCTAssertFalse(OptOutPlan.verifyQueue(m.plan, entries: m.directory).contains(agile.domain), "nor is it in the semi-automated queue")

        // Even after a run tried it (as the 2026-11-24 run did), the page says who it is for instead of asking the person to do it.
        m.setRunStartedForTesting(Date().addingTimeInterval(-600))
        m.recordAttemptForTesting(OptOutAttempt(date: Date().addingTimeInterval(-60), outcome: "failed", detail: "no opt-out form was found on the page"), site: agile.id)
        let row = try XCTUnwrap(m.activityRows(for: me).first { $0.id == agile.id })
        XCTAssertEqual(row.group, .notTried)
        XCTAssertEqual(row.line, "Only holds data on people who work in US schools or school districts: nothing to do unless that is you")
    }

    func testAConfirmationUnderPenaltyOfPerjuryGetsPlainWords() {
        XCTAssertNotNil(AssistedRunner.certificationNote("Under penalty of perjury, I declare all the above information to be true and accurate."))
        XCTAssertNotNil(AssistedRunner.certificationNote("I swear that I am the consumer named above"))
        XCTAssertNil(AssistedRunner.certificationNote("I understand that I may be contacted to verify my request."), "plain wording needs no note")
        XCTAssertNil(AssistedRunner.certificationNote(nil))
    }
}
