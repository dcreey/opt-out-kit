import XCTest

final class BrokerListUITests: XCTestCase {
    func testBrokerListShowsQueue() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.otherElements["broker-list"].waitForExistence(timeout: 10)
                      || app.collectionViews["broker-list"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.buttons["broker-spokeo"].exists)
    }
}
