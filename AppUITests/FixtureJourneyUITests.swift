import XCTest

/// Journeys that run the real engine against broker fixture pages served by the test itself (`FixtureServer`): nothing in the app is faked, so what the
/// screen says is what really happened on a page. docs/TESTING.md, "End-to-end tests against fixture pages"; the list of journeys is docs/JOURNEYS.md.
final class FixtureJourneyUITests: UITestCase {
    private var server: FixtureBrokers!

    /// The fixture brokers whose pages the app completes by itself: plain forms, request-type tiles, a choice that reveals the form, a cookie banner over the
    /// form, a form in a frame, and one that promises an email. Left for the person: a Cloudflare box, an "I'm not a robot" box, an emailed code, a page with no form and a page that is down.
    /// The sites the broad Run now covers (not the slow ones, which have a test of their own).
    static let runNowDomains = ["plain-1", "plain-2", "plain-3", "tiles-1", "reveal-1", "cookie-1", "iframe-1", "emaillink-1", "turnstile-1", "robot-1", "noform-1", "down-1", "code-1"].map { $0 + ".fixture.test" }.joined(separator: ",")

    static let sendable: Set<String> = ["fx_plain_1", "fx_plain_2", "fx_plain_3", "fx_tiles_1", "fx_reveal_1", "fx_cookie_1", "fx_iframe_1", "fx_emaillink_1"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try FixtureBrokers.start()
    }

    /// As a user I want to press Run now and have my request sent to every broker whose page can be completed without me, in whatever way its page is built:
    /// the form is filled with my name and email, sent, and the app says so; the brokers that need me are left alone.
    func testRunNowFillsAndSendsTheFormOnEachBrokerPage() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-only-domains", Self.runNowDomains] + server.launchArguments
        app.launch()
        app.buttons["profile-button"].tap()
        app.fillRequiredProfile()
        app.buttons["editor-done"].tap()
        app.tabBars.buttons["Settings"].tap()
        var scrolls = 0
        while !app.buttons["auto-activity"].isHittable && scrolls < 8 { app.swipeUp(); scrolls += 1 }
        app.buttons["auto-activity"].tap()
        XCTAssertTrue(app.buttons["auto-run-now"].waitForExistence(timeout: 5))
        app.buttons["auto-run-now"].tap()
        let done = app.buttons["run-report-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 240), "the run finished and reported")
        done.tap()

        let a = XCTAttachment(screenshot: app.screenshot()); a.lifetime = .keepAlways; add(a)
        let sent = server.requests.filter { $0.path == "send" }
        XCTAssertEqual(Set(sent.map(\.site)), Self.sendable, "every broker whose page the app can complete was sent, and no other: \(server.requests)")
        XCTAssertEqual(sent.count, Self.sendable.count, "each was sent once")
        for request in sent {
            XCTAssertTrue(request.fields["email"]?.contains("@") == true, "\(request.site) was sent an email: \(request.fields)")
            XCTAssertFalse(request.fields["name"]?.isEmpty ?? true, "\(request.site) was sent a name: \(request.fields)")
        }
        let count = app.buttons["activity-count-sent"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let start = Date()
        while !count.label.hasPrefix("\(Self.sendable.count)") && Date().timeIntervalSince(start) < 15 { Thread.sleep(forTimeInterval: 1) }
        XCTAssertTrue(count.label.hasPrefix("\(Self.sendable.count)"), "the page counts the sites that were sent: \(count.label)")
    }

    /// As a user I want the app to fill each form for me and send it, and when a site shows a check, to wait for me to clear it first (Solve and send): the
    /// first broker has none and is sent at once; the second shows a Cloudflare box that only I can tap, and is sent when I have.
    func testSolveAndSendFillsTheFormWaitsForMyCheckThenSendsAndMovesOn() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile"] + server.launchArguments + ["-semi-domains", "plain-1.fixture.test,turnstile-1.fixture.test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["assisted-site"].waitForExistence(timeout: 30), "the Solve-and-send screen opened")

        // After each send the app asks whether it is completely done (some brokers email a link afterwards); I say yes, and it moves to the next broker.
        let done = app.buttons.matching(identifier: "finish-done").firstMatch          // the alert lists its buttons twice
        XCTAssertTrue(done.waitForExistence(timeout: 60), "the first broker was filled and sent, and the app asks whether it is completely done: \(server.requests)")
        XCTAssertEqual(server.sentSites, ["fx_plain_1"], "the form with no check was sent")
        done.tap()

        let verify = app.webViews.buttons["Verify you are human"]
        XCTAssertTrue(verify.waitForExistence(timeout: 60), "the second broker's page shows its check")
        XCTAssertEqual(server.sentSites, ["fx_plain_1"], "nothing more is sent while the check is waiting for me: \(server.requests)")
        // The page is still being filled and laid out when it first shows, so a tap can land beside the box: tap again until the page says it took.
        var taps = 0
        while !app.webViews.buttons["Verified"].exists && taps < 8 {
            if verify.isHittable { verify.tap() }
            _ = app.webViews.buttons["Verified"].waitForExistence(timeout: 3)
            taps += 1
        }
        XCTAssertTrue(app.webViews.buttons["Verified"].exists || done.exists, "the page took my tap on its check")
        XCTAssertTrue(done.waitForExistence(timeout: 60), "the form was sent once I cleared the check, and the app asks again: \(server.requests)")
        XCTAssertEqual(server.sentSites, ["fx_plain_1", "fx_turnstile_1"])
        done.tap()
        for request in server.requests.filter({ $0.path == "send" }) {
            XCTAssertTrue(request.fields["email"]?.contains("@") == true && request.fields["name"]?.isEmpty == false, "\(request.site) got my name and email: \(request.fields)")
        }
        XCTAssertEqual(server.requests.filter { $0.site == "fx_turnstile_1" && $0.fields["cf-turnstile-response"] == "token" }.count, 1, "the broker got the check's token")
    }

    private func solveAndSend(_ domain: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile"] + server.launchArguments + ["-semi-domains", "\(domain).fixture.test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["assisted-site"].waitForExistence(timeout: 30), "the Solve-and-send screen opened")
        return app
    }

    /// As a user I want a site that asks "I'm not a robot" to wait for me: my details are filled in, I tick the box, and it is sent.
    func testSolveAndSendWaitsForTheNotARobotBoxAndSendsWhenITickIt() {
        let app = solveAndSend("robot-1")
        let box = app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'not a robot'")).firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 30), "the page shows its box")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Solve the check'")).firstMatch.waitForExistence(timeout: 30), "the app says it is waiting for my check")
        XCTAssertTrue(server.sentSites.isEmpty, "nothing is sent while the box is unticked: \(server.requests)")
        var taps = 0
        while server.sentSites.isEmpty && taps < 8 {
            let f = box.frame
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.minX + 24, dy: f.midY)).tap()          // the tick box at the left of its label
            Thread.sleep(forTimeInterval: 3); taps += 1
        }
        XCTAssertEqual(server.sentSites, ["fx_robot_1"], "the form was sent once I ticked the box: \(server.requests)")
        XCTAssertEqual(server.requests.last?.fields["human"], "yes", "the broker saw the box ticked")
        XCTAssertTrue(app.buttons.matching(identifier: "finish-done").firstMatch.waitForExistence(timeout: 30), "the app asks whether it is completely done")
    }

    /// As a user I want a site whose confirmation says it will email me a link to be told so: the app sees the promise in the page, does not ask, and lists the
    /// site as sent with the email still to confirm.
    func testSolveAndSendSeesThatASitePromisesAnEmailAndListsItForTheFollowUp() {
        let app = solveAndSend("emaillink-1")
        let row = app.staticTexts["Sent; confirm the email they sent you"]
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the form was sent and the summary says an email is still to come: \(server.requests)")
        XCTAssertEqual(server.sentSites, ["fx_emaillink_1"])
        XCTAssertTrue(app.staticTexts["Sent 1 of 1."].exists)
    }

    /// As a user I want a page that has no form to send nothing, and to be able to say I did it another way.
    func testSolveAndSendSendsNothingToAPageWithNoFormAndLetsMeMarkItDone() {
        let app = solveAndSend("noform-1")
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'do not offer an online form'")).firstMatch.waitForExistence(timeout: 30), "the page loaded")
        Thread.sleep(forTimeInterval: 10)
        XCTAssertTrue(server.sentSites.isEmpty, "there is no form to send: \(server.requests)")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'could not find a form'")).firstMatch.exists, "and the app says so, not that it pressed Send and saw no confirmation")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'pressed Send'")).firstMatch.exists)
        let done = app.buttons["Mark as done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "I can mark it done myself")
    }

    /// As a user I want a broker whose page is down to be left unsent, not counted as done, and to be able to skip it.
    func testSolveAndSendLeavesABrokerThatIsDownUnsentAndLetsMeSkipIt() {
        let app = solveAndSend("down-1")
        XCTAssertTrue(app.webViews.staticTexts["Service unavailable"].waitForExistence(timeout: 30), "the page shows what the broker answered")
        Thread.sleep(forTimeInterval: 10)
        XCTAssertTrue(server.sentSites.isEmpty, "nothing is sent to a page that is down: \(server.requests)")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'could not find a form'")).firstMatch.exists, "the app says it found no form, not that it pressed Send")
        app.buttons["assisted-more"].tap()
        XCTAssertTrue(app.buttons["assisted-skip"].waitForExistence(timeout: 5), "I can skip it")
    }

    /// As a user I want a page that asks "Who is this request for?" before it shows its form to be answered for me (myself), and the form that appears to be
    /// filled and sent.
    func testSolveAndSendAnswersWhoTheRequestIsForAndFillsTheFormThatAppears() {
        let app = solveAndSend("reveal-1")
        XCTAssertTrue(app.buttons.matching(identifier: "finish-done").firstMatch.waitForExistence(timeout: 60), "the form that appeared was filled and sent: \(server.requests)")
        XCTAssertEqual(server.sentSites, ["fx_reveal_1"])
        XCTAssertEqual(server.requests.last?.fields["email"], "pat@example.com")
    }

    /// As a user I want a site that emails me a code before it accepts a request to stay on my list until I have entered the code: my details are filled in, the
    /// site emails me, nothing counts as sent or done while it waits, and when I type the code and send, it is done.
    func testSolveAndSendIsNotDoneUntilIHaveEnteredTheCodeFromTheEmail() {
        let app = solveAndSend("code-1")
        let getCode = app.webViews.buttons["Email me a verification code"]
        XCTAssertTrue(getCode.waitForExistence(timeout: 30), "the page shows its code step")
        Thread.sleep(forTimeInterval: 10)
        XCTAssertTrue(server.sentSites.isEmpty, "nothing is sent before the code: \(server.requests)")
        let early = XCTAttachment(screenshot: app.screenshot()); early.name = "code-early"; early.lifetime = .keepAlways; add(early)
        XCTAssertFalse(app.buttons["finish-done"].exists, "the site is not done: \(server.requests)")

        var taps = 0
        while !server.requests.contains(where: { $0.path == "code" }) && taps < 6 { if getCode.isHittable { getCode.tap() }; Thread.sleep(forTimeInterval: 2); taps += 1 }
        XCTAssertTrue(server.requests.contains { $0.path == "code" }, "the site was asked to email me the code: \(server.requests)")
        let field = app.webViews.textFields["Verification code"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the code box appeared")
        XCTAssertTrue(server.sentSites.isEmpty, "still nothing sent while the code is not entered")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "code-step"; shot.lifetime = .keepAlways; add(shot)
        field.tap()
        field.typeTextChecked("750439")
        XCTAssertTrue(server.waitForSent(timeout: 40) { $0 == ["fx_code_1"] }, "the request was accepted once the code was entered: \(server.requests)")
        XCTAssertEqual(server.requests.last?.fields["code"], "750439")
        XCTAssertFalse(server.requests.contains { $0.path == "rejected" }, "the site never saw a wrong code")
        let finished = app.buttons.matching(identifier: "finish-done").firstMatch.waitForExistence(timeout: 30)
        let end = XCTAttachment(screenshot: app.screenshot()); end.name = "code-end"; end.lifetime = .keepAlways; add(end)
        XCTAssertTrue(finished, "now the app asks whether it is completely done: \(app.staticTexts.allElementsBoundByIndex.prefix(10).map(\.label))")
    }

    /// As a user I want to see what happened when a site takes my request but never confirms it in time: the run says it was sent but not confirmed, and for that
    /// site I can see what its page said and a screenshot of how the page looked, so I can judge it myself.
    func testRunNowShowsWhatAPageSaidAndItsScreenshotWhenTheSiteDidNotConfirmInTime() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-only-domains", "slow-1.fixture.test"] + server.launchArguments
        app.launch()
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        app.buttons["profile-button"].tap()
        app.fillRequiredProfile()
        app.buttons["editor-done"].tap()
        app.tabBars.buttons["Settings"].tap()
        var scrolls = 0
        while !app.buttons["auto-activity"].isHittable && scrolls < 8 { app.swipeUp(); scrolls += 1 }
        app.buttons["auto-activity"].tap()
        XCTAssertTrue(app.buttons["auto-run-now"].waitForExistence(timeout: 5))
        shot("1-before-the-run")
        app.buttons["auto-run-now"].tap()

        let done = app.buttons["run-report-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 120), "the run finished and reported")
        shot("2-run-report")
        let title = app.staticTexts["run-report-title"].label
        XCTAssertEqual(server.sentSites, ["fx_slow_1"], "the request was posted to the site once: \(server.requests)")
        done.tap()
        shot("3-after-the-run")

        // Review of the last run: the site is listed as sent but not confirmed, and says why.
        let review = app.buttons["review-last-run"]
        XCTAssertTrue(app.scrollUntilExists(review), "the review of the last run is offered")
        review.tap()
        let row = app.buttons["review-fx_slow_1"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the site is in the review (\(title))")
        shot("4-review-list")
        XCTAssertTrue(row.label.localizedCaseInsensitiveContains("did not confirm") || row.label.localizedCaseInsensitiveContains("not confirmed"),
                      "the review says the site did not confirm in time: \(row.label)")
        row.tap()

        // The site's page: what it said at the end, and a screenshot of it.
        let said = app.descendants(matching: .any).matching(identifier: "site-page-said").firstMatch
        XCTAssertTrue(app.scrollUntilExists(said), "what the page said is shown")
        XCTAssertTrue(said.label.contains("Processing your request"), "it shows the page's own words, that it was still processing: \(said.label)")
        shot("5-what-the-page-said")
        let picture = app.buttons["site-screenshot"]
        XCTAssertTrue(app.scrollUntilExists(picture), "a screenshot of the page was saved; on screen: \(app.buttons.allElementsBoundByIndex.map(\.identifier)) \(app.images.allElementsBoundByIndex.map(\.identifier))")
        picture.tap()
        let full = app.images["screenshot-full"]
        let opened = full.waitForExistence(timeout: 5)
        shot("6-the-screenshot-full-size")
        XCTAssertTrue(opened, "the screenshot opens full size")
        app.buttons["BackButton"].tap()
        XCTAssertTrue(picture.waitForExistence(timeout: 5), "and I am back on the site's page")
    }

    /// As a user I want to skip a site for now and bring it back later: it goes to my skipped list, and bringing it back puts it in my queue again.
    func testISkipASiteForNowAndBringItBackFromTheSkippedList() {
        let app = solveAndSend("noform-1")
        let label = app.staticTexts["assisted-site"]
        XCTAssertTrue(label.waitForExistence(timeout: 30))
        app.buttons["assisted-more"].tap()
        let skip = app.buttons["assisted-skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5), "I can skip it")
        skip.tap()
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 30), "with nothing left, Solve and send ends with its summary")
        let sumShot = XCTAttachment(screenshot: app.screenshot()); sumShot.name = "summary-after-skip"; sumShot.lifetime = .keepAlways; add(sumShot)
        done.tap()
        app.tabBars.buttons["Sites"].tap()
        app.searchSites("noform-1")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'noform-1.fixture.test'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the site is found")
        row.tap()
        let bring = app.buttons["site-bring-back"]
        XCTAssertTrue(app.scrollUntilExists(bring), "its page offers to bring it back to my list")
        let before = XCTAttachment(screenshot: app.screenshot()); before.name = "skipped-site"; before.lifetime = .keepAlways; add(before)
        bring.tap()
        XCTAssertFalse(app.buttons["site-bring-back"].waitForExistence(timeout: 3), "once brought back it is no longer set aside")
    }

    private func startRunNow(_ app: XCUIApplication) {
        app.buttons["profile-button"].tap()
        app.fillRequiredProfile()
        app.buttons["editor-done"].tap()
        app.tabBars.buttons["Settings"].tap()
        var scrolls = 0
        while !app.buttons["auto-activity"].isHittable && scrolls < 8 { app.swipeUp(); scrolls += 1 }
        app.buttons["auto-activity"].tap()
        XCTAssertTrue(app.buttons["auto-run-now"].waitForExistence(timeout: 5))
        app.buttons["auto-run-now"].tap()
    }

    /// As a user I want the automatic run to send what it can and then take me straight to the sites that need me: the report says one moved to semi-automatic,
    /// starting them opens the site with its check, and when I clear it the form is sent.
    func testRunNowThenTheSemiAutomatedQueueFinishesWhatTheRunCouldNot() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-only-domains", "plain-1.fixture.test,turnstile-1.fixture.test"] + server.launchArguments
        app.launch()
        startRunNow(app)
        let start = app.buttons["run-report-start-semi"]
        XCTAssertTrue(start.waitForExistence(timeout: 120), "the run finished and offers the semi-automated sites")
        XCTAssertEqual(server.sentSites, ["fx_plain_1"], "the plain form was sent by the run; the Cloudflare one was left for me")
        start.tap()

        // The report sends me to my queue; the site the run left for my check is found by its name and opened.
        app.tabBars.buttons["Sites"].tap()
        app.searchSites("turnstile-1")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'turnstile-1.fixture.test'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the site the run could not send is found")
        row.tap()
        XCTAssertTrue(app.staticTexts["Stopped: a human check"].waitForExistence(timeout: 10), "the site says why the run left it for me")
        XCTAssertTrue(app.buttons["site-screenshot"].waitForExistence(timeout: 10), "with a screenshot of the form as far as the run got")
        app.buttons["Opt out"].tap()
        let verify = app.webViews.buttons["Verify you are human"]
        let opened = verify.waitForExistence(timeout: 60)
        let afterStart = XCTAttachment(screenshot: app.screenshot()); afterStart.name = "after-start-semi"; afterStart.lifetime = .keepAlways; add(afterStart)
        XCTAssertTrue(opened, "the site that needs me opens with its check")
        var taps = 0
        while !app.webViews.buttons["Verified"].exists && taps < 8 {
            if verify.isHittable { verify.tap() }
            _ = app.webViews.buttons["Verified"].waitForExistence(timeout: 3)
            taps += 1
        }
        XCTAssertTrue(server.waitForSent(timeout: 60) { $0 == ["fx_plain_1", "fx_turnstile_1"] }, "the form was sent once I cleared the check: \(server.requests)")
        XCTAssertTrue(app.buttons.matching(identifier: "finish-done").firstMatch.waitForExistence(timeout: 30), "and the app asks whether it is completely done")
    }

    /// As a user I want to tell the app I did a site by myself: it is marked done, and my list shows it.
    func testIMarkASiteDoneByHandAndItShowsAsDone() {
        let app = solveAndSend("noform-1")
        let mark = app.buttons["Mark as done"]
        XCTAssertTrue(mark.waitForExistence(timeout: 30), "I can mark the site done")
        mark.tap()
        let summary = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'noform-1.fixture.test'")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 20), "the summary lists the site")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "marked-done"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(server.sentSites.isEmpty, "marking it done sent nothing: it was done by hand")
    }

    /// As a user I want to stop an automatic run part way and carry on later: what was already sent stays sent, and the next Run now sends only the rest.
    func testIStopTheRunPartWayAndRunNowCarriesOnWithOnlyWhatIsLeft() {
        let app = XCUIApplication()
        let sites = ["plain-1", "plain-2", "plain-3", "cookie-1", "tiles-1"].map { $0 + ".fixture.test" }.joined(separator: ",")
        app.launchArguments = ["-uitest-reset", "-only-domains", sites] + server.launchArguments
        app.launch()
        startRunNow(app)
        let stop = app.buttons["auto-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 30), "a run in progress offers Stop")
        XCTAssertTrue(server.waitForSent(timeout: 60) { !$0.isEmpty }, "the run has begun sending")
        stop.tap()
        let rerun = app.buttons["auto-run-now"]
        let ended = NSPredicate(format: "exists == false")
        wait(for: [XCTNSPredicateExpectation(predicate: ended, object: stop)], timeout: 90)          // the sites in progress finish first
        XCTAssertTrue(rerun.waitForExistence(timeout: 10) && rerun.isEnabled, "the run stopped and Run now is offered again")
        let sentSoFar = server.sentSites
        XCTAssertFalse(sentSoFar.isEmpty)
        XCTAssertLessThan(sentSoFar.count, 5, "it stopped before the last site: \(sentSoFar)")
        let stoppedShot = XCTAttachment(screenshot: app.screenshot()); stoppedShot.name = "stopped"; stoppedShot.lifetime = .keepAlways; add(stoppedShot)

        rerun.tap()
        Thread.sleep(forTimeInterval: 25)
        let again = XCTAttachment(screenshot: app.screenshot()); again.name = "after-run-now-again"; again.lifetime = .keepAlways; add(again)
        XCTAssertTrue(server.waitForSent(timeout: 150) { Set($0).count == 5 }, "Run now carried on and sent the rest: \(server.sentSites)")
        XCTAssertEqual(server.sentSites.count, 5, "nothing already sent was sent a second time: \(server.sentSites)")
    }

    /// As a user I want a site that answers my request with an error to be reported as such: not counted as sent-and-done, with the page's own words and a
    /// screenshot of the error, so I can see what the site said.
    func testRunNowShowsTheErrorAPageAnsweredWithAndItsScreenshot() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-only-domains", "errorpage-1.fixture.test"] + server.launchArguments
        app.launch()
        startRunNow(app)
        XCTAssertTrue(app.buttons["run-report-done"].waitForExistence(timeout: 120), "the run finished and reported")
        XCTAssertEqual(server.sentSites, ["fx_errorpage_1"], "the form was posted: \(server.requests)")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "run-report-for-an-error"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["run-report-done"].tap()
        let review = app.buttons["review-last-run"]
        XCTAssertTrue(app.scrollUntilExists(review))
        review.tap()
        let row = app.buttons["review-fx_errorpage_1"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let list = XCTAttachment(screenshot: app.screenshot()); list.name = "review-for-an-error"; list.lifetime = .keepAlways; add(list)
        row.tap()
        let said = app.descendants(matching: .any).matching(identifier: "site-page-said").firstMatch
        XCTAssertTrue(app.scrollUntilExists(said), "what the page said is shown")
        XCTAssertTrue(said.label.contains("Something went wrong"), "it shows the error the site gave: \(said.label)")
        XCTAssertTrue(app.scrollUntilExists(app.buttons["site-screenshot"]), "with a screenshot of the error")
    }

    /// As a user I want a wrong code to be reported as a failure, not as sent: the site answers "that code is not right", the app does not count the site as sent
    /// or done, and says what the page said so I can type the right code.
    func testAWrongEmailedCodeIsNotCountedAsSent() {
        let app = solveAndSend("code-1")
        let getCode = app.webViews.buttons["Email me a verification code"]
        XCTAssertTrue(getCode.waitForExistence(timeout: 30))
        var taps = 0
        while !server.requests.contains(where: { $0.path == "code" }) && taps < 6 { if getCode.isHittable { getCode.tap() }; Thread.sleep(forTimeInterval: 2); taps += 1 }
        let field = app.webViews.textFields["Verification code"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeTextChecked("000000")
        let start = Date()
        while !server.requests.contains(where: { $0.path == "rejected" }) && Date().timeIntervalSince(start) < 40 { Thread.sleep(forTimeInterval: 1) }
        XCTAssertTrue(server.requests.contains { $0.path == "rejected" }, "the app sent the form with the wrong code: \(server.requests)")
        Thread.sleep(forTimeInterval: 8)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "wrong-code"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertFalse(app.buttons["finish-done"].exists, "a rejected code is not a finished request")
        XCTAssertFalse(app.staticTexts["Sent."].exists, "and is not shown as sent")
        XCTAssertTrue(server.sentSites.isEmpty, "nothing was accepted by the broker")
    }
}
