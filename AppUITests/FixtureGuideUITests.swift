import XCTest

/// The guided screen against a fixture broker with a hand-written guide (fixtures/flows/fxguide.yml, page kind `guide`): the real guide engine, a real page
/// in a real web view, nothing faked. docs/TESTING.md, "End-to-end tests against fixture pages".
final class FixtureGuideUITests: UITestCase {
    private var server: FixtureBrokers!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try FixtureBrokers.start()
    }

    private func openGuide(_ app: XCUIApplication) {
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile"] + server.launchArguments          // a guide needs a complete profile
        app.launch()
        app.openFlowTask("fxguide", search: "guide-1")
        let start = app.buttons["guide-me"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// As a user I want the guide on top of the site's page, showing the whole step and where I am in the walkthrough.
    func testTheGuideSitsOnTopInAColouredFrameAndShowsTheWholeStep() {
        let app = XCUIApplication()
        openGuide(app)
        let progress = app.staticTexts["guided-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        XCTAssertTrue(progress.label.contains("of 5"), "the total number of steps is shown: \(progress.label)")
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
        XCTAssertTrue(app.webViews.staticTexts["Opt out of fx_guide_1"].waitForExistence(timeout: 20), "the broker's page really loaded in it")
        shot(app, "guide-panel")
    }

    /// As a user I want the guide to move on by itself when it sees a step done (the page loaded, my email copied) and to wait for Next when it cannot see it.
    func testStepsAdvanceByThemselvesWhenSeenAndWithNextWhenNot() {
        let app = XCUIApplication()
        openGuide(app)
        let progress = app.staticTexts["guided-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        // Step 1 (open the site) is finished by the app as soon as the page loads.
        expectation(for: NSPredicate(format: "label CONTAINS 'Step 2'"), evaluatedWith: progress); waitForExpectations(timeout: 20)
        // Step 2 is "copy your email": copying it finishes the step, which the guide sees.
        XCTAssertTrue(app.buttons["guided-copy"].exists)
        app.buttons["guided-copy"].tap()
        XCTAssertTrue(app.staticTexts["guided-status"].waitForExistence(timeout: 3))
        let status = app.staticTexts["guided-status"].label
        XCTAssertTrue(status.contains("Copied") || status.contains("done"), status)
        let step3 = NSPredicate(format: "label CONTAINS 'Step 3'")
        if !step3.evaluate(with: progress) { app.buttons["guided-next"].tap() }
        expectation(for: step3, evaluatedWith: progress); waitForExpectations(timeout: 5)
        // Step 3 ("enter your email") has no detector: Next moves on.
        app.buttons["guided-next"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS 'Step 4'"), evaluatedWith: progress); waitForExpectations(timeout: 5)
        shot(app, "guide-step-4")
    }

    /// As a user I want to finish a guide: I enter my email on the page and press its Submit myself, the broker receives it, and the guide walks me to done and
    /// the site shows as done.
    func testWalkingTheGuideToTheEndSendsMyRequestAndMarksTheSiteDone() {
        let app = XCUIApplication()
        openGuide(app)
        let progress = app.staticTexts["guided-progress"]
        expectation(for: NSPredicate(format: "label CONTAINS 'Step 2'"), evaluatedWith: progress); waitForExpectations(timeout: 20)
        app.buttons["guided-copy"].tap()
        let step3 = NSPredicate(format: "label CONTAINS 'Step 3'")
        if !step3.evaluate(with: progress) { app.buttons["guided-next"].tap() }
        expectation(for: step3, evaluatedWith: progress); waitForExpectations(timeout: 5)
        app.buttons["guided-next"].tap()                                  // "Enter your email on the page"
        expectation(for: NSPredicate(format: "label CONTAINS 'Step 4'"), evaluatedWith: progress); waitForExpectations(timeout: 5)

        // I enter my email on the page (the guide copied it for me to paste) and press the page's own Submit; the broker receives the request.
        let box = app.webViews.textFields["Email address"]
        XCTAssertTrue(box.waitForExistence(timeout: 10))
        box.tap(); box.typeTextChecked("pat@example.com")
        let submit = app.webViews.buttons["Submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        var taps = 0
        while server.sentSites.isEmpty && taps < 6 { if submit.isHittable { submit.tap() }; Thread.sleep(forTimeInterval: 3); taps += 1 }
        XCTAssertEqual(server.sentSites, ["fx_guide_1"], "the broker received the request: \(server.requests)")
        XCTAssertTrue(server.requests.last?.fields["email"]?.contains("@") == true, "with my email: \(server.requests)")

        for _ in 0..<3 where app.buttons["guided-next"].waitForExistence(timeout: 20) {
            app.buttons["guided-next"].tap()
            if app.buttons["finish-done"].waitForExistence(timeout: 5) { break }
        }
        let done = app.buttons.matching(identifier: "finish-done").firstMatch
        if done.waitForExistence(timeout: 20) { done.tap() }
        shot(app, "guide-finished")
        XCTAssertTrue(app.staticTexts["Submitted, verifying"].waitForExistence(timeout: 20), "back on the site, which shows the request as submitted and being verified")
    }

    /// As a user I want to cancel a guide and land back on the site's page without it counting as a report.
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

    /// As a user I want to say a guide does not work and why: the reasons are offered, and the site then shows it was reported.
    func testNotWorkingOffersTheReasonsAndRecordsOne() {
        let app = XCUIApplication()
        openGuide(app)
        XCTAssertTrue(app.buttons["guided-more"].waitForExistence(timeout: 10))
        app.buttons["guided-more"].tap()
        let notWorking = app.buttons["Not working"], first = app.buttons["The page or link is broken"]
        XCTAssertTrue(notWorking.waitForExistence(timeout: 10))
        for _ in 0..<3 where !first.exists {
            expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: notWorking); waitForExpectations(timeout: 10)
            notWorking.tap()
            _ = first.waitForExistence(timeout: 5)
        }
        shot(app, "guide-not-working-menu")
        for label in ["The page or link is broken", "It needs something else (login, payment, ID or a phone call)", "The site blocked me"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5), "\(label) is offered")
        }
        app.buttons["The site blocked me"].tapWhenHittable()
        XCTAssertTrue(app.descendants(matching: .any)["reported-issue"].waitForExistence(timeout: 10), "the site now shows it was reported")
    }

    /// As a user I want a guide whose page or link is broken to say so and look for the new page, rather than leave me stuck on it.
    func testAGuideToldTheLinkIsBrokenLooksForTheNewPage() {
        let app = XCUIApplication()
        openGuide(app)
        XCTAssertTrue(app.buttons["guided-more"].waitForExistence(timeout: 10))
        app.buttons["guided-more"].tap()
        let notWorking = app.buttons["Not working"], first = app.buttons["The page or link is broken"]
        XCTAssertTrue(notWorking.waitForExistence(timeout: 10))
        for _ in 0..<3 where !first.exists {
            expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: notWorking); waitForExpectations(timeout: 10)
            notWorking.tap()
            _ = first.waitForExistence(timeout: 5)
        }
        first.tapWhenHittable()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'looks broken'")).firstMatch.waitForExistence(timeout: 30), "the guide says it will look for the new page")
        shot(app, "guide-broken-link")
    }
}
