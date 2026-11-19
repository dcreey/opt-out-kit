import XCTest

/// The guided screen: browser on top, our panel in the bottom quarter, with the step, a count, Next, Cancel and Not working.
final class GuidedFlowUITests: XCTestCase {
    private func openGuide(_ app: XCUIApplication) {
        app.launchArguments = ["-uitest-reset", "-uitest-fake-guided", "-uitest-seed-profile"]          // a guide needs a complete profile
        app.launch()
        app.openFlowTask("peopleconnect")
        let start = app.buttons["guide-me"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testTheGuideSitsOnTopInAColouredFrameAndShowsTheWholeStep() {
        let app = XCUIApplication()
        openGuide(app)
        let progress = app.staticTexts["guided-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        XCTAssertTrue(progress.label.contains("of 6"), "the total number of steps is shown: \(progress.label)")
        let screen = app.windows.firstMatch.frame
        XCTAssertTrue(app.otherElements["guided-banner"].exists || app.staticTexts["guided-banner"].exists, "a gold line carrying the icon and Exnay separates the guide from the site")
        let next = app.buttons["guided-next"]
        XCTAssertLessThan(next.frame.maxY, screen.height * 0.6, "the guide and its buttons are on top, nothing is cut off at the bottom")
        let title = app.staticTexts["guided-step-title"]
        XCTAssertTrue(title.exists)
        XCTAssertFalse(title.label.hasSuffix("…") || title.label.hasSuffix("..."), "the instruction is shown in full")
        let browser = app.webViews.firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(browser.frame.minY, next.frame.maxY - 1, "the site's page is below the guide")
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
        // Step 2 is "copy your email". Copying it finishes the step, which the guide sees, so it moves on by itself (Next is only for a step it
        // cannot see).
        XCTAssertTrue(app.buttons["guided-copy"].exists)
        app.buttons["guided-copy"].tap()
        XCTAssertTrue(app.staticTexts["guided-status"].waitForExistence(timeout: 3))
        let status = app.staticTexts["guided-status"].label
        XCTAssertTrue(status.contains("Copied") || status.contains("done"), status)
        let step3 = NSPredicate(format: "label CONTAINS 'Step 3'")
        if !step3.evaluate(with: progress) { app.buttons["guided-next"].tap() }
        expectation(for: step3, evaluatedWith: progress); waitForExpectations(timeout: 5)
        // Step 3 has no detector in this broker file: Next moves on.
        app.buttons["guided-next"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS 'Step 4'"), evaluatedWith: progress); waitForExpectations(timeout: 5)
        shot(app, "7-guided-step-4")
    }

    func testCancelLeavesTheGuideAndGoesBackToTheSite() {
        let app = XCUIApplication()
        openGuide(app)
        XCTAssertTrue(app.buttons["guided-more"].waitForExistence(timeout: 10))
        app.buttons["guided-more"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["guide-me"].waitForExistence(timeout: 5), "back on the site's page")
        XCTAssertFalse(app.staticTexts["reported-issue"].exists, "cancelling is not a report")
    }

    func testNotWorkingOffersTheReasonsAndRecordsOne() {
        let app = XCUIApplication()
        openGuide(app)
        XCTAssertTrue(app.buttons["guided-more"].waitForExistence(timeout: 10))
        app.buttons["guided-more"].tap()
        // On a slow machine the menu can still be appearing: tap "Not working" once it can be tapped, and again if its reasons did not open.
        let notWorking = app.buttons["Not working"], first = app.buttons["The page or link is broken"]
        XCTAssertTrue(notWorking.waitForExistence(timeout: 10))
        for _ in 0..<3 where !first.exists {
            let ready = NSPredicate(format: "hittable == true")
            expectation(for: ready, evaluatedWith: notWorking); waitForExpectations(timeout: 10)
            notWorking.tap()
            _ = first.waitForExistence(timeout: 5)
        }
        shot(app, "8-guided-not-working-menu")
        for label in ["The page or link is broken", "It needs something else (login, payment, ID or a phone call)", "The site blocked me"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5), "\(label) is offered")
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
        app.launchArguments = ["-uitest-reset", "-uitest-fake-guided", "-uitest-seed-profile"]          // a guide needs a complete profile
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

    func testADirectorySiteViewHasTheSiteLinkAtTheTopAndNotAgainAtTheBottom() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-fake-guided", "-uitest-seed-profile"]          // a guide needs a complete profile
        app.launch()
        app.tabBars.buttons["Sites"].tap()
        app.searchSites("texascourtrecords")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'task-site-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        let guide = app.buttons["guide-me"]
        XCTAssertTrue(guide.waitForExistence(timeout: 5))
        XCTAssertLessThan(guide.frame.minY, app.windows.firstMatch.frame.height * 0.5)
        let link = app.buttons["site-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 3), "the site link is in the status block at the top")
        XCTAssertLessThan(link.frame.minY, app.windows.firstMatch.frame.height * 0.5)
        XCTAssertEqual(app.buttons.matching(identifier: "site-link").count, 1, "one link, not a second one at the bottom")
    }

    func testTheGuideOpensFromTheSiteView() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-fake-guided", "-uitest-seed-profile"]          // a guide needs a complete profile
        app.launch()
        app.tabBars.buttons["Sites"].tap()
        app.searchSites("peopleconnect")
        app.buttons["task-flow-peopleconnect"].tap()
        app.buttons["guide-me"].tap()
        XCTAssertTrue(app.staticTexts["guided-progress"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["guided-more"].exists, "the guide's menu is on top")
    }
}
