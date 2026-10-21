import XCTest

final class AutoProtectionUITests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testFirstRunPageTurnsOnBothSwitchesByDefaultAndSavesTheAnswer() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-onboarding"]
        app.launch()
        for _ in 0..<5 { XCTAssertTrue(app.buttons["onboarding-next"].waitForExistence(timeout: 10)); app.buttons["onboarding-next"].tap() }
        let scan = app.switches["auto-scan-toggle"], opt = app.switches["auto-optout-toggle"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        XCTAssertEqual(scan.value as? String, "1", "daily scan starts on")
        XCTAssertEqual(opt.value as? String, "1", "weekly opt-out starts on")
        shot(app, "1-first-run-automatic-protection")
        app.buttons["onboarding-done"].tap()

        app.tabBars.buttons["About"].tap()
        let s2 = app.switches["settings-scan-toggle"]
        XCTAssertTrue(s2.waitForExistence(timeout: 5))
        XCTAssertEqual(s2.value as? String, "1")
        XCTAssertEqual(app.switches["settings-optout-toggle"].value as? String, "1")
        shot(app, "2-settings-both-on")
    }

    func testDecliningAtFirstRunTurnsBothOffAndTheQueueBannerDisappears() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-onboarding"]
        app.launch()
        for _ in 0..<5 { app.buttons["onboarding-next"].tap() }
        for id in ["auto-scan-toggle", "auto-optout-toggle"] {
            let t = app.switches[id]; XCTAssertTrue(t.waitForExistence(timeout: 5))
            t.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            XCTAssertEqual(t.value as? String, "0")
        }
        app.buttons["onboarding-done"].tap()
        XCTAssertFalse(app.buttons["auto-banner"].exists, "an answer, even no, was given")
        app.tabBars.buttons["About"].tap()
        XCTAssertEqual(app.switches["settings-scan-toggle"].value as? String, "0")
    }

    func testSkippingTheWalkthroughLeavesAQueueBannerThatOffersToTurnItOn() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        XCTAssertTrue(app.buttons["auto-banner"].waitForExistence(timeout: 10))
        app.buttons["auto-banner"].tap()
        app.buttons["auto-turn-on"].tap()
        XCTAssertFalse(app.buttons["auto-banner"].waitForExistence(timeout: 2))
    }

    func testRunNowShowsWhatWasSentAndWhatNeedsYouWithoutTouchingTheInternet() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-fake-submit", "-uitest-fake-scan"]
        app.launch()
        // Give the owner a name and email so forms can be filled.
        app.buttons["profile-button"].tap()
        let name = app.textFields["name-0"]; XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Pat Example")
        app.buttons["Done"].tap()
        app.tabBars.buttons["About"].tap()
        var scrolls = 0
        while !app.buttons["auto-activity"].isHittable && scrolls < 8 { app.swipeUp(); scrolls += 1 }
        app.buttons["auto-activity"].tap()
        XCTAssertTrue(app.buttons["auto-preview"].waitForExistence(timeout: 5))
        app.buttons["auto-preview"].tap()
        XCTAssertTrue(app.staticTexts["auto-summary"].waitForExistence(timeout: 60))
        shot(app, "3-activity-after-preview")
    }

    func testBlockedByPaymentIsAnAnswerInQuickChecks() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        app.tabBars.buttons["Sites"].tap()
        app.buttons["quick-checks"].tap()
        XCTAssertTrue(app.buttons["answer-paywalled"].waitForExistence(timeout: 5))
        shot(app, "4-quick-check-blocked-by-payment")
        app.buttons["answer-paywalled"].tap()
        XCTAssertTrue(app.staticTexts["earned"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["2 pts"].waitForExistence(timeout: 3))
    }
}
