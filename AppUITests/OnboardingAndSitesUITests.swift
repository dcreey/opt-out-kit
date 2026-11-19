import XCTest

final class OnboardingAndSitesUITests: XCTestCase {
    func testWalkthroughShowsOnFirstInstallAndCanBeFinished() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-onboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding-next"].waitForExistence(timeout: 10))
        for _ in 0..<3 { app.buttons["onboarding-next"].tap() }
        app.enterOnboardingEmail()
        app.finishOnboarding()
        app.completeProfileGate()
        // A new person: the first automatic pass is the first step (it starts by itself once the profile is in), and the semi-automated queue waits for it.
        XCTAssertTrue(app.descendants(matching: .any)["first-pass-step2"].waitForExistence(timeout: 10), "the queue starts with the automatic pass")
    }

    func testWalkthroughOffersTheAdvertisingIDAndLetsYouPassIt() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-onboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding-next"].waitForExistence(timeout: 10))
        for _ in 0..<3 { app.buttons["onboarding-next"].tap() }
        app.enterOnboardingEmail()
        XCTAssertTrue(app.staticTexts["Automatic protection"].waitForExistence(timeout: 5), "passing the advertising ID page leads on to automatic protection")
        app.finishOnboarding()
    }

    func testChoosingCaliforniaExplainsItsLawsAndOffersDropInTheQueue() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-onboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding-next"].waitForExistence(timeout: 10))
        for _ in 0..<3 { app.buttons["onboarding-next"].tap() }
        let field = app.textFields["onboarding-email"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("pat@example.com")
        app.buttons["onboarding-next"].tap()
        let state = app.descendants(matching: .any)["onboarding-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        state.tap()
        app.buttons["California"].tap()
        let rules = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'requires data brokers to register themselves'")).firstMatch
        XCTAssertTrue(rules.waitForExistence(timeout: 5), "the page explains California's registry")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'automatic opt-out for all of these registries'")).firstMatch.exists)
        // Reading it is required: Next stays off until the last line (the review date) has been on screen.
        app.assertNextWaitsForTheEnd(of: app.staticTexts["state-rules-reviewed"], "California's rules")
        XCTAssertTrue(app.staticTexts["state-rules-reviewed"].exists, "the review date is the last line")
        app.buttons["onboarding-next"].tap()
        XCTAssertTrue(app.staticTexts["Accept site terms for you?"].waitForExistence(timeout: 5), "the walkthrough asks about accepting terms")
        // Either it is not available yet (and says so), or reviewed terms exist and it can be allowed.
        XCTAssertTrue(app.descendants(matching: .any)["onboarding-terms-status"].waitForExistence(timeout: 5) || app.buttons["onboarding-terms-allow"].exists,
                      "and says whether that is available")
        app.buttons["onboarding-next"].tap()
        // The advertising ID page, passed without sharing it; then the automatic-protection page and the last one.
        XCTAssertTrue(app.buttons["adid-allow"].waitForExistence(timeout: 5) || app.staticTexts["adid-allowed"].exists)
        app.tapNextOnboarding()
        app.finishOnboarding()
        app.completeProfileGate(city: "Los Angeles", state: "CA", zip: "90001")          // an address in California too

        // In California the first step is the DROP request, then the automatic pass.
        XCTAssertTrue(app.descendants(matching: .any)["first-pass-platform"].waitForExistence(timeout: 10), "the queue leads with California DROP")
        XCTAssertTrue(app.descendants(matching: .any)["first-pass-step2"].exists, "then the automatic pass")
        app.tabBars.buttons["Sites"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Up next'")).firstMatch.waitForExistence(timeout: 5), "the Sites page lists the sites up next, not every task")
        app.searchSites("spokeo")
        XCTAssertTrue(app.buttons["task-platform-ca-drop"].waitForExistence(timeout: 5), "Spokeo is part of the DROP task, not a separate one")
        XCTAssertFalse(app.buttons["task-flow-spokeo"].exists)
    }

    func testThePageDotsSitBelowTheContentNotOnTopOfIt() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-onboarding"]
        app.launch()
        let next = app.buttons["onboarding-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        let dots = app.otherElements["onboarding-page-dots"]
        XCTAssertTrue(dots.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(dots.frame.maxY, next.frame.minY + 1, "dots above the buttons")
        let body = app.scrollViews.firstMatch.frame
        XCTAssertGreaterThanOrEqual(dots.frame.minY, body.maxY - 1, "dots below the scrolling content, not over it")
    }

    func testTheWalkthroughOpensWithAutomaticRemovalAndHasNoSitePages() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-onboarding"]
        app.launch()
        XCTAssertTrue(app.staticTexts["We remove your data for you"].waitForExistence(timeout: 10), "the first page is automatic removal")
        XCTAssertFalse(app.staticTexts["Work through a site"].exists)
        XCTAssertFalse(app.staticTexts["Track every site"].exists)
    }

    func testFirstVisitsShowAShortGuideOnceInsteadOfWalkthroughPages() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-coach"]
        app.launch()
        app.tabBars.buttons["Sites"].tap()
        XCTAssertTrue(app.buttons["coach-done"].waitForExistence(timeout: 5), "the first visit to Sites explains the queue")
        app.buttons["coach-done"].tap()
        XCTAssertFalse(app.buttons["coach-done"].waitForExistence(timeout: 1))
        app.tabBars.buttons["Queue"].tap()
        app.tabBars.buttons["Sites"].tap()
        XCTAssertFalse(app.buttons["coach-done"].waitForExistence(timeout: 2), "and only the first time")
    }

    func testEveryKeyboardHasADoneButtonThatPutsItAway() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        app.tabBars.buttons["Sites"].tap()
        let open = app.buttons["sites-search"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(app.textFields["site-search-field"].waitForExistence(timeout: 5), "the search field opens the search screen")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "with its field focused")
        app.textFields["site-search-field"].typeText("spo")
        XCTAssertTrue(app.buttons["keyboard-done"].waitForExistence(timeout: 3), "a Done button sits above the keyboard")
        app.buttons["keyboard-done"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1), "and puts the keyboard away")
    }

    func testTheSitesTabShowsTenPerGroupAndSeeAllOpensTheSearchWithThatStatus() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        app.tabBars.buttons["Sites"].tap()
        let all = app.buttons["all-todo-sites"]
        XCTAssertTrue(app.scrollUntilExists(all, maxSwipes: 8), "more than ten sites to do: a link to see them all")
        all.tap()
        let status = app.buttons["filter-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("Up next"), "the status is chosen already: \(status.label)")
        XCTAssertTrue(app.buttons["filter-clear"].exists, "and can be cleared")
        for id in ["filter-region", "filter-type", "filter-tracks", "filter-sells", "filter-method"] {
            XCTAssertTrue(app.buttons[id].exists, id)
        }
        XCTAssertFalse(app.keyboards.firstMatch.exists, "opened from a group, the field is not focused")
        let count = app.staticTexts["site-search-count"].label
        app.buttons["filter-region"].tap()
        let choice = app.buttons["Not in your area"]
        XCTAssertTrue(choice.waitForExistence(timeout: 3))
        choice.tap()
        XCTAssertTrue(app.buttons["filter-region"].label.contains("Not in your area"), "the chip shows the choice: \(app.buttons["filter-region"].label)")
        XCTAssertTrue(app.buttons["filter-status"].label.contains("Up next"), "and the status stays chosen")
        XCTAssertNotEqual(app.staticTexts["site-search-count"].label, count, "the list narrows")
    }

    func testAStateWithNoLawPointsToStrongerStatesWithExamples() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-onboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding-next"].waitForExistence(timeout: 10))
        for _ in 0..<3 { app.buttons["onboarding-next"].tap() }
        let field = app.textFields["onboarding-email"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("pat@example.com")
        app.buttons["onboarding-next"].tap()
        let state = app.descendants(matching: .any)["onboarding-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 5)); state.tap()
        app.buttons["Alaska"].tap()
        var swipes = 0
        let example = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'In California, one free request'")).firstMatch
        while !example.exists && swipes < 12 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(example.exists, "Alaska has no broker registry, so the page shows what California offers")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'no comprehensive privacy law'")).firstMatch.exists)
    }

    func testTheDeviceLanguageIsUsedAndTheWalkthroughCanSwitchLanguage() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-onboarding", "-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Nous retirons vos données pour vous"].waitForExistence(timeout: 10), "French from the device language")
        // The picker on the first page switches the whole app at once.
        app.buttons["onboarding-language"].tap()
        app.buttons["Español"].tap()
        XCTAssertTrue(app.staticTexts["Eliminamos sus datos por usted"].waitForExistence(timeout: 5), "now Spanish")
        app.buttons["onboarding-language"].tap()
        app.buttons["Deutsch"].tap()
        XCTAssertTrue(app.staticTexts["Wir entfernen Ihre Daten für Sie"].waitForExistence(timeout: 5), "now German")
    }

    func testChoosingAnotherCountryShowsItsLawsAndRegulatorAndNeedsReadingToo() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-onboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding-next"].waitForExistence(timeout: 10))
        for _ in 0..<3 { app.buttons["onboarding-next"].tap() }
        let field = app.textFields["onboarding-email"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("pat@example.com")
        app.buttons["onboarding-next"].tap()
        let country = app.buttons["onboarding-country"]
        XCTAssertTrue(country.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding-state"].exists, "the United States is the default here, so its states are offered")
        country.tap()
        app.buttons["Uruguay"].tap()             // the menu opens scrolled to the selected United States, so pick a country in view
        XCTAssertFalse(app.buttons["onboarding-state"].exists, "only the US has states")
        let law = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Uruguay has a data protection law'")).firstMatch
        XCTAssertTrue(law.waitForExistence(timeout: 5))
        let regulator = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'gub.uy'")).firstMatch
        app.assertNextWaitsForTheEnd(of: regulator, "Uruguay's rules")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'gub.uy'")).firstMatch.exists, "the regulator is named")
    }

    func testNotLivingInCaliforniaHidesIt() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile", "-uitest-auto-on"]          // the made-up profile lives in Illinois
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["first-pass-start"].waitForExistence(timeout: 10), "the app's own run comes first when there is no official service")
        XCTAssertFalse(app.descendants(matching: .any)["first-pass-platform"].exists, "and California's DROP is not offered")
    }

    func testWalkthroughDoesNotReappearOnNextLaunch() {
        let first = XCUIApplication()
        first.launchArguments = ["-uitest-reset", "-uitest-onboarding"]
        first.launch()
        for _ in 0..<3 { first.tapNextOnboarding() }          // there is no Skip: each page is scrolled to its end, then Next
        first.enterOnboardingEmail()
        first.finishOnboarding()
        first.completeProfileGate()
        first.terminate()

        let again = XCUIApplication()
        again.launch()
        XCTAssertTrue(again.buttons["profile-button"].waitForExistence(timeout: 10), "the app opens on the queue")
        XCTAssertFalse(again.buttons["onboarding-next"].exists)
    }

    func testSitesTabSearchAndStatus() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        app.tabBars.buttons["Sites"].tap()

        // Search finds a brand covered by PeopleConnect.
        app.searchSites("truthfinder")
        XCTAssertTrue(app.buttons["task-flow-peopleconnect"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["task-flow-peopleconnect"].exists)
        XCTAssertFalse(app.buttons["task-flow-spokeo"].exists)

        app.buttons["task-flow-peopleconnect"].tap()
        XCTAssertTrue(app.staticTexts["Not started"].waitForExistence(timeout: 5))
    }

    func testAboutTabReplaysWalkthrough() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["show-walkthrough"].tap()
        XCTAssertTrue(app.buttons["onboarding-next"].waitForExistence(timeout: 5))
    }
}

final class DirectoryUITests: XCTestCase {
    /// The Sites tab never shows a site's tier (an internal measure). Its groups (Done, Skipped, Up next) have their own test,
    /// `testTheSitesTabShowsTenPerGroupAndSeeAllOpensTheSearchWithThatStatus`.
    func testTheSitesTabShowsNoTiers() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        app.tabBars.buttons["Sites"].tap()
        XCTAssertTrue(app.collectionViews["sites-list"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'tier'")).count, 0, "tiers are not shown")
    }

    func testSitesTabListsAndSearchesTheDirectory() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        app.tabBars.buttons["Sites"].tap()
        app.searchSites("texascourtrecords")
        // A site that leads a group sharing one opt-out is listed as its task, any other by its domain.
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'task-site-' OR identifier BEGINSWITH 'site-texascourtrecords'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the search finds the site")
        row.tap()
        // How the site is opted out is folded under "More details" on its page.
        let more = app.buttons["More details"]
        XCTAssertTrue(app.scrollUntilExists(more), "the site page has its details")
        more.tap()
        let shared = app.staticTexts["Shared opt-out"]
        for _ in 0..<4 where !shared.exists { app.swipeUp() }
        XCTAssertTrue(shared.waitForExistence(timeout: 5))
        // The real form the profiler found: it posts to the shared members host.
        let submits = app.staticTexts["Submits to members.courtrecords.us"]
        for _ in 0..<4 where !submits.exists { app.swipeUp() }
        XCTAssertTrue(submits.waitForExistence(timeout: 5))
    }
}

final class ExposureScanUITests: XCTestCase {
    func testScanShowsGroupedResultsWithoutTouchingTheNetwork() {
        let app = XCUIApplication()
        // A complete made-up profile, so the check has someone to search for (typing a profile is tested in ProfileEditorUITests).
        app.launchArguments = ["-uitest-reset", "-uitest-fake-scan", "-uitest-seed-profile"]
        app.launch()

        app.tabBars.buttons["Sites"].tap()
        XCTAssertTrue(app.scrollUntilExists(app.buttons["scan-exposure"]), "the scan is low on the Sites tab")
        app.buttons["scan-exposure"].tap()
        app.buttons["start-scan"].tap()
        XCTAssertTrue(app.staticTexts["scan-summary"].waitForExistence(timeout: 30))
    }
}

final class QuickCheckUITests: XCTestCase {
    func testLookingAtASiteEarnsPoints() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile"]          // looking a site up needs a complete profile
        app.launch()
        app.tabBars.buttons["Sites"].tap()
        XCTAssertTrue(app.scrollUntilExists(app.buttons["quick-checks"]), "quick checks are low on the Sites tab")
        app.buttons["quick-checks"].tap()
        XCTAssertTrue(app.buttons["answer-clean"].waitForExistence(timeout: 5))
        app.buttons["answer-clean"].tap()
        XCTAssertTrue(app.staticTexts["earned"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["5 pts"].waitForExistence(timeout: 3))
    }
}
