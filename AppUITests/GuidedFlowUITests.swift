import XCTest

/// The guided screen: browser on top, our panel in the bottom quarter, with the step, a count, Next, Cancel and Not working.
final class GuidedFlowUITests: XCTestCase {
    private func openGuide(_ app: XCUIApplication) {
        app.launchArguments = ["-uitest-reset", "-uitest-fake-guided"]
        app.launch()
        app.openFlowTask("peopleconnect")
        let start = app.buttons["guide-me"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testThePanelSitsInTheBottomQuarterAndShowsTheStepAndTheTotal() {
        let app = XCUIApplication()
        openGuide(app)
        let progress = app.staticTexts["guided-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        XCTAssertTrue(progress.label.contains("of 6"), "the total number of steps is shown: \(progress.label)")
        let screen = app.windows.firstMatch.frame
        let next = app.buttons["guided-next"]
        XCTAssertGreaterThan(next.frame.minY, screen.height * 0.74, "the app's controls live in the bottom quarter")
        XCTAssertGreaterThan(next.frame.maxY, screen.height * 0.9, "and the panel reaches the bottom of the screen, with no gap")
        let browser = app.webViews.firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(browser.frame.maxY, screen.height * 0.76, "the browser fills the top three quarters")
        XCTAssertGreaterThan(browser.frame.height, screen.height * 0.6, "and takes most of the screen")
        shot(app, "6-guided-panel")
    }

    func testStepsAdvanceByThemselvesWhenSeenAndWithNextWhenNot() {
        let app = XCUIApplication()
        openGuide(app)
        let progress = app.staticTexts["guided-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        // Step 1 (open the site) is finished by the app as soon as the page loads.
        let advanced = NSPredicate(format: "label CONTAINS 'Step 2'")
        expectation(for: advanced, evaluatedWith: progress); waitForExpectations(timeout: 10)
        // Step 2 is "copy your email". With no email on the profile it says so, and Next still moves on.
        XCTAssertTrue(app.buttons["guided-copy"].exists)
        app.buttons["guided-copy"].tap()
        XCTAssertTrue(app.staticTexts["guided-status"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["guided-status"].label.contains("not on your profile"))
        app.buttons["guided-next"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS 'Step 3'"), evaluatedWith: progress); waitForExpectations(timeout: 5)
        // Step 3 has no detector in this broker file: Next moves on.
        app.buttons["guided-next"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS 'Step 4'"), evaluatedWith: progress); waitForExpectations(timeout: 5)
        shot(app, "7-guided-step-4")
    }

    func testCancelLeavesTheGuideAndGoesBackToTheSite() {
        let app = XCUIApplication()
        openGuide(app)
        XCTAssertTrue(app.buttons["guided-cancel"].waitForExistence(timeout: 10))
        app.buttons["guided-cancel"].tap()
        XCTAssertTrue(app.buttons["guide-me"].waitForExistence(timeout: 5), "back on the site's page")
        XCTAssertFalse(app.staticTexts["reported-issue"].exists, "cancelling is not a report")
    }

    func testNotWorkingOffersTheReasonsAndRecordsOne() {
        let app = XCUIApplication()
        openGuide(app)
        XCTAssertTrue(app.buttons["guided-not-working"].waitForExistence(timeout: 10))
        app.buttons["guided-not-working"].tap()
        shot(app, "8-guided-not-working-menu")
        for label in ["The page or link is broken", "It needs something else (login, payment, ID or a phone call)", "The site blocked me"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 3), "\(label) is offered")
        }
        app.buttons["The page or link is broken"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["reported-issue"].waitForExistence(timeout: 5), "the site now shows it was reported")
    }
}

final class SiteViewLayoutUITests: XCTestCase {
    private func scrollToBottom(_ app: XCUIApplication) {
        for _ in 0..<8 { app.swipeUp() }
    }

    func testABrokerSiteViewLeadsWithTheGuideAndEndsWithTheSiteLink() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-fake-guided"]
        app.launch()
        app.tabBars.buttons["Sites"].tap()
        app.searchSites("peopleconnect")
        XCTAssertTrue(app.buttons["task-flow-peopleconnect"].waitForExistence(timeout: 10))
        app.buttons["task-flow-peopleconnect"].tap()
        let guide = app.buttons["guide-me"]
        XCTAssertTrue(guide.waitForExistence(timeout: 5))
        let screen = app.windows.firstMatch.frame
        XCTAssertLessThan(guide.frame.minY, screen.height * 0.4, "the guide is front and center, at the top")
        XCTAssertGreaterThan(guide.frame.width, screen.width * 0.7, "and it is big")
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "9-site-view-guide-first"; a.lifetime = .keepAlways; add(a)
        scrollToBottom(app)
        let link = app.buttons["site-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 3), "the site link is at the bottom")
        XCTAssertFalse(guide.isHittable, "the guide is far above it")
    }

    func testADirectorySiteViewLeadsWithTheGuideAndEndsWithTheSiteLink() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-fake-guided"]
        app.launch()
        app.tabBars.buttons["Sites"].tap()
        app.searchSites("texascourtrecords")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'task-site-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        let guide = app.buttons["guide-me"]
        XCTAssertTrue(guide.waitForExistence(timeout: 5))
        XCTAssertLessThan(guide.frame.minY, app.windows.firstMatch.frame.height * 0.4)
        scrollToBottom(app)
        XCTAssertTrue(app.buttons["site-link"].waitForExistence(timeout: 3))
        XCTAssertFalse(guide.isHittable)
    }

    func testTheGuideOpensFromTheSiteView() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-fake-guided"]
        app.launch()
        app.tabBars.buttons["Sites"].tap()
        app.searchSites("peopleconnect")
        app.buttons["task-flow-peopleconnect"].tap()
        app.buttons["guide-me"].tap()
        XCTAssertTrue(app.staticTexts["guided-progress"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["guided-cancel"].exists)
    }
}
