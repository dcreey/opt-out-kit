import XCTest
import OptOutKitCore
@testable import AssistedRunLogic

/// Workflows that had no test at all (found in the audit in docs/TESTING.md): the California link in Settings, and the Global Privacy Control
/// walkthrough being remembered. (A link opened from outside the app is covered by AppModelTests.testOnlyAWebAddressInsideAnExnayLinkIsTaken.)
@MainActor
final class WorkflowGapTests: XCTestCase {
    private func model() -> AppModel {
        AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                 defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
    }

    /// Only the owner's profile may have "I am this person" boxes ticked (the page rules are end to end in `FixturePageTypeUITests`).
    func testTheOwnerNeedsNoSettingAndFamilyNeverGetsIt() {
        let m = model()
        _ = m.addPerson(named: "Mom", relationship: .parent)
        XCTAssertTrue(m.household.people.first { $0.relationship == .me }!.mayConfirmOwnIdentity())
        XCTAssertFalse(m.household.people.first { $0.displayName == "Mom" }!.mayConfirmOwnIdentity())
    }

    func testTheCaliforniaLinkInSettingsShowsOnlyWhenCaliforniaIsChosen() {
        let m = model()
        m.setOwnerCountry("US"); m.setOwnerState("TX")
        XCTAssertFalse(m.showsCaliforniaDrop, "Texas: no California link")
        m.setOwnerState("CA")
        XCTAssertTrue(m.showsCaliforniaDrop)
        m.setOwnerCountry("DE"); m.setOwnerState(nil)
        XCTAssertFalse(m.showsCaliforniaDrop, "another country: no California link")
    }

    func testTheGlobalPrivacyControlWalkthroughIsRememberedAndCanBeUndone() {
        let m = model()
        XCTAssertFalse(m.gpcSetupDone)
        m.setGPCSetupDone(true)
        XCTAssertTrue(m.gpcSetupDone)
        m.setGPCSetupDone(false)
        XCTAssertFalse(m.gpcSetupDone)
    }

    func testAPastedLinkBecomesAnHTTPSAddressAndJunkIsRefused() {
        XCTAssertEqual(LinkAddress.normalized("https://example.com/confirm?id=1")?.absoluteString, "https://example.com/confirm?id=1")
        XCTAssertEqual(LinkAddress.normalized("http://example.com/x")?.scheme, "https", "an http link is upgraded")
        XCTAssertEqual(LinkAddress.normalized("  example.com/optout \n")?.absoluteString, "https://example.com/optout", "a bare address gets https and stray spaces go")
        XCTAssertNil(LinkAddress.normalized(""))
        XCTAssertNil(LinkAddress.normalized("not a link"))
        XCTAssertNil(LinkAddress.normalized("ftp://example.com/file"))
        XCTAssertNil(LinkAddress.normalized("javascript:alert(1)"))
    }

    func testSendingForThePersonIsOnByDefaultTheSessionBoxOverridesItAndSettingsChangesTheDefault() {
        let m = model()
        XCTAssertTrue(m.autoSubmitDefault); XCTAssertTrue(m.autoSubmit)
        m.autoSubmitSession = false                        // the box in a guide
        XCTAssertFalse(m.autoSubmit); XCTAssertTrue(m.autoSubmitDefault, "the box does not change the default")
        m.autoSubmitSession = nil
        m.setAutoSubmitDefault(false)                      // Settings
        XCTAssertFalse(m.autoSubmit)
        m.autoSubmitSession = true
        XCTAssertTrue(m.autoSubmit, "this session's box wins over the default")
    }
}
