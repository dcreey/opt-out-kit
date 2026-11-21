import XCTest

extension XCUIApplication {
    /// The Sites tab shows only a few sites, so find one by search: the tab's search field opens the search screen, whose field takes the text.
    func searchSites(_ text: String) {
        let open = buttons["sites-search"]
        // Right after another screen was put away the tab can still be showing it: tapping the tab again brings its first screen back.
        if !open.waitForExistence(timeout: 5) { tabBars.buttons["Sites"].tap() }
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let search = textFields["site-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeTextChecked(text)
    }
}

extension XCUIApplication {
    /// With the profile editor open: fills the required details (legal name, current address and, for the owner, the email)
    /// with a made-up person. Pass `email: nil` for a relative's profile, which has no email field.
    func fillRequiredProfile(first: String = "Pat", last: String = "Example", street: String = "1 Main St", city: String = "Springfield",
                             state: String = "IL", zip: String = "62701", email: String? = "pat@example.com") {
        func type(_ id: String, _ text: String) {
            let f = textFields[id]
            var tries = 0
            while !f.exists && tries < 10 { swipeDown(); tries += 1 }       // the form may be scrolled down
            XCTAssertTrue(f.waitForExistence(timeout: 5), id)
            if (f.value as? String) == text { return }
            f.tap(); f.typeTextChecked(text)
        }
        type("legal-first", first); type("legal-last", last)
        type("current-street", street); type("current-city", city); chooseState(state); type("current-zip", zip)
        if let email { type("contact-email", email) }
    }
}

extension XCUIApplication {
    /// Chooses a state (two-letter code) in the profile editor's state menu.
    func chooseState(_ code: String) {
        let menu = buttons["current-state"].exists ? buttons["current-state"] : descendants(matching: .any)["current-state"]
        var tries = 0
        while !menu.exists && tries < 10 { swipeDown(); tries += 1 }
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "current-state")
        if (menu.value as? String)?.contains(code) == true || menu.label.contains(code) { return }
        menu.tap()
        let item = descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH %@", "(\(code))")).firstMatch
        // A short menu (the keyboard is up) shows only the first states: scroll within it until the state is there.
        let first = descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH %@", "(AL)")).firstMatch
        var swipes = 0
        while !item.waitForExistence(timeout: 1) && swipes < 8 { (first.exists ? first : item).swipeUp(); swipes += 1 }
        XCTAssertTrue(item.waitForExistence(timeout: 5), "state \(code) in the menu")
        item.tap()          // the menu scrolls to it
    }

    /// On the walkthrough's email page (the sixth): types the required email address and continues.
    func enterOnboardingEmail(_ email: String = "pat@example.com") {
        let field = textFields["onboarding-email"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(buttons["onboarding-next"].isEnabled, "cannot go on without an email address")
        field.tap(); field.typeTextChecked(email)
        XCTAssertTrue(buttons["onboarding-next"].isEnabled)
        tapNextOnboarding()
        // The next page asks where the person lives (optional; the state is asked only for the United States); move past it.
        XCTAssertTrue(descendants(matching: .any)["onboarding-country"].waitForExistence(timeout: 5))
        tapNextOnboarding()
        // Then the terms page (accepting site terms for you); move past it without allowing anything.
        XCTAssertTrue(staticTexts["Accept site terms for you?"].waitForExistence(timeout: 5))
        tapNextOnboarding()
        // Then the advertising ID page, which can be passed without sharing it.
        XCTAssertTrue(buttons["adid-allow"].waitForExistence(timeout: 5) || staticTexts["adid-allowed"].exists)
        tapNextOnboarding()
    }

    /// From the automatic-protection page: on to the last page, which points to the Settings tab, and Start.
    func finishOnboarding() {
        tapNextOnboarding()
        XCTAssertTrue(staticTexts["Your settings are in Settings"].waitForExistence(timeout: 5), "the last page points to the Settings tab")
        buttons["onboarding-done"].tap()
    }
}

extension XCUIApplication {
    /// Scrolls a long list (the lazy SwiftUI List renders rows only near the screen) until the element exists.
    @discardableResult
    func scrollUntilExists(_ element: XCUIElement, maxSwipes: Int = 12) -> Bool {
        if element.waitForExistence(timeout: 2) { return true }          // the screen may still be appearing
        var n = 0
        while !element.waitForExistence(timeout: 0.5) && n < maxSwipes { swipeUp(); n += 1 }
        return element.exists
    }
}

extension XCUIApplication {
    /// Goes to the Sites tab, searches, and opens the task of a hand-written flow (spokeo, peopleconnect...).
    func openFlowTask(_ id: String, search: String? = nil) {
        tabBars.buttons["Sites"].tap()
        searchSites(search ?? id)
        let row = buttons["task-flow-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(id) missing from the queue")
        row.tap()
    }

    /// Opens a flow's step cards (the guided walk-through screen) from its task page.
    func openFlowSteps(_ id: String) {
        openFlowTask(id)
        let open = buttons["open-flow"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
    }
}

extension XCUIApplication {
    /// Every walkthrough page must be scrolled to its bottom before Next works: scrolls until it is enabled, then taps it.
    func tapNextOnboarding() {
        var swipes = 0
        while !buttons["onboarding-next"].isEnabled && swipes < 12 { swipeUp(); swipes += 1 }
        buttons["onboarding-next"].tap()
    }
}

extension XCUIApplication {
    /// After the walkthrough with automatic protection on: the profile gate asks for the legal name and current address (the email was given in
    /// the walkthrough). Fills them in, continues, and passes the question about earlier addresses.
    func completeProfileGate(city: String = "Springfield", state: String = "IL", zip: String = "62701") {
        XCTAssertTrue(buttons["profile-gate-continue"].waitForExistence(timeout: 10), "the profile is asked for next")
        fillRequiredProfile(city: city, state: state, zip: zip, email: nil)
        buttons["profile-gate-continue"].tap()
        let skip = buttons.matching(identifier: "profile-gate-skip-previous").firstMatch          // its alert lists the button twice
        if skip.waitForExistence(timeout: 3) { skip.tap() }
    }

    /// A page whose reading is required: Next stays off until its last line has been on screen. On a tall screen a short page is read at once.
    func assertNextWaitsForTheEnd(of lastLine: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let next = buttons["onboarding-next"]
        XCTAssertTrue(!next.isEnabled || lastLine.exists, "\(what): Next is on only once the end has been seen", file: file, line: line)
        var swipes = 0
        while !next.isEnabled && swipes < 12 { swipeUp(); swipes += 1 }
        XCTAssertTrue(next.isEnabled, "\(what): scrolling to the end unlocks Next", file: file, line: line)
    }
}

extension XCUIApplication {
    /// Sets a SwiftUI toggle row. The row flips only when its switch is tapped, and where the switch sits depends on the phone's width, so it taps the
    /// switch itself and, if that did not take, the right-hand end of the row.
    func setSwitch(_ toggle: XCUIElement, on: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let want = on ? "1" : "0"
        if (toggle.value as? String) == want { return }
        let inner = toggle.switches.firstMatch
        (inner.exists ? inner : toggle).tap()
        if (toggle.value as? String) != want { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }
        XCTAssertEqual(toggle.value as? String, want, file: file, line: line)
    }
}

extension XCUIApplication {
    /// Launch arguments that keep a whole automatic run small in CI: the first 25 sites with a known form. The weekly end-to-end job sets
    /// OPTOUT_ALL_SITES=1 (TEST_RUNNER_OPTOUT_ALL_SITES for xcodebuild) to run the same tests over every site.
    static var fewSites: [String] { ProcessInfo.processInfo.environment["OPTOUT_ALL_SITES"] == "1" ? [] : ["-uitest-sites", "25"] }
}
