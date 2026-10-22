import XCTest

extension XCUIApplication {
    /// The Sites list is a long ranked queue, so find a site by typing in its search box.
    func searchSites(_ text: String) {
        let search = textFields["sites-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText(text)
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
            f.tap(); f.typeText(text)
        }
        type("legal-first", first); type("legal-last", last)
        type("current-street", street); type("current-city", city); type("current-state", state); type("current-zip", zip)
        if let email { type("contact-email", email) }
    }
}

extension XCUIApplication {
    /// On the walkthrough's email page (the sixth): types the required email address and continues.
    func enterOnboardingEmail(_ email: String = "pat@example.com") {
        let field = textFields["onboarding-email"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(buttons["onboarding-next"].isEnabled, "cannot go on without an email address")
        field.tap(); field.typeText(email)
        XCTAssertTrue(buttons["onboarding-next"].isEnabled)
        buttons["onboarding-next"].tap()
        // The next page asks which state the person lives in (optional); move past it.
        XCTAssertTrue(buttons["onboarding-state"].waitForExistence(timeout: 5))
        buttons["onboarding-next"].tap()
        // Then the terms page (accepting site terms for you); move past it without allowing anything.
        XCTAssertTrue(staticTexts["Accept site terms for you?"].waitForExistence(timeout: 5))
        buttons["onboarding-next"].tap()
    }
}

extension XCUIApplication {
    /// Scrolls a long list (the lazy SwiftUI List renders rows only near the screen) until the element exists.
    @discardableResult
    func scrollUntilExists(_ element: XCUIElement, maxSwipes: Int = 12) -> Bool {
        var n = 0
        while !element.exists && n < maxSwipes { swipeUp(); n += 1 }
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
