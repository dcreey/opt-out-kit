import XCTest

/// The app opens on the Queue: "What do you want to tackle today?", one row per kind of broker, the first marked "Start here".
final class BrokerListUITests: UITestCase {
    func testBrokerListShowsQueue() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset"]
        app.launch()
        XCTAssertTrue(app.otherElements["broker-list"].waitForExistence(timeout: 10)
                      || app.collectionViews["broker-list"].waitForExistence(timeout: 1))
        let kinds = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'kind-'"))
        XCTAssertTrue(kinds.firstMatch.waitForExistence(timeout: 10), "the queue lists the kinds of broker")
        XCTAssertTrue(app.staticTexts["Start here"].exists, "and says where to start")
    }
}
