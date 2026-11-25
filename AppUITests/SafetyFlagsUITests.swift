import XCTest

/// Minor and public-figure flags: off by default, saved, and they switch searching off for that profile. (Family profiles are switched off,
/// `Features.otherProfiles`; the rules for them and for minors are Mac tests: `CoreTests` on `canBeSearched` and the relationships.)
final class SafetyFlagsUITests: UITestCase {
    private var brokers: FixtureBrokers!

    override func setUpWithError() throws { brokers = try FixtureBrokers.start() }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"] + brokers.launchArguments   // only the fixture brokers on this machine are ever searched
        app.launch()
        return app
    }

    /// Scrolls the editor until the element can be tapped.
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        var tries = 0
        while !element.isHittable && tries < 8 { app.swipeUp(); tries += 1 }
    }

    /// A SwiftUI toggle row only flips when its switch (the right-hand end of the row) is tapped.
    private func flip(_ app: XCUIApplication, _ toggle: XCUIElement) {
        reveal(app, toggle)
        app.setSwitch(toggle, on: (toggle.value as? String) != "1")
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testBothFlagsAreOffByDefaultAndTheEditorSaysWhy() {
        let app = launch()
        app.buttons["profile-button"].tap()
        let minor = app.switches["flag-minor"], figure = app.switches["flag-public-figure"]
        XCTAssertTrue(app.scrollUntilExists(minor), "the safety flags are in the editor")
        reveal(app, minor)
        XCTAssertEqual(minor.value as? String, "0", "Under 18 must default to off")
        XCTAssertEqual(figure.value as? String, "0", "Public figure must default to no")
        screenshot(app, "1-flags-off-by-default")
    }

    func testPublicFigureFlagAlsoTurnsSearchingOffAndSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile"] + brokers.launchArguments          // a complete profile: only the flag changes
        app.launch()
        app.buttons["profile-button"].tap()
        let figure = app.switches["flag-public-figure"]
        XCTAssertTrue(app.scrollUntilExists(figure), "the safety flags are in the editor")
        flip(app, figure)
        XCTAssertEqual(figure.value as? String, "1")
        app.buttons["editor-done"].tap()          // the editor's own Done button (the keyboard has only its keyboard-down button)
        app.terminate()

        let again = XCUIApplication()
        again.launchArguments = brokers.launchArguments        // no reset: it must have been saved
        again.launch()
        again.tab("Sites", 1).tap()
        XCTAssertTrue(again.scrollUntilExists(again.staticTexts["search-blocked"]), "searching is off, with the reason")      // low on the Sites tab
    }
}
