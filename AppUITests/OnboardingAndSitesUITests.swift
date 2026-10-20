import XCTest

final class OnboardingAndSitesUITests: XCTestCase {
    func testWalkthroughShowsOnFirstInstallAndCanBeFinished() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-onboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding-next"].waitForExistence(timeout: 10))
        for _ in 0..<4 { app.buttons["onboarding-next"].tap() }
        app.buttons["onboarding-done"].tap()
        XCTAssertTrue(app.buttons["broker-spokeo"].waitForExistence(timeout: 5), "queue visible after walkthrough")
    }

    func testWalkthroughDoesNotReappearOnNextLaunch() {
        let first = XCUIApplication()
        first.launchArguments = ["-uitest-reset", "-uitest-onboarding"]
        first.launch()
        first.buttons["onboarding-skip"].tap()
        first.terminate()

        let again = XCUIApplication()
        again.launch()
        XCTAssertTrue(again.buttons["broker-spokeo"].waitForExistence(timeout: 10))
        XCTAssertFalse(again.buttons["onboarding-next"].exists)
    }

    func testSitesTabSearchAndStatus() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        app.tabBars.buttons["Sites"].tap()
        XCTAssertTrue(app.buttons["site-peopleconnect"].waitForExistence(timeout: 5))

        // Search finds a brand covered by PeopleConnect.
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("truthfinder")
        XCTAssertTrue(app.buttons["site-peopleconnect"].exists)
        XCTAssertFalse(app.buttons["site-spokeo"].exists)

        app.buttons["site-peopleconnect"].tap()
        XCTAssertTrue(app.staticTexts["Not started"].waitForExistence(timeout: 5))
    }

    func testAboutTabReplaysWalkthrough() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        app.tabBars.buttons["About"].tap()
        app.buttons["show-walkthrough"].tap()
        XCTAssertTrue(app.buttons["onboarding-next"].waitForExistence(timeout: 5))
    }
}
