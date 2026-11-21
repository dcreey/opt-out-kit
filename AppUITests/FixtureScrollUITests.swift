import XCTest

/// A very long page with its request form at the very end, opened in Solve and send while the person scrolls: does the app, filling the form and moving the page,
/// fight the person's scrolling? The fixture pages (`longform`, `longneeds`) report every scroll position to the server with whether a finger was moving it
/// (fixtures/server.py, `/__scroll`), so the test can tell the person's scrolling from the app's. docs/TESTING.md, "End-to-end tests against fixture pages".
final class FixtureScrollUITests: UITestCase {
    private var server: FixtureBrokers!
    /// When the page's web view first showed on screen (seconds since 1970), and how long after the app was launched.
    private var visibleAt: TimeInterval = 0
    private var timeToShow: TimeInterval = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try FixtureBrokers.start()
    }

    /// Opens Solve and send on the long page and starts scrolling the moment its web view is on screen, like a person who begins to read at once.
    private func openAndScrollAtOnce(_ domain: String, _ site: String, for seconds: TimeInterval) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile"] + server.launchArguments + ["-semi-domains", "\(domain).fixture.test"]
        app.launch()
        let web = app.webViews.firstMatch
        let launched = Date().timeIntervalSince1970
        XCTAssertTrue(web.waitForExistence(timeout: 40), "the page's web view is on screen")
        visibleAt = Date().timeIntervalSince1970
        timeToShow = visibleAt - launched
        // While the app prepares the page (fills it, finds the form) a "Loading the form…" cover hides the page, so nothing can be scrolled yet: a picture of it.
        let pic = XCTAttachment(screenshot: app.screenshot()); pic.name = "while-the-page-prepares"; pic.lifetime = .keepAlways; add(pic)
        // The person scrolls the way a person does: flicks down the page, a flick back up now and then, a short pause between.
        let start = Date()
        var n = 0
        while Date().timeIntervalSince(start) < seconds {
            if n % 4 == 3 { web.swipeDown(velocity: .fast) } else { web.swipeUp(velocity: .fast) }
            Thread.sleep(forTimeInterval: 0.2)
            n += 1
        }
        XCTAssertTrue(server.scrolls.contains { $0.site == site && $0.kind == "load" }, "the long page loaded")
        return app
    }

    /// A readable timeline, relative to the moment the person could first see the page (negative: before, while the page was loading out of sight), with the
    /// broker's receipts, and the moves the app made by itself after the person first touched the page: a scroll with no finger on it, or one far bigger than a
    /// flick (a smooth scroll to a link is the second kind).
    private func timeline(_ site: String) -> (text: String, appMovesAfterTouch: [FixtureBrokers.Scroll]) {
        let events = server.scrolls.filter { $0.site == site }
        var rows: [(at: TimeInterval, line: String)] = []
        var prev = 0
        var touched = false
        var moves: [FixtureBrokers.Scroll] = []
        for e in events {
            if e.kind == "touchstart" { touched = true }
            let delta = e.y - prev
            if e.kind == "scroll", touched, (!e.user && abs(delta) > 30) || abs(delta) > 200 { moves.append(e) }
            rows.append((e.at, String(format: "%+7.2f s  y=%5d  Δ=%+5d  %@  %@", e.at - visibleAt, e.y, delta, e.user ? "PERSON" : "app   ", e.kind)))
            if e.kind == "scroll" { prev = e.y }
        }
        for r in server.requests where r.site == site { rows.append((r.at, String(format: "%+7.2f s  BROKER RECEIVED %@ %@", r.at - visibleAt, r.path, r.path == "send" ? "(the form was sent)" : ""))) }
        let header = String(format: "the page's web view showed %.2f s after the app was launched; times below are relative to that\n", timeToShow)
        return (header + rows.sorted { $0.at < $1.at }.map(\.line).joined(separator: "\n"), moves)
    }

    private func attach(_ text: String, _ name: String) {
        let a = XCTAttachment(string: text); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// A form that is sent by the app (Solve and send, "Send it for me" on) at the end of a very long page, while the person scrolls: the page must not be moved
    /// by the app after the person has touched it.
    func testScrollingAWhileTheAppFillsAndSendsALongPageIsNotFoughtOver() {
        let app = openAndScrollAtOnce("longform-1", "fx_longform_1", for: 10)
        _ = server.waitForSent(timeout: 45) { $0.contains("fx_longform_1") }
        Thread.sleep(forTimeInterval: 2)
        let (text, moves) = timeline("fx_longform_1")
        attach(text, "scroll-timeline-auto-sent")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "after"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertEqual(server.sentSites, ["fx_longform_1"], "the form at the end of the page was still filled and sent: \(server.requests)")
        XCTAssertTrue(moves.isEmpty, "the app moved the page \(moves.count) times by itself after the person touched it:\n\(text)")
    }

    /// A form that needs details the app does not have (a case number), at the end of a very long page, while the person scrolls: the app fills what it can and
    /// waits, and must leave the page where the person put it.
    func testScrollingAWhileTheAppWaitsForDetailsOnALongPageIsNotFoughtOver() {
        let app = openAndScrollAtOnce("longneeds-1", "fx_longneeds_1", for: 10)
        Thread.sleep(forTimeInterval: 12)          // the app keeps watching the page for a while: it must not move it
        let (text, moves) = timeline("fx_longneeds_1")
        attach(text, "scroll-timeline-needs-details")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "after"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(server.sentSites.isEmpty, "nothing is sent while a required detail is missing: \(server.requests)")
        XCTAssertTrue(moves.isEmpty, "the app moved the page \(moves.count) times by itself after the person touched it:\n\(text)")
    }

    /// A long page that gets new content while the person reads it (a banner fixed to the top of the screen, as cookie and privacy banners are, that mentions opting out) and a form
    /// at the end that waits for a detail the app lacks: the person scrolls near the end, and the page must stay where they put it.
    func testScrollingWhileALongPageGainsAnOptOutBannerDoesNotJumpThePage() {
        let app = openAndScrollAtOnce("longdynamic-1", "fx_longdynamic_1", for: 20)
        let (text, moves) = timeline("fx_longdynamic_1")
        attach(text, "scroll-timeline-late-opt-out-link")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "after"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(moves.isEmpty, "the app moved the page \(moves.count) times by itself after the person touched it (first: \(moves.first.map { "t=\($0.ms) ms y=\($0.y)" } ?? "")); timeline:\n\(text.split(separator: "\n").filter { $0.contains("app") }.prefix(12).joined(separator: "\n"))")
    }
}
