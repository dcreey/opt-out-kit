import XCTest

extension XCUIApplication {
    /// The Sites list is grouped by method and long, so find a hand-written site by searching for it.
    func searchSites(_ text: String) {
        let search = searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText(text)
    }
}
