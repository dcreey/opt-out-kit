import XCTest

/// The Solve-and-send screen on two real directory sites with the fake driver (no site is loaded): skipping on, then back to the earlier site.
final class SolveAndSendUITests: XCTestCase {
    func testPreviousSiteReopensTheEarlierSiteAndNextSiteBringsYouForwardAgain() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile", "-uitest-fake-submit", "-uitest-fake-hold", "-semi-domains", "abovedata.io,accudata.com"]
        app.launch()
        let label = app.staticTexts["assisted-site"]
        XCTAssertTrue(label.waitForExistence(timeout: 20), "the Solve-and-send screen opened")
        let first = label.label

        // "Send it for me" is on by default and can be turned off for the session.
        let box = app.buttons["auto-submit-toggle"]
        XCTAssertTrue(box.waitForExistence(timeout: 10))
        XCTAssertEqual(box.value as? String, "on")
        box.tap()
        XCTAssertEqual(box.value as? String, "off")
        box.tap()
        XCTAssertEqual(box.value as? String, "on")

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
        XCTAssertTrue(words.label.contains("back on this site"), "it says nothing is sent for you: \(words.label)")
        let next = app.buttons["assisted-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        expectation(for: NSPredicate(format: "label == %@", second), evaluatedWith: label)
        waitForExpectations(timeout: 20)
    }

    func testMyDataIsInTheMenuAndOffersEachDetailToCopy() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile", "-uitest-fake-submit", "-uitest-fake-hold", "-semi-domains", "abovedata.io,accudata.com"]
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
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile", "-uitest-fake-submit", "-uitest-fake-hold", "-semi-domains", "abovedata.io,accudata.com", "-show-sent-question"]
        app.launch()
        let alert = app.alerts["Was this sent?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "the question is on screen")
        XCTAssertTrue(alert.buttons["Yes, it was sent"].exists)
        XCTAssertTrue(alert.buttons["No, stay on this page"].exists)
        alert.buttons["No, stay on this page"].tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 2), "answering closes it")
    }

    func testTheFirstGuidedFlowOpensWithAWalkthroughThatCanBePagedThroughOrSkipped() {
        let args = ["-uitest-reset", "-uitest-seed-profile", "-uitest-fake-submit", "-uitest-fake-hold", "-semi-domains", "abovedata.io,accudata.com", "-show-guided-intro"]
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
        app.tabBars.buttons["About"].tap()
        let replay = app.buttons["show-guided-intro"]
        XCTAssertTrue(replay.waitForExistence(timeout: 10))
        replay.tap()
        XCTAssertTrue(app.staticTexts["This is a guided site"].waitForExistence(timeout: 5))
        app.buttons["guided-intro-skip"].tap()
        XCTAssertTrue(app.buttons["show-guided-intro"].waitForExistence(timeout: 5), "back on About")
    }
}
