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
