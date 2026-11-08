import XCTest

final class ProfileEditorUITests: XCTestCase {
    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        if reset { app.launchArguments = ["-uitest-reset"] }
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
        XCTAssertTrue(app.textFields["Street (optional)"].waitForExistence(timeout: 3), "previous addresses are added separately")
    }

    func testALegalNameAndCurrentAddressAreRequiredBeforeTheEditorCanClose() {
        let app = launch(reset: true)
        app.buttons["profile-button"].tap()
        XCTAssertTrue(app.staticTexts["missing-details"].waitForExistence(timeout: 5), "says what is still needed")
        XCTAssertFalse(app.buttons["editor-done"].isEnabled, "cannot close an incomplete profile")
        XCTAssertFalse(app.pickers.firstMatch.exists, "the legal name and current address have no type to choose")
        XCTAssertTrue(app.textFields["legal-middle"].exists, "a middle name can be given")
        XCTAssertTrue(app.textFields["contact-email"].exists, "the owner's email is required too")
        app.fillRequiredProfile()
        XCTAssertFalse(app.staticTexts["missing-details"].exists)
        XCTAssertTrue(app.buttons["editor-done"].isEnabled)
        app.buttons["editor-done"].tap()
        XCTAssertTrue(app.buttons["profile-button"].waitForExistence(timeout: 5))
    }

    func testAddRelativeAsAnotherPersonAndSwitchAccounts() {
        let app = launch(reset: true)
        app.buttons["account-switcher"].tap()
        app.buttons["Add person…"].tap()
        let field = app.alerts.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("Mum")
        app.alerts.buttons["Add"].tap()

        // Editor opens for the new person, with a relationship dropdown.
        let dropdown = app.buttons["field-relationship"]
        XCTAssertTrue(dropdown.waitForExistence(timeout: 5))
        dropdown.tap()
        for option in ["Parent", "Child", "Sibling", "Cousin", "Other family"] {
            XCTAssertTrue(app.buttons[option].waitForExistence(timeout: 3), "\(option) missing from relationship list")
        }
        XCTAssertFalse(app.buttons["Friend"].exists, "family only: there is no Friend option")
        app.buttons["Parent"].tap()
        XCTAssertTrue(app.buttons["field-relationship"].label.contains("Parent"))
        app.fillRequiredProfile(first: "Mum", email: nil)
        app.buttons["Done"].tap()

        app.buttons["account-switcher"].tap()
        XCTAssertTrue(app.buttons["Mum"].exists && app.buttons["Me"].exists)
    }

    /// Real Keychain + encrypted file: a profile typed in one launch is still there in the next.
    func testProfileSurvivesRelaunch() {
        let app = launch(reset: true)
        app.buttons["profile-button"].tap()
        let name = app.textFields["legal-first"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Pat")
        app.terminate()

        let again = launch(reset: false)
        again.buttons["profile-button"].tap()
        let restored = again.textFields["legal-first"]
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertEqual(restored.value as? String, "Pat")
    }
}
