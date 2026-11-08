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
        XCTAssertTrue(app.buttons["next-automatic"].waitForExistence(timeout: 5), "the ranked queue is visible after the walkthrough")
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
        // Reading it is required: Next stays off until the person has scrolled to the bottom.
        XCTAssertFalse(app.buttons["onboarding-next"].isEnabled, "cannot continue before reading the state's rules")
        XCTAssertTrue(app.staticTexts["onboarding-state-scroll-hint"].exists)
        var swipes = 0
        while !app.buttons["onboarding-next"].isEnabled && swipes < 12 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(app.buttons["onboarding-next"].isEnabled, "scrolling to the end unlocks Next")
        XCTAssertTrue(app.staticTexts["state-rules-reviewed"].exists, "the review date is the last line")
        app.buttons["onboarding-next"].tap()
        XCTAssertTrue(app.staticTexts["Accept site terms for you?"].waitForExistence(timeout: 5), "the walkthrough asks about accepting terms")
        XCTAssertTrue(app.staticTexts["onboarding-terms-status"].waitForExistence(timeout: 5), "and says whether that is available")
        app.buttons["onboarding-next"].tap()
        app.finishOnboarding()

        XCTAssertTrue(app.buttons["next-platform-ca-drop"].waitForExistence(timeout: 5), "the queue leads with California DROP")
        XCTAssertTrue(app.scrollUntilExists(app.buttons["band-1"], maxSwipes: 6), "and its band is the first")
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
        XCTAssertTrue(app.staticTexts["We find and remove your data for you"].waitForExistence(timeout: 10), "the first page is automatic scanning and removal")
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
        let search = app.textFields["sites-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("spo")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["keyboard-done"].waitForExistence(timeout: 3), "a Done button sits above the keyboard")
        app.buttons["keyboard-done"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1), "and puts the keyboard away")
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
        XCTAssertTrue(app.staticTexts["Reprenez vos données"].waitForExistence(timeout: 10), "French from the device language")
        // The picker on the first page switches the whole app at once.
        app.buttons["onboarding-language"].tap()
        app.buttons["Español"].tap()
        XCTAssertTrue(app.staticTexts["Recupera tus datos"].waitForExistence(timeout: 5), "now Spanish")
        app.buttons["onboarding-language"].tap()
        app.buttons["Deutsch"].tap()
        XCTAssertTrue(app.staticTexts["Holen Sie sich Ihre Daten zurück"].waitForExistence(timeout: 5), "now German")
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
        XCTAssertFalse(app.buttons["onboarding-next"].isEnabled, "the rules have to be read")
        var swipes = 0
        while !app.buttons["onboarding-next"].isEnabled && swipes < 12 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(app.buttons["onboarding-next"].isEnabled)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'gub.uy'")).firstMatch.exists, "the regulator is named")
    }

    func testNotLivingInCaliforniaHidesIt() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        XCTAssertTrue(app.buttons["next-automatic"].waitForExistence(timeout: 10), "the app's own run leads when there is no official service")
        XCTAssertFalse(app.buttons["next-platform-ca-drop"].exists)
    }

    func testWalkthroughDoesNotReappearOnNextLaunch() {
        let first = XCUIApplication()
        first.launchArguments = ["-uitest-reset", "-uitest-onboarding"]
        first.launch()
        for _ in 0..<3 { first.tapNextOnboarding() }          // there is no Skip: each page is scrolled to its end, then Next
        first.enterOnboardingEmail()
        first.finishOnboarding()
        first.terminate()

        let again = XCUIApplication()
        again.launch()
        XCTAssertTrue(again.buttons["next-automatic"].waitForExistence(timeout: 10))
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
        app.tabBars.buttons["About"].tap()
        app.buttons["show-walkthrough"].tap()
        XCTAssertTrue(app.buttons["onboarding-next"].waitForExistence(timeout: 5))
    }
}

final class DirectoryUITests: XCTestCase {
    func testSitesAreGroupedByWhoDoesTheWorkAndShowNoTiers() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        app.tabBars.buttons["Sites"].tap()
        let list = app.collectionViews["sites-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let auto = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Automatic opt-out ('")).firstMatch
        XCTAssertTrue(auto.waitForExistence(timeout: 5), "an automatic section with its site count")
        XCTAssertTrue(auto.label.hasSuffix("sites)"))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'tier'")).count, 0, "tiers are not shown")
    }

    func testSitesTabListsAndSearchesTheDirectory() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        app.tabBars.buttons["Sites"].tap()
        app.searchSites("texascourtrecords")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'task-site-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
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
        app.launchArguments = ["-uitest-reset", "-uitest-fake-scan"]
        app.launch()
        // Give the default person a name so the check has something to search for.
        app.buttons["profile-button"].tap()
        app.fillRequiredProfile()
        app.buttons["Done"].tap()

        app.tabBars.buttons["Sites"].tap()
        app.buttons["scan-exposure"].tap()
        app.buttons["start-scan"].tap()
        XCTAssertTrue(app.staticTexts["scan-summary"].waitForExistence(timeout: 30))
    }
}

final class QuickCheckUITests: XCTestCase {
    func testLookingAtASiteEarnsPoints() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        app.tabBars.buttons["Sites"].tap()
        XCTAssertTrue(app.staticTexts["Exposed"].waitForExistence(timeout: 5))
        app.buttons["quick-checks"].tap()
        XCTAssertTrue(app.buttons["answer-clean"].waitForExistence(timeout: 5))
        app.buttons["answer-clean"].tap()
        XCTAssertTrue(app.staticTexts["earned"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["5 pts"].waitForExistence(timeout: 3))
    }
}
