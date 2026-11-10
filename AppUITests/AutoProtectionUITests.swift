import XCTest

final class AutoProtectionUITests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testFirstRunPageTurnsOnBothSwitchesByDefaultAndSavesTheAnswer() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-onboarding"]
        app.launch()
        for _ in 0..<3 { XCTAssertTrue(app.buttons["onboarding-next"].waitForExistence(timeout: 10)); app.buttons["onboarding-next"].tap() }
        app.enterOnboardingEmail()
        let scan = app.switches["auto-scan-toggle"], opt = app.switches["auto-optout-toggle"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        XCTAssertEqual(scan.value as? String, "1", "daily scan starts on")
        XCTAssertEqual(opt.value as? String, "1", "weekly opt-out starts on")
        shot(app, "1-first-run-automatic-protection")
        app.finishOnboarding()

        app.tabBars.buttons["Settings"].tap()
        let s2 = app.switches["settings-scan-toggle"]
        XCTAssertTrue(app.scrollUntilExists(s2))
        XCTAssertEqual(s2.value as? String, "1")
        XCTAssertEqual(app.switches["settings-optout-toggle"].value as? String, "1")
        shot(app, "2-settings-both-on")
    }

    func testDecliningAtFirstRunTurnsBothOffAndTheQueueBannerDisappears() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-onboarding"]
        app.launch()
        for _ in 0..<3 { app.buttons["onboarding-next"].tap() }
        app.enterOnboardingEmail()
        for id in ["auto-scan-toggle", "auto-optout-toggle"] {
            let t = app.switches[id]; XCTAssertTrue(t.waitForExistence(timeout: 5))
            t.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            XCTAssertEqual(t.value as? String, "0")
        }
        app.finishOnboarding()
        XCTAssertFalse(app.buttons["auto-banner"].exists, "an answer, even no, was given")
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.scrollUntilExists(app.switches["settings-scan-toggle"]))
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
        app.fillRequiredProfile()
        app.buttons["Done"].tap()
        app.tabBars.buttons["Settings"].tap()
        var scrolls = 0
        while !app.buttons["auto-activity"].isHittable && scrolls < 8 { app.swipeUp(); scrolls += 1 }
        app.buttons["auto-activity"].tap()
        XCTAssertTrue(app.buttons["auto-run-now"].waitForExistence(timeout: 5), "one button runs everything")
        app.buttons["auto-run-now"].tap()
        XCTAssertTrue(app.staticTexts["auto-summary"].waitForExistence(timeout: 60))
        shot(app, "3-activity-after-preview")
    }

    func testBlockedByPaymentIsAnAnswerInQuickChecks() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        app.buttons["profile-button"].tap()
        app.fillRequiredProfile()                     // searching needs the profile's legal name, address and the household email
        app.buttons["editor-done"].tap()
        app.tabBars.buttons["Sites"].tap()
        app.buttons["quick-checks"].tap()
        XCTAssertTrue(app.buttons["answer-paywalled"].waitForExistence(timeout: 5))
        shot(app, "4-quick-check-blocked-by-payment")
        app.buttons["answer-paywalled"].tap()
        XCTAssertTrue(app.staticTexts["earned"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["2 pts"].waitForExistence(timeout: 3))
    }

    /// A site on the automatic status page must open its page and stay there. (It once bounced straight back: the page declared a navigation destination of
    /// its own while opened by a closure-style link, so SwiftUI built it twice and rejected the push.)
    func testASiteOnTheAutomaticStatusPageOpensItsPageAndStaysThere() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile", "-uitest-fake-submit", "-uitest-demo-run"]
        app.launch()
        let done = app.buttons["run-report-done"]
        if done.waitForExistence(timeout: 120) { done.tap() }          // the run's result sheet comes up when it finishes
        let status = app.buttons["home-auto-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30), "the home page shows the period standing")
        status.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'period-site-'")).firstMatch
        XCTAssertTrue(app.scrollUntilExists(row), "the status page lists every site")
        row.tap()
        let state = app.descendants(matching: .any)["site-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 5), "the site's page opened")
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertTrue(state.exists, "and it stayed: the push did not bounce back")
        shot(app, "5-site-opened-from-the-status-page")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["period-summary"].waitForExistence(timeout: 5), "back on the status page")
    }

    func testTheBirthdateIsChosenYearThenMonthThenDayAndIsRequired() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-require-birthdate"]
        app.launch()
        app.buttons["profile-button"].tap()
        let year = app.descendants(matching: .any)["birth-year"]
        XCTAssertTrue(app.scrollUntilExists(year), "the profile asks for a birthdate")
        XCTAssertFalse(app.descendants(matching: .any)["birth-month"].isEnabled, "month waits for the year")
        XCTAssertFalse(app.descendants(matching: .any)["birth-day"].isEnabled, "day waits for the month")
        XCTAssertTrue(app.staticTexts["missing-details"].exists || app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'birthdate'")).count > 0, "and says it is still needed")
    }
}
