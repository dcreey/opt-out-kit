import XCTest

/// Walks every bundled broker flow by tapping through its step cards, the way a user would.
/// It never taps "Open in Safari", so no live broker site is contacted.
final class BrokerFlowUITests: UITestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        return app
    }

    private func walk(_ id: String) {
        let app = launch()
        app.openFlowSteps(id)

        // Count cards from the "Step N of M" label on the first card.
        let first = app.buttons["done-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        // The step count is printed on the first card ("Step 1 of N"). Counting buttons on screen undercounts, because the list
        // only renders the cards that are visible.
        let total = totalGuess(app)
        XCTAssertGreaterThan(total, 0)

        // A later step must stay locked until earlier ones are done.
        if total > 1 { XCTAssertFalse(app.buttons["done-1"].isEnabled, "step 2 unlocked too early") }

        for i in 0..<total {
            let button = app.buttons["done-\(i)"]
            var scrolls = 0
            while !button.isHittable && scrolls < 6 { app.swipeUp(); scrolls += 1 }     // the screen is taller now, so scroll until it can be tapped
            // The step unlocks when the one before is done, a moment later on a slow machine: wait for it, never read it at once.
            XCTAssertTrue(button.becomes("enabled == true"), "step \(i + 1) of \(id) should be unlocked")
            // Done once it says so (the button then reads "Done" and is disabled). A tap can be lost on GitHub's slower simulator: tap again only while it
            // does not say so, so a step is never tapped twice.
            for _ in 0..<3 where button.label != "Done" {
                button.tap()
                if button.becomes("label == 'Done'") { break }
            }
            XCTAssertEqual(button.label, "Done", "step \(i + 1) of \(id) is marked done")
        }

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let done = app.buttons["task-flow-\(id)"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(done.images["checkmark.circle.fill"].waitForExistence(timeout: 5) || done.label.contains("checkmark"),
                      "\(id) should show as done")
    }

    /// Cards are labelled "Step N of M"; read M from the first one.
    private func totalGuess(_ app: XCUIApplication) -> Int {
        let label = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Step 1 of '")).firstMatch.label
        return Int(label.components(separatedBy: " ").last ?? "") ?? 0
    }

    func testSpokeoFlow() { walk("spokeo") }
    func testFastPeopleSearchFlow() { walk("fastpeoplesearch") }
    func testPeopleConnectFlow() { walk("peopleconnect") }
}
