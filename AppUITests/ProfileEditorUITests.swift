import XCTest

/// The profile editor. (Adding family profiles is switched off, `Features.otherProfiles`, so it has no UI test; its rules are Mac tests.)
final class ProfileEditorUITests: UITestCase {
    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        // Without a reset it still opens as a test run (`-uitest-relaunch` keeps the data): a bare launch resumed the first-run setup over the
        // incomplete profile and started the automatic run, and on CI the editor never showed.
        app.launchArguments = [reset ? "-uitest-reset" : "-uitest-relaunch"]
        app.launch()
        return app
    }

    func testProfileButtonOpensEditorWithPrivacyNote() {
        let app = launch(reset: true)
        app.buttons["profile-button"].tap()
        XCTAssertTrue(app.staticTexts["privacy-note"].waitForExistence(timeout: 5)
                      || app.otherElements["privacy-note"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.textFields["current-city"].waitForExistence(timeout: 3), "the current address is its own required field")
        XCTAssertTrue(app.descendants(matching: .any)["current-state"].exists, "the state is chosen from a menu")
        var down = 0
        while !app.buttons["add-name"].isHittable && down < 10 { app.swipeUp(); down += 1 }
        app.buttons["add-name"].tap()
        XCTAssertTrue(app.textFields["name-1"].waitForExistence(timeout: 3), "can add more than one name")
        var scrolls = 0
        while !app.buttons["add-address"].isHittable && scrolls < 10 { app.swipeUp(); scrolls += 1 }   // the editor is taller now
        app.buttons["add-address"].tap()
        // A previous address is a city, state and ZIP code (no street: those are enough to find a record).
        XCTAssertTrue(app.scrollUntilExists(app.descendants(matching: .any)["previous-state-1"]), "previous addresses are added separately")
        XCTAssertFalse(app.textFields["Street (optional)"].exists, "with no street")
    }

    func testALegalNameAndCurrentAddressAreRequiredBeforeTheEditorCanClose() {
        let app = launch(reset: true)
        app.buttons["profile-button"].tap()
        // The top of the editor first: scrolling down to the note takes these off the screen (and out of the list).
        XCTAssertTrue(app.textFields["legal-middle"].waitForExistence(timeout: 5), "a middle name can be given")
        XCTAssertFalse(app.pickers.firstMatch.exists, "the legal name and current address have no type to choose")
        let missing = app.descendants(matching: .any)["missing-details"]
        XCTAssertTrue(app.scrollUntilExists(missing), "says what is still needed")          // under the birthdate, below the first screen
        XCTAssertFalse(app.buttons["editor-done"].isEnabled, "cannot close an incomplete profile")
        XCTAssertTrue(app.scrollUntilExists(app.textFields["contact-email"]), "the owner's email is required too")
        app.fillRequiredProfile()
        XCTAssertTrue(missing.waitForNonExistence(timeout: 5), "nothing is missing any more")
        XCTAssertTrue(app.buttons["editor-done"].isEnabled)
        app.buttons["editor-done"].tap()
        // The editor closes. (What comes next can be a sheet of its own, which hides the screen below from the test, so the test checks the editor.)
        XCTAssertTrue(app.buttons["editor-done"].waitForNonExistence(timeout: 5), "a complete profile closes the editor")
    }

    /// Real Keychain + encrypted file: a profile typed in one launch is still there in the next.
    func testProfileSurvivesRelaunch() {
        let app = launch(reset: true)
        app.buttons["profile-button"].tap()
        let name = app.textFields["legal-first"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeTextChecked("Pat")
        XCUIDevice.shared.press(.home)          // leaving the app saves what is typed (nothing is written while typing)
        sleep(5)                                // the save is written in the background; CI machines are slow
        app.terminate()

        let again = launch(reset: false)
        XCTAssertTrue(again.buttons["profile-button"].waitForExistence(timeout: 15), "the app opened")
        again.buttons["profile-button"].tap()
        let restored = again.textFields["legal-first"]
        XCTAssertTrue(restored.waitForExistence(timeout: 10), "the profile editor opened")
        XCTAssertEqual(restored.value as? String, "Pat")
    }
}
