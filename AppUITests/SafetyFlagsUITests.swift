import XCTest

/// Minor and public-figure flags: off by default, saved, and they switch searching off for that profile.
final class SafetyFlagsUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-fake-scan"]   // fake scan: never touches the internet
        app.launch()
        return app
    }

    private func addRelative(_ app: XCUIApplication, named name: String) {
        app.buttons["account-switcher"].tap()
        app.buttons["Add person…"].tap()
        let field = app.alerts.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText(name)
        app.alerts.buttons["Add"].tap()
    }

    /// Gives the owner the required legal name and current address, which searching needs.
    private func completeOwner(_ app: XCUIApplication) {
        app.buttons["profile-button"].tap()
        app.fillRequiredProfile()
        app.buttons["Done"].tap()
    }

    /// Scrolls the editor until the element can be tapped.
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        var tries = 0
        while !element.isHittable && tries < 8 { app.swipeUp(); tries += 1 }
    }

    /// A SwiftUI toggle row only flips when its switch (the right-hand end of the row) is tapped.
    private func flip(_ app: XCUIApplication, _ toggle: XCUIElement) {
        reveal(app, toggle)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testBothFlagsAreOffByDefaultAndTheEditorSaysWhy() {
        let app = launch()
        app.buttons["profile-button"].tap()
        let minor = app.switches["flag-minor"], figure = app.switches["flag-public-figure"]
        XCTAssertTrue(minor.waitForExistence(timeout: 5))
        reveal(app, minor)
        XCTAssertEqual(minor.value as? String, "0", "Under 18 must default to off")
        XCTAssertEqual(figure.value as? String, "0", "Public figure must default to no")
        screenshot(app, "1-flags-off-by-default")
    }

    func testFriendIsNotAnOption() {
        let app = launch()
        addRelative(app, named: "Mum")
        let dropdown = app.buttons["field-relationship"]
        XCTAssertTrue(dropdown.waitForExistence(timeout: 5))
        dropdown.tap()
        XCTAssertTrue(app.buttons["Parent"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Friend"].exists)
        XCTAssertTrue(app.buttons["Other family"].exists)
        screenshot(app, "2-relationship-family-only")
    }

    func testMarkingAChildAsAMinorTurnsSearchingOffForThatProfileOnly() {
        let app = launch()
        completeOwner(app)
        // The owner can scan (fake network).
        app.tabBars.buttons["Sites"].tap()
        XCTAssertTrue(app.buttons["scan-exposure"].isEnabled)
        XCTAssertFalse(app.staticTexts["search-blocked"].exists)

        // Add a child and mark them under 18.
        app.tabBars.buttons["Queue"].tap()
        addRelative(app, named: "Sam")
        let minor = app.switches["flag-minor"]
        XCTAssertTrue(minor.waitForExistence(timeout: 5))
        flip(app, minor)
        XCTAssertEqual(minor.value as? String, "1")
        screenshot(app, "3-minor-switch-on")
        app.fillRequiredProfile()
        app.buttons["Done"].tap()

        // Sam is selected: searching is off, with a reason.
        app.tabBars.buttons["Sites"].tap()
        XCTAssertTrue(app.staticTexts["search-blocked"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["scan-exposure"].isEnabled)
        XCTAssertFalse(app.buttons["quick-checks"].isEnabled)
        screenshot(app, "4-searching-off-for-minor")

        // Switch back to the owner: searching works again.
        app.tabBars.buttons["Queue"].tap()
        app.buttons["account-switcher"].tap()
        app.buttons["Me"].tap()
        app.tabBars.buttons["Sites"].tap()
        XCTAssertTrue(app.buttons["scan-exposure"].isEnabled)
        XCTAssertFalse(app.staticTexts["search-blocked"].exists)
        screenshot(app, "5-owner-can-search-again")
    }

    func testPublicFigureFlagAlsoTurnsSearchingOffAndSurvivesRelaunch() {
        let app = launch()
        app.buttons["profile-button"].tap()
        let figure = app.switches["flag-public-figure"]
        XCTAssertTrue(figure.waitForExistence(timeout: 5))
        flip(app, figure)
        XCTAssertEqual(figure.value as? String, "1")
        app.fillRequiredProfile()
        app.buttons["Done"].tap()
        app.terminate()

        let again = XCUIApplication()
        again.launchArguments = ["-uitest-fake-scan"]        // no reset: it must have been saved
        again.launch()
        again.tabBars.buttons["Sites"].tap()
        XCTAssertTrue(again.staticTexts["search-blocked"].waitForExistence(timeout: 5))
        XCTAssertFalse(again.buttons["scan-exposure"].isEnabled)
    }
}
