import XCTest
import OptOutKitCore
@testable import OptOutKit

/// "I am this person" boxes, on LOCAL pages with a made-up profile. Only the owner who allowed it gets a plain self statement
/// ticked; family profiles, legal certifications and terms are never touched.
@MainActor
final class IdentityConfirmationTests: XCTestCase {
    private let html = """
    <html><body><form onsubmit="event.preventDefault(); document.body.innerHTML='<p>Thank you. Your request has been received.</p><pre id=got>' + [me.checked, cert.checked, terms.checked, agent.checked].join('|') + '</pre>';">
      <input type="email" name="email">
      <label><input type="checkbox" name="me"> I confirm that I am the person associated with this email address and consent to receive an email from Example.</label>
      <label><input type="checkbox" name="cert"> I certify under penalty of perjury that the information is true.</label>
      <label><input type="checkbox" name="terms"> I agree to the terms of service.</label>
      <label><input type="checkbox" name="agent"> I am an authorized agent acting on behalf of the person.</label>
      <button type="submit">Submit</button></form></body></html>
    """

    private func form() -> OptOutForm {
        OptOutForm(page: URL(string: "https://x.example/optout")!, method: "post", action: nil, fields: [FormField(type: "email", name: "email", label: "Email *")], hops: 1)
    }

    private func ticked(_ person: Person) async throws -> String {
        let plan = FormFiller.plan(for: form(), signals: nil, person: person)
        XCTAssertEqual(plan.verdict, .ready)
        let session = WebViewSession.make()
        defer { session.close() }
        try await session.loadHTML(html)
        await session.settlePage(maxWait: 2)
        _ = await session.fillFields(plan.values)
        let state = try await session.webView.evaluateJavaScript(#"["me","cert","terms","agent"].map(function(n){return document.querySelector('[name='+n+']').checked}).join('|')"#) as? String
        return try XCTUnwrap(state)
    }

    func testOnlyThePlainSelfStatementIsTickedForTheOwner() async throws {
        let me = Person(displayName: "Me", relationship: .me, names: [NameEntry(kind: .legal, name: "Pat Example")], emails: ["pat@example.com"], confirmsOwnIdentity: true)
        let state = try await ticked(me)
        XCTAssertEqual(state, "true|false|false|false")
    }

    func testNothingIsTickedForAFamilyProfile() async throws {
        for person in [Person(displayName: "Mom", relationship: .parent, names: [NameEntry(kind: .legal, name: "Pat Example")], emails: ["pat@example.com"], confirmsOwnIdentity: true),
                       Person(displayName: "Dad", relationship: .parent, names: [NameEntry(kind: .legal, name: "Pat Example")], emails: ["pat@example.com"])] {
            // These plans are not "ready" when the form lists the box, but this page's form description omits it, as a real profile may:
            // the live page must still be left untouched.
            let plan = FormFiller.plan(for: form(), signals: nil, person: person)
            XCTAssertFalse(plan.values.contains { $0.type == FormFiller.confirmIdentityType })
            let session = WebViewSession.make()
            defer { session.close() }
            try await session.loadHTML(html)
            await session.settlePage(maxWait: 2)
            _ = await session.fillFields(plan.values)
            let state = try await session.webView.evaluateJavaScript(#"["me","cert","terms","agent"].map(function(n){return document.querySelector('[name='+n+']').checked}).join('|')"#) as? String
            XCTAssertEqual(state, "false|false|false|false", person.displayName)
        }
    }

    func testTheOwnerNeedsNoSettingAndFamilyNeverGetsIt() {
        let model = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                             defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        _ = model.addPerson(named: "Mom", relationship: .parent)
        XCTAssertTrue(model.household.people.first { $0.relationship == .me }!.mayConfirmOwnIdentity())
        XCTAssertFalse(model.household.people.first { $0.displayName == "Mom" }!.mayConfirmOwnIdentity())
    }
}
