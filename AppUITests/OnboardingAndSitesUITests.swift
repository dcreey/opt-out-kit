import XCTest

final class OnboardingAndSitesUITests: XCTestCase {
    func testWalkthroughShowsOnFirstInstallAndCanBeFinished() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-onboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding-next"].waitForExistence(timeout: 10))
        for _ in 0..<5 { app.buttons["onboarding-next"].tap() }
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

final class DirectoryUITests: XCTestCase {
    func testSitesTabListsAndSearchesTheDirectory() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        app.tabBars.buttons["Sites"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("texascourtrecords")
        let row = app.buttons["dir-texascourtrecords_us"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["Shared opt-out"].waitForExistence(timeout: 5))
        // The real form the profiler found: it posts to the shared members host.
        XCTAssertTrue(app.staticTexts["Submits to members.courtrecords.us"].waitForExistence(timeout: 5))
    }
}

final class ExposureScanUITests: XCTestCase {
    func testScanShowsGroupedResultsWithoutTouchingTheNetwork() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-fake-scan"]
        app.launch()
        // Give the default person a name so the check has something to search for.
        app.buttons["profile-button"].tap()
        let name = app.textFields["name-0"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Pat Example")
        app.buttons["Done"].tap()

        app.tabBars.buttons["Sites"].tap()
        app.buttons["scan-exposure"].tap()
        app.buttons["start-scan"].tap()
        XCTAssertTrue(app.staticTexts["scan-summary"].waitForExistence(timeout: 30))
    }
}

final class QuickCheckUITests: XCTestCase {
    func testLookingAtASiteEarnsPoints() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        app.tabBars.buttons["Sites"].tap()
        XCTAssertTrue(app.staticTexts["Exposed"].waitForExistence(timeout: 5))
        app.buttons["quick-checks"].tap()
        XCTAssertTrue(app.buttons["answer-clean"].waitForExistence(timeout: 5))
        app.buttons["answer-clean"].tap()
        XCTAssertTrue(app.staticTexts["earned"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["5 pts"].waitForExistence(timeout: 3))
    }
}
