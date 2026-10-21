import XCTest

/// End-to-end dry run for one real person, up to but never including submission.
/// Personal details come from the environment, never from the repo:
///   TEST_RUNNER_OPTOUT_NAME="First Last" TEST_RUNNER_OPTOUT_STREET="..." TEST_RUNNER_OPTOUT_CITY=... TEST_RUNNER_OPTOUT_STATE=XX
/// It types the profile into the app, scans Spokeo for a listing, and opens the opt-out flow. It never taps
/// "Mark done" on a step that would send data, and never submits anything on the broker's site.
final class DryRunUITests: XCTestCase {
    func testDryRunForRealPerson() throws {
        let env = ProcessInfo.processInfo.environment
        guard let name = env["OPTOUT_NAME"], let city = env["OPTOUT_CITY"], let state = env["OPTOUT_STATE"] else {
            throw XCTSkip("set TEST_RUNNER_OPTOUT_NAME / _CITY / _STATE to run the dry run")
        }
        let street = env["OPTOUT_STREET"] ?? ""

        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()

        // 1. Fill in the profile through the real editor.
        app.buttons["profile-button"].tap()
        let nameField = app.textFields["name-0"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap(); nameField.typeText(name)
        app.buttons["add-address"].tap()
        let streetField = app.textFields["Street (optional)"]
        XCTAssertTrue(streetField.waitForExistence(timeout: 5))
        if !street.isEmpty { streetField.tap(); streetField.typeText(street) }
        let cityField = app.textFields["City"]; cityField.tap(); cityField.typeText(city)
        let stateField = app.textFields["State"]; stateField.tap(); stateField.typeText(state)
        attach(app, "1-profile")
        app.buttons["Done"].tap()

        // 2. The Sites page lists Spokeo with what it will receive.
        app.tabBars.buttons["Sites"].tap()
        app.searchSites("spokeo")
        app.buttons["site-spokeo"].tap()
        XCTAssertTrue(app.staticTexts["site-summary"].waitForExistence(timeout: 5)
                      || app.staticTexts["Not started"].waitForExistence(timeout: 5))

        // 3. Scan Spokeo for a listing: live, read-only.
        let scan = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'scan-'")).firstMatch
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        scan.tap()
        let result = app.staticTexts["scan-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 45), "scan did not finish")
        let verdict = result.label
        print("DRYRUN scan result: \(verdict)")
        XCTAssertFalse(verdict.hasPrefix("Can't tell"), "scan was inconclusive: \(verdict)")
        attach(app, "2-scan")

        // 4. Open the opt-out flow and get to the step before anything is sent.
        app.buttons["Start"].firstMatch.tap()
        XCTAssertTrue(app.buttons["done-0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["done-1"].exists)
        XCTAssertFalse(app.buttons["done-1"].isEnabled, "step 2 must stay locked until step 1 is done")
        app.buttons["Open in Safari"].firstMatch.tap()          // loads Spokeo's real opt-out page; nothing is entered
        sleep(6)
        attach(app, "3-spokeo-optout-page")
        XCTAssertTrue(app.buttons["Done"].exists || app.buttons["Close"].exists)
        // STOP: the remaining steps (paste listing URL, enter email, confirm) are the submission.
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
