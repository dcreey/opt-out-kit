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
        app.buttons["add-name"].tap()
        XCTAssertTrue(app.textFields["name-1"].waitForExistence(timeout: 3), "can add more than one name")
        app.buttons["add-address"].tap()
        XCTAssertTrue(app.textFields["City"].waitForExistence(timeout: 3))
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
        for option in ["Parent", "Child", "Sibling", "Cousin", "Friend"] {
            XCTAssertTrue(app.buttons[option].waitForExistence(timeout: 3), "\(option) missing from relationship list")
        }
        app.buttons["Parent"].tap()
        XCTAssertTrue(app.buttons["field-relationship"].label.contains("Parent"))
        app.buttons["Done"].tap()

        app.buttons["account-switcher"].tap()
        XCTAssertTrue(app.buttons["Mum"].exists && app.buttons["Me"].exists)
    }

    /// Real Keychain + encrypted file: a profile typed in one launch is still there in the next.
    func testProfileSurvivesRelaunch() {
        let app = launch(reset: true)
        app.buttons["profile-button"].tap()
        let name = app.textFields["name-0"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Pat Example")
        app.terminate()

        let again = launch(reset: false)
        again.buttons["profile-button"].tap()
        let restored = again.textFields["name-0"]
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertEqual(restored.value as? String, "Pat Example")
    }
}
