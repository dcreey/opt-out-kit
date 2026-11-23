import XCTest

/// The Solve-and-send screen on fixture brokers that hold for the person (a page with no form, a page that is down): the real engine and web view, nothing
/// faked. docs/TESTING.md, "End-to-end tests against fixture pages".
final class SolveAndSendUITests: UITestCase {
    private var server: FixtureBrokers!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try FixtureBrokers.start()
    }

    /// Launch arguments for Solve and send on two sites that hold for the person, so nothing is sent while the screen is looked at.
    private func holding(_ extra: [String] = []) -> [String] {
        ["-uitest-reset", "-uitest-seed-profile"] + server.launchArguments + ["-semi-domains", "noform-1.fixture.test,down-1.fixture.test"] + extra
    }

    func testPreviousSiteReopensTheEarlierSiteAndNextSiteBringsYouForwardAgain() {
        let app = XCUIApplication()
        app.launchArguments = holding()
        app.launch()
        let label = app.staticTexts["assisted-site"]
        XCTAssertTrue(label.waitForExistence(timeout: 20), "the Solve-and-send screen opened")
        let first = label.label

        // "Send it for me" is on by default and can be turned off for the session.
        let box = app.buttons["auto-submit-toggle"]
        XCTAssertTrue(box.waitForExistence(timeout: 10))
        XCTAssertEqual(box.value as? String, "on")
        // The switch's value follows a tap a moment later on a slow machine: wait for it.
        func becomes(_ v: String) -> Bool {
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", v), object: box)], timeout: 5) == .completed
        }
        box.tap()
        XCTAssertTrue(becomes("off"), "Send it for me turns off")
        box.tap()
        XCTAssertTrue(becomes("on"), "and on again")

        // The first site has nothing before it.
        app.buttons["assisted-more"].tap()
        XCTAssertTrue(app.buttons["assisted-skip"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["assisted-back"].exists, "no Previous site on the first site")
        app.buttons["assisted-skip"].tap()

        expectation(for: NSPredicate(format: "label != %@", first), evaluatedWith: label)
        waitForExpectations(timeout: 20)
        let second = label.label

        app.buttons["assisted-more"].tap()
        let back = app.buttons["assisted-back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Previous site is in the menu from the second site on")
        back.tap()

        expectation(for: NSPredicate(format: "label == %@", first), evaluatedWith: label)
        waitForExpectations(timeout: 20)
        let words = app.staticTexts["assisted-instruction"]
        XCTAssertTrue(words.waitForExistence(timeout: 10))
        // The earlier site's page loads again first; once it is up the app says it will not send anything for a site visited again.
        expectation(for: NSPredicate(format: "label CONTAINS 'back on this site'"), evaluatedWith: words); waitForExpectations(timeout: 30)
        let next = app.buttons["assisted-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        expectation(for: NSPredicate(format: "label == %@", second), evaluatedWith: label)
        waitForExpectations(timeout: 20)
    }

    func testMyDataIsInTheMenuAndOffersEachDetailToCopy() {
        let app = XCUIApplication()
        app.launchArguments = holding()
        app.launch()
        XCTAssertTrue(app.staticTexts["assisted-site"].waitForExistence(timeout: 20))
        app.buttons["assisted-more"].tap()
        let myData = app.buttons["assisted-my-data"]
        XCTAssertTrue(myData.waitForExistence(timeout: 5), "My data is in the … menu")
        myData.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '@'")).firstMatch.waitForExistence(timeout: 5), "the person's email is listed to copy")
        XCTAssertTrue(app.buttons["assisted-maid"].exists, "the advertising ID (MAID) is offered too")
    }

    func testAConfirmationNobodyPressedAnythingForAsksWasThisSent() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile"] + server.launchArguments + ["-semi-domains", "selfconfirm-1.fixture.test"]
        app.launch()
        // The page says "Your request has been received" by itself, though I pressed nothing: the app asks rather than assuming.
        let alert = app.alerts["Was this sent?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 60), "the question is on screen")
        XCTAssertTrue(server.sentSites.isEmpty, "nothing was sent: the page only said so")
        XCTAssertTrue(alert.buttons["Yes, it was sent"].exists)
        XCTAssertTrue(alert.buttons["No, stay on this page"].exists)
        alert.buttons["No, stay on this page"].tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 2), "answering closes it")
        XCTAssertFalse(app.buttons["finish-done"].exists, "No means it is not counted as sent or done")
    }

    func testTheFirstGuidedFlowOpensWithAWalkthroughThatCanBePagedThroughOrSkipped() {
        let args = holding(["-show-guided-intro"])
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        XCTAssertTrue(app.staticTexts["This is a guided site"].waitForExistence(timeout: 20), "the walkthrough opens before the first site")
        for _ in 0..<4 { app.buttons["guided-intro-next"].tap() }
        XCTAssertTrue(app.staticTexts["Emails after you send"].waitForExistence(timeout: 5), "the last page explains the email follow-ups")
        app.buttons["guided-intro-done"].tap()
        XCTAssertTrue(app.staticTexts["assisted-site"].waitForExistence(timeout: 20), "the flow starts once the walkthrough closes")

        let again = XCUIApplication()
        again.launchArguments = args
        again.launch()
        XCTAssertTrue(again.buttons["guided-intro-skip"].waitForExistence(timeout: 20), "it can be skipped")
        again.buttons["guided-intro-skip"].tap()
        XCTAssertTrue(again.staticTexts["assisted-site"].waitForExistence(timeout: 20))
    }

    func testTheGuidedWalkthroughIsReplayedFromAbout() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile"]
        app.launch()
        app.tab("Settings", 3).tap()
        let replay = app.buttons["show-guided-intro"]
        XCTAssertTrue(replay.waitForExistence(timeout: 10))
        replay.tap()
        XCTAssertTrue(app.staticTexts["This is a guided site"].waitForExistence(timeout: 5))
        app.buttons["guided-intro-skip"].tap()
        XCTAssertTrue(app.buttons["show-guided-intro"].waitForExistence(timeout: 5), "back on About")
    }
}
