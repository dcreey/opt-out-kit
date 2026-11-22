import XCTest

final class SiteViewLayoutUITests: UITestCase {
    private func scrollToBottom(_ app: XCUIApplication) {
        for _ in 0..<8 { app.swipeUp() }
    }

    func testABrokerSiteViewLeadsWithTheGuideAndEndsWithTheSiteLink() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile"]          // a guide needs a complete profile
        app.launch()
        app.tab("Sites", 1).tap()
        app.searchSites("peopleconnect")
        XCTAssertTrue(app.buttons["task-flow-peopleconnect"].waitForExistence(timeout: 10))
        app.buttons["task-flow-peopleconnect"].tap()
        let guide = app.buttons["guide-me"]
        XCTAssertTrue(guide.waitForExistence(timeout: 5))
        let screen = app.windows.firstMatch.frame
        XCTAssertLessThan(guide.frame.minY, screen.height * 0.4, "the guide is front and center, at the top")
        XCTAssertGreaterThan(guide.frame.width, screen.width * 0.7, "and it is big")
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "9-site-view-guide-first"; a.lifetime = .keepAlways; add(a)
        scrollToBottom(app)
        let link = app.buttons["site-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 3), "the site link is at the bottom")
        XCTAssertFalse(guide.isHittable, "the guide is far above it")
    }

    func testADirectorySiteViewHasTheSiteLinkAtTheTopAndNotAgainAtTheBottom() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile"]          // a guide needs a complete profile
        app.launch()
        app.tab("Sites", 1).tap()
        app.searchSites("texascourtrecords")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'task-site-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        let guide = app.buttons["guide-me"]
        XCTAssertTrue(guide.waitForExistence(timeout: 5))
        XCTAssertLessThan(guide.frame.minY, app.windows.firstMatch.frame.height * 0.5)
        let link = app.buttons["site-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 3), "the site link is in the status block at the top")
        XCTAssertLessThan(link.frame.minY, app.windows.firstMatch.frame.height * 0.5)
        XCTAssertEqual(app.buttons.matching(identifier: "site-link").count, 1, "one link, not a second one at the bottom")
    }

    func testTheGuideOpensFromTheSiteView() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile"]          // a guide needs a complete profile
        app.launch()
        app.tab("Sites", 1).tap()
        app.searchSites("peopleconnect")
        app.buttons["task-flow-peopleconnect"].tap()
        app.buttons["guide-me"].tap()
        XCTAssertTrue(app.staticTexts["guided-progress"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["guided-more"].exists, "the guide's menu is on top")
    }
}
