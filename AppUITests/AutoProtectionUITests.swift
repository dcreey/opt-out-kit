import XCTest

final class AutoProtectionUITests: UITestCase {
    /// Settings, then the automatic opt-out page.
    private func openAutomaticPage(_ app: XCUIApplication) {
        app.tab("Settings", 3).tap()
        let status = app.buttons["auto-activity"]
        XCTAssertTrue(app.scrollUntilExists(status), "Settings opens the automatic opt-out page")
        status.tap()
        XCTAssertTrue(app.buttons["auto-run-now"].waitForExistence(timeout: 10) || app.buttons["activity-count-sent"].waitForExistence(timeout: 10))
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
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
        app.tab("Settings", 3).tap()
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

    /// A run over the real catalog with sending faked (no broker is contacted): a representative sample of 40 sites for a release, every site in the weekly job
    /// (OPTOUT_ALL_SITES=1). The run against fixture brokers that sends for real is `FixtureJourneyUITests.testRunNowFillsAndSendsTheFormOnEachBrokerPage`.
    func testRunNowShowsWhatWasSentAndWhatNeedsYouWithoutTouchingTheInternet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-fake-submit", "-uitest-fake-scan"] + XCUIApplication.fewSites
        app.launch()
        // Give the owner a name and email so forms can be filled.
        app.buttons["profile-button"].tap()
        app.fillRequiredProfile()
        app.buttons["editor-done"].tap()
        app.tab("Settings", 3).tap()
        var scrolls = 0
        while !app.buttons["auto-activity"].isHittable && scrolls < 8 { app.swipeUp(); scrolls += 1 }
        app.buttons["auto-activity"].tap()
        XCTAssertTrue(app.buttons["auto-run-now"].waitForExistence(timeout: 5), "one button runs everything")
        app.buttons["auto-run-now"].tap()
        // The run finishes and reports: a sample of 40 sites for a release (`fewSites`), every site in the weekly end-to-end job.
        let everySite = ProcessInfo.processInfo.environment["OPTOUT_ALL_SITES"] == "1"
        let done = app.buttons["run-report-done"]
        XCTAssertTrue(done.waitForExistence(timeout: everySite ? 5400 : 300), "the run finished and reported")
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
        app.tab("Sites", 1).tap()
        XCTAssertTrue(app.scrollUntilExists(app.buttons["quick-checks"]), "quick checks are low on the Sites tab")
        app.buttons["quick-checks"].tap()
        XCTAssertTrue(app.buttons["answer-paywalled"].waitForExistence(timeout: 5))
        shot(app, "4-quick-check-blocked-by-payment")
        app.buttons["answer-paywalled"].tap()
        XCTAssertTrue(app.staticTexts["answer-saved"].waitForExistence(timeout: 3), "the answer was kept")
    }

    /// A site on the automatic status page must open its page and stay there. (It once bounced straight back: the page declared a navigation destination of
    /// its own while opened by a closure-style link, so SwiftUI built it twice and rejected the push.)
    func testASiteOnTheAutomaticStatusPageOpensItsPageAndStaysThere() throws {
        let app = XCUIApplication()
        let everySite = ProcessInfo.processInfo.environment["OPTOUT_ALL_SITES"] == "1"
        if everySite {
            // The weekly job runs the real catalog with sending faked (no broker is contacted).
            app.launchArguments = ["-uitest-reset", "-uitest-seed-profile", "-uitest-fake-submit", "-uitest-demo-run"]
        } else {
            // Every other run: a real run against fixture brokers (docs/TESTING.md, "End-to-end tests against fixture pages").
            let server = try FixtureBrokers.start()
            app.launchArguments = ["-uitest-reset", "-uitest-seed-profile", "-only-domains", "plain-1.fixture.test,plain-2.fixture.test"] + server.launchArguments
        }
        app.launch()
        if !everySite { openAutomaticPage(app); app.buttons["auto-run-now"].tap() }
        // The whole run, then its result sheet.
        let done = app.buttons["run-report-done"]
        XCTAssertTrue(done.waitForExistence(timeout: everySite ? 5400 : 120), "the run finished and reported")
        done.tap()
        if everySite { openAutomaticPage(app) }
        let status = app.buttons["activity-count-sent"]
        _ = status
        XCTAssertTrue(app.buttons["activity-count-sent"].waitForExistence(timeout: 10), "the page opens with the three counts")
        shot(app, "5a-activity-page-folded")
        // The groups are folded except "Need you"; tapping a count opens its list.
        app.buttons["activity-count-sent"].tap()
        // One named row, not a query over every row: on a slow machine that query timed out ("Timed out while evaluating UI query") in the first 25 sites' list.
        let row = everySite ? app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'period-site-'")).firstMatch : app.buttons["period-site-plain-1.fixture.test"]
        XCTAssertTrue(app.scrollUntilExists(row), "the opened group lists its sites")
        shot(app, "5b-activity-page-sent-open")
        row.tap()
        // A typed query: a query over every element timed out ("Timed out while evaluating UI query") on GitHub's slower simulator.
        let state = app.staticTexts["site-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 5), "the site's page opened")
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertTrue(state.exists, "and it stayed: the push did not bounce back")
        shot(app, "5-site-opened-from-the-status-page")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["run-dates"].waitForExistence(timeout: 5), "back on the status page")
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
    func testANewPersonGetsTheAutomaticPassFirstAndTheSemiAutomatedQueueAfterIt() throws {
        let server = try FixtureBrokers.start()
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile", "-uitest-auto-on", "-only-domains", "plain-1.fixture.test,turnstile-1.fixture.test"] + server.launchArguments
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["first-pass-step2"].waitForExistence(timeout: 15), "step 2 is shown as waiting for step 1")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'kind-'")).firstMatch.exists, "the semi-automated queue is not offered yet")
        shot(app, "6a-new-person-step-1")
        // UI tests do not start runs by themselves (`-uitest-reset`), so the test starts it the way a person can.
        app.buttons["first-pass-start"].tap()
        // The run's pages work out of sight: none is offered to VoiceOver (or to an accessibility query, which waited on the busy page and timed out on GitHub).
        for _ in 0..<6 { XCTAssertFalse(app.webViews.firstMatch.exists, "no hidden page is in the accessibility tree during the run"); Thread.sleep(forTimeInterval: 0.5) }
        let later = app.buttons["run-report-done"]
        XCTAssertTrue(later.waitForExistence(timeout: 120), "the first pass finishes and says what it did")
        shot(app, "6b-first-pass-report")
        if later.exists && later.isHittable { later.tap() }          // on a slow machine the report can already have been put away
        // The queue shows what to tackle today (the chooser, or today's task with Continue once a choice is made).
        let opened = app.staticTexts["What do you want to tackle today?"].waitForExistence(timeout: 10) || app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Continue'")).firstMatch.exists
        shot(app, "6c-queue-after-first-pass")
        XCTAssertTrue(opened, "then the semi-automated queue opens")
        XCTAssertFalse(app.descendants(matching: .any)["first-pass-step2"].exists)
        shot(app, "6c-queue-after-first-pass")
        XCTAssertEqual(server.sentSites, ["fx_plain_1"], "the pass sent the plain form and left the one behind a check for the queue")
    }
}
