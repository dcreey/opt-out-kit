import XCTest

final class AutoProtectionUITests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// The first-run page has one switch, automatic opt-out requests, on by default; the answer is saved and shown in Settings. (There was a daily
    /// scan switch too; the scan is no longer automatic.)
    func testFirstRunPageTurnsAutomaticOptOutOnByDefaultAndSavesTheAnswer() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-onboarding"]
        app.launch()
        for _ in 0..<3 { XCTAssertTrue(app.buttons["onboarding-next"].waitForExistence(timeout: 10)); app.tapNextOnboarding() }
        app.enterOnboardingEmail()
        let opt = app.switches["auto-optout-toggle"]
        XCTAssertTrue(app.scrollUntilExists(opt), "the automatic protection page")
        XCTAssertEqual(opt.value as? String, "1", "automatic opt-out starts on")
        XCTAssertFalse(app.switches["auto-scan-toggle"].exists, "there is no automatic scan to turn on")
        shot(app, "1-first-run-automatic-protection")
        app.finishOnboarding()
        // Turned on, it needs the legal name and current address before it can start: the profile gate asks for them next.
        app.completeProfileGate()

        app.tabBars.buttons["Settings"].tap()
        let setting = app.switches["settings-optout-toggle"]
        XCTAssertTrue(app.scrollUntilExists(setting))
        XCTAssertEqual(setting.value as? String, "1", "Settings shows it on")
        shot(app, "2-settings-on")
    }

    func testDecliningAtFirstRunTurnsItOffAndTheQueueBannerDisappears() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-onboarding"]
        app.launch()
        for _ in 0..<3 { XCTAssertTrue(app.buttons["onboarding-next"].waitForExistence(timeout: 10)); app.tapNextOnboarding() }
        app.enterOnboardingEmail()
        let opt = app.switches["auto-optout-toggle"]
        XCTAssertTrue(app.scrollUntilExists(opt))
        app.setSwitch(opt, on: false)
        app.finishOnboarding()
        XCTAssertFalse(app.buttons["auto-banner"].exists, "an answer, even no, was given")
        app.tabBars.buttons["Settings"].tap()
        let setting = app.switches["settings-optout-toggle"]
        XCTAssertTrue(app.scrollUntilExists(setting))
        XCTAssertEqual(setting.value as? String, "0", "Settings shows it off")
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
        app.launchArguments = ["-uitest-reset", "-uitest-fake-submit", "-uitest-fake-scan"] + XCUIApplication.fewSites
        app.launch()
        // Give the owner a name and email so forms can be filled.
        app.buttons["profile-button"].tap()
        app.fillRequiredProfile()
        app.buttons["editor-done"].tap()
        app.tabBars.buttons["Settings"].tap()
        var scrolls = 0
        while !app.buttons["auto-activity"].isHittable && scrolls < 8 { app.swipeUp(); scrolls += 1 }
        app.buttons["auto-activity"].tap()
        XCTAssertTrue(app.buttons["auto-run-now"].waitForExistence(timeout: 5), "one button runs everything")
        app.buttons["auto-run-now"].tap()
        // The run finishes and reports: 25 sites in CI (`fewSites`), every site in the weekly end-to-end job.
        let everySite = ProcessInfo.processInfo.environment["OPTOUT_ALL_SITES"] == "1"
        let done = app.buttons["run-report-done"]
        XCTAssertTrue(done.waitForExistence(timeout: everySite ? 5400 : 120), "the run finished and reported")
        shot(app, "3a-run-report")
        done.tap()
        let sent = app.buttons["activity-count-sent"]
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        let start = Date()
        while sent.label.hasPrefix("0") && Date().timeIntervalSince(start) < 10 { Thread.sleep(forTimeInterval: 1) }
        XCTAssertFalse(sent.label.hasPrefix("0"), "the page counts the sites that were sent")
        shot(app, "3-activity-after-preview")
    }

    func testBlockedByPaymentIsAnAnswerInQuickChecks() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile"]          // searching needs a complete profile; typing one is tested elsewhere
        app.launch()
        app.tabBars.buttons["Sites"].tap()
        XCTAssertTrue(app.scrollUntilExists(app.buttons["quick-checks"]), "quick checks are low on the Sites tab")
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
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile", "-uitest-fake-submit", "-uitest-demo-run"] + XCUIApplication.fewSites
        app.launch()
        // The whole run, then its result sheet: 25 sites in CI, every site in the weekly end-to-end job.
        let done = app.buttons["run-report-done"]
        let everySite = ProcessInfo.processInfo.environment["OPTOUT_ALL_SITES"] == "1"
        XCTAssertTrue(done.waitForExistence(timeout: everySite ? 5400 : 120), "the run finished and reported")
        done.tap()
        app.tabBars.buttons["Settings"].tap()
        let status = app.buttons["auto-activity"]
        XCTAssertTrue(app.scrollUntilExists(status), "Settings opens the automatic opt-out page")
        status.tap()
        XCTAssertTrue(app.buttons["activity-count-sent"].waitForExistence(timeout: 10), "the page opens with the three counts")
        shot(app, "5a-activity-page-folded")
        // The groups are folded except "Need you"; tapping a count opens its list.
        app.buttons["activity-count-sent"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'period-site-'")).firstMatch
        XCTAssertTrue(app.scrollUntilExists(row), "the opened group lists its sites")
        shot(app, "5b-activity-page-sent-open")
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

    /// A new person: the automatic pass goes first and the semi-automated queue waits for it, then opens with the sites that need a person.
    func testANewPersonGetsTheAutomaticPassFirstAndTheSemiAutomatedQueueAfterIt() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile", "-uitest-auto-on", "-uitest-fake-submit", "-only-domains", "abovedata.io,acronymix.com"] + XCUIApplication.fewSites
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["first-pass-step2"].waitForExistence(timeout: 15), "step 2 is shown as waiting for step 1")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'kind-'")).firstMatch.exists, "the semi-automated queue is not offered yet")
        shot(app, "6a-new-person-step-1")
        // UI tests do not start runs by themselves (`-uitest-reset`), so the test starts it the way a person can.
        app.buttons["first-pass-start"].tap()
        let later = app.buttons["run-report-done"]
        XCTAssertTrue(later.waitForExistence(timeout: 120), "the first pass finishes and says what it did")
        shot(app, "6b-first-pass-report")
        if later.exists && later.isHittable { later.tap() }          // on a slow machine the report can already have been put away
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'kind-'")).firstMatch.waitForExistence(timeout: 10), "then the semi-automated queue opens")
        XCTAssertFalse(app.descendants(matching: .any)["first-pass-step2"].exists)
        shot(app, "6c-queue-after-first-pass")
    }
}
