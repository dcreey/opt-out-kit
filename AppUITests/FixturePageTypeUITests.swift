import XCTest

/// Kinds of opt-out page seen in the recorded sites (docs/PAGE-TYPES.md), each as a fixture broker the real engine fills and sends in Solve and send: the broker's own
/// record of what it received says what the app chose and typed. docs/TESTING.md, "End-to-end tests against fixture pages".
final class FixturePageTypeUITests: UITestCase {
    private var server: FixtureBrokers!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try FixtureBrokers.start()
    }

    private func solveAndSend(_ domain: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile"] + extra + server.launchArguments + ["-semi-domains", "\(domain).fixture.test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["assisted-site"].waitForExistence(timeout: 30), "the Solve-and-send screen opened")
        return app
    }

    /// Waits for the broker to receive the form, and returns the fields it got.
    private func sent(_ site: String, timeout: TimeInterval = 60) -> [String: String] {
        let arrived = server.waitForSent(timeout: timeout) { $0.contains(site) }
        if !arrived { let shot = XCTAttachment(screenshot: XCUIApplication().screenshot()); shot.name = "not-sent-\(site)"; shot.lifetime = .keepAlways; add(shot) }
        XCTAssertTrue(arrived, "the form was sent: \(server.requests)")
        return server.requests.last { $0.site == site && $0.path == "send" }?.fields ?? [:]
    }

    // MARK: Search opt out

    /// A site whose removal form asks for the link to my listing (92 of the recorded sites ask for it, 67 more say "search first"): the app searches the site for me,
    /// I tap my own profile in the results and say "This is me", and the form is filled with the link to that profile and sent.
    func testASearchFirstSiteIsSearchedForMeAndTheListingIPickGoesIntoItsForm() {
        let app = solveAndSend("search-1")
        let me = app.webViews.links["Pat Example, 34, Springfield IL"]
        XCTAssertTrue(me.waitForExistence(timeout: 30), "the site's results for my name are shown")
        XCTAssertTrue(server.requests.contains { $0.site == "fx_search_1" && $0.path == "search" && $0.fields["q"]?.contains("Pat") == true }, "the app searched the site for my name: \(server.requests)")
        XCTAssertTrue(server.sentSites.isEmpty, "nothing is sent before I pick my listing")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "search-results"; shot.lifetime = .keepAlways; add(shot)
        me.tap()
        let mine = app.buttons["assisted-my-profile"]
        XCTAssertTrue(mine.waitForExistence(timeout: 10), "This is me is offered")
        mine.tap()
        let fields = sent("fx_search_1")
        XCTAssertEqual(fields["listing"], server.url.appendingPathComponent("fx_search_1/profile-pat-example-il").absoluteString, "the form got the link to the listing I picked")
        XCTAssertEqual(fields["email"], "pat@example.com")
    }

    /// The same site when I am not in the results: "Not listed" sends nothing.
    func testNotBeingListedOnASearchFirstSiteSendsNothing() {
        let app = solveAndSend("search-1")
        XCTAssertTrue(app.webViews.links["Pat Example, 34, Springfield IL"].waitForExistence(timeout: 30))
        app.buttons["assisted-not-listed"].tap()
        Thread.sleep(forTimeInterval: 8)
        XCTAssertTrue(server.sentSites.isEmpty, "I am not listed there, so nothing was sent: \(server.requests)")
    }

    // MARK: Several addresses, emails, phones and names

    /// A page with boxes for previous addresses, a second email and phone, and other names (47 recorded forms have boxes for other addresses, 50 for a second email,
    /// 14 for a second phone): each box gets the right one of the person's, never the same value twice.
    func testAPageWithBoxesForPreviousAddressesAndASecondEmailAndPhoneGetsEachOne() {
        let app = solveAndSend("multi-1", extra: ["-uitest-seed-multi"])
        let f = sent("fx_multi_1")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "multi-sent"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertEqual(f["name"], "Pat Example")
        XCTAssertEqual(f["street"], "1 Main St"); XCTAssertEqual(f["city"], "Springfield"); XCTAssertEqual(f["state"], "IL"); XCTAssertEqual(f["zip"], "62701")
        XCTAssertEqual(f["prev_street"], "22 Oak Ave", "the previous address box got the person's previous address: \(f)")
        XCTAssertEqual(f["prev_city"], "Portland"); XCTAssertEqual(f["prev_zip"], "97201")
        XCTAssertEqual(f["prev2_street"], "9 Pine Rd", "the second previous address box got the next one: \(f)")
        XCTAssertEqual(f["prev2_city"], "Austin"); XCTAssertEqual(f["prev2_zip"], "78701")
        XCTAssertTrue(f["email"]?.contains("@") == true && f["email2"]?.contains("@") == true && f["email"] != f["email2"], "two different emails: \(f)")
        XCTAssertTrue(f["phone"]?.range(of: "^\\d{10}$", options: .regularExpression) != nil && f["phone2"]?.range(of: "^\\d{10}$", options: .regularExpression) != nil && f["phone"] != f["phone2"], "two different plain-digit phones: \(f)")
        XCTAssertTrue(f["other_names"]?.contains("Patricia") == true, "the box for other names has the other names: \(f)")
    }

    /// A page with one email box and one phone box and "Add another" buttons: the app presses them for the person's further emails and phones, and fills the new boxes.
    func testAddAnotherButtonsArePressedForTheFurtherEmailsAndPhones() {
        _ = solveAndSend("multiadd-1", extra: ["-uitest-seed-multi"])
        let f = sent("fx_multiadd_1")
        let emails = f.filter { $0.key.hasPrefix("email") && !$0.value.isEmpty }.values.sorted()
        let phones = f.filter { $0.key.hasPrefix("phone") && !$0.value.isEmpty }.values.sorted()
        XCTAssertGreaterThanOrEqual(emails.count, 3, "a box was added for each of the person's emails: \(f)")
        XCTAssertEqual(Set(emails).count, emails.count, "no email twice: \(f)")
        XCTAssertGreaterThanOrEqual(phones.count, 2, "a box was added for the second phone: \(f)")
        XCTAssertEqual(Set(phones).count, phones.count, "no phone twice: \(f)")
    }

    // MARK: Choose exactly one request

    /// Radio buttons: know, correct, delete, opt out of sale (only one may be chosen): the app chooses to delete, which removes the data and so covers the sale.
    func testWhenOnlyOneOfKnowCorrectDeleteAndOptOutCanBeChosenItChoosesDelete() {
        _ = solveAndSend("choose-1")
        let f = sent("fx_choose_1")
        XCTAssertEqual(f["request_type"], "delete", "\(f)")
    }

    /// Radio buttons with no delete among them: it chooses to opt out of the sale, never "know", and not the sensitive-information limit.
    func testWhenThereIsNoDeleteChoiceItChoosesOptOutOfTheSale() {
        _ = solveAndSend("chooseoptout-1")
        let f = sent("fx_chooseoptout_1")
        XCTAssertEqual(f["request_type"], "optout", "\(f)")
    }

    /// A request-type menu: the app picks the right entry (never "know" or "correct").
    func testARequestTypeMenuIsSetToARemovingChoice() {
        _ = solveAndSend("chooseselect-1")
        let f = sent("fx_chooseselect_1")
        XCTAssertTrue(["optout", "delete"].contains(f["request_type"] ?? ""), "a menu of requests is set to opt out or delete: \(f)")
    }

    /// Checkboxes ("select all that apply"): the removing ones are ticked and "know" and "correct" are not.
    func testCheckboxesTickTheRemovingRequestsAndNotKnowOrCorrect() {
        let app = solveAndSend("checkboxes-1")
        let box = XCTAttachment(screenshot: app.screenshot()); box.name = "checkboxes"; box.lifetime = .keepAlways; add(box)
        let f = sent("fx_checkboxes_1")
        let ticked = f["requests"] ?? ""
        XCTAssertFalse(ticked.contains("know") || ticked.contains("correct"), "know and correct were not ticked: \(f)")
        XCTAssertTrue(ticked.contains("delete") || ticked.contains("optout"), "a removing request was ticked: \(f)")
        // The page also has "To withdraw consent" and a hidden EU section with a consent box (affinityanswers.com): neither held the form as a certification, so it was sent.
    }

    // MARK: Checks, certifications, scripted and multi-step forms

    /// A real-shaped reCAPTCHA checkbox (274 recorded sites show one): the app fills the form and waits; when I tick the box in its frame, it sends, and the broker
    /// receives the response token.
    func testAReCaptchaCheckboxWaitsForMeAndTheFormIsSentWhenITickIt() {
        let app = solveAndSend("recaptcha-1")
        let box = app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'not a robot'")).firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 40), "the page shows its reCAPTCHA checkbox")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Solve the check'")).firstMatch.waitForExistence(timeout: 30), "the app says it waits for my check")
        XCTAssertTrue(server.sentSites.isEmpty, "nothing is sent while the check is open")
        var taps = 0
        let frame = box.frame
        while server.sentSites.isEmpty && taps < 8 {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + 28, dy: frame.midY)).tap()          // the tick box at the left of its label
            Thread.sleep(forTimeInterval: 3); taps += 1
        }
        let f = sent("fx_recaptcha_1", timeout: 20)
        XCTAssertEqual(f["g-recaptcha-response"], "token", "the broker received the check's response: \(f)")
    }

    /// A box certifying under penalty of perjury (about 10 recorded sites): the app never ticks it. It fills the rest and waits; I read it and tick it; it is then sent.
    func testACertificationBoxIsLeftForMeToTickAndTheFormIsSentWhenIHaveTickedIt() {
        let app = solveAndSend("certify-1")
        let certify = app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'penalty of perjury'")).firstMatch
        XCTAssertTrue(certify.waitForExistence(timeout: 40), "the page shows its certification")
        Thread.sleep(forTimeInterval: 8)
        XCTAssertTrue(server.sentSites.isEmpty, "the app did not tick the certification or send: \(server.requests)")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'tick a confirmation yourself'")).firstMatch.exists, "it says the certification is mine to tick")
        var taps = 0
        let frame = certify.frame
        while server.sentSites.isEmpty && taps < 8 {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + 20, dy: frame.minY + 20)).tap()
            Thread.sleep(forTimeInterval: 3); taps += 1
        }
        let f = sent("fx_certify_1", timeout: 20)
        XCTAssertEqual(f["certify"], "yes", "the broker saw the box ticked: \(f)")
    }

    /// A form the page builds with script a moment after it loads (69 recorded sites are script-built): the app waits for it, finds it, fills it and sends it.
    func testAFormBuiltByScriptAfterTheLoadIsFoundFilledAndSent() {
        _ = solveAndSend("jsform-1")
        let f = sent("fx_jsform_1")
        XCTAssertEqual(f["email"], "pat@example.com"); XCTAssertEqual(f["name"], "Pat Example")
    }

    /// A two-step form (email, Next; then name, Submit): the app fills the first step, presses Next, fills the second and sends.
    func testATwoStepFormIsWalkedThroughAndSent() {
        _ = solveAndSend("steps-1")
        let f = sent("fx_steps_1")
        XCTAssertEqual(f["email"], "pat@example.com", "the first step's box: \(f)"); XCTAssertEqual(f["name"], "Pat Example", "the second step's box: \(f)")
    }

    // MARK: Pages the person has to do something about

    /// A form that wants a photo of an ID (59 recorded sites ask for ID or a file): the app has none to give, so it fills what it can, sends nothing, and says so.
    func testAFormThatWantsAFileUploadIsNotSentWithoutIt() {
        let app = solveAndSend("upload-1")
        XCTAssertTrue(app.webViews.staticTexts["Opt out of fx_upload_1"].waitForExistence(timeout: 40), "the page loaded")
        Thread.sleep(forTimeInterval: 10)
        XCTAssertTrue(server.sentSites.isEmpty, "a form that needs an ID photo is never sent without it: \(server.requests)")
        XCTAssertFalse(app.buttons["finish-done"].exists, "and is not counted as done")
    }

    /// "Are you an authorized agent acting on behalf of someone?": the person is asking for themselves, so the app answers No and sends.
    func testAnAuthorizedAgentQuestionIsAnsweredNo() {
        _ = solveAndSend("agent-1")
        let f = sent("fx_agent_1")
        XCTAssertEqual(f["agent"], "no", "\(f)")
    }

    /// A required "Authorized agent? No / Yes" asked with radios (astoriacompany.com): a question the app answers No for a person asking for themselves, not a
    /// statement only the person may certify, so the form is sent.
    func testARequiredAuthorizedAgentRadioQuestionIsAnsweredNoAndTheFormSent() {
        _ = solveAndSend("agentradio-1")
        let f = sent("fx_agentradio_1")
        XCTAssertEqual(f["authorizedAgent"], "no", "\(f)")
    }

    /// A page that only offers a sign-in (58 recorded sites need an account): nothing is typed into the sign-in form and nothing is sent.
    func testASignInPageIsNeverFilledOrSent() {
        let app = solveAndSend("login-1")
        XCTAssertTrue(app.webViews.staticTexts["Sign in to fx_login_1"].waitForExistence(timeout: 40), "the page loaded")
        Thread.sleep(forTimeInterval: 10)
        XCTAssertTrue(server.requests.isEmpty, "nothing was sent to a sign-in form: \(server.requests)")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "sign-in"; shot.lifetime = .keepAlways; add(shot)
    }

    // MARK: Formats, traps and prompts

    /// A terms gate ("I Agree") in front of the form (about 20 recorded sites): the app never accepts terms for me; once I tap "I Agree", it fills and sends.
    func testATermsGateIsNeverAcceptedByTheAppAndTheFormIsSentOnceIHaveAgreed() {
        let app = solveAndSend("terms-1")
        let agree = app.webViews.buttons["I Agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 40), "the page shows its terms")
        Thread.sleep(forTimeInterval: 8)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "terms-after-wait"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'accept its terms'")).firstMatch.exists, "the app says the terms are mine to accept")
        XCTAssertTrue(server.sentSites.isEmpty, "nothing was sent behind the terms: \(server.requests)")
        let agreeNow = app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label == 'I Agree'")).firstMatch
        var taps = 0
        while server.sentSites.isEmpty && taps < 6 {
            if agreeNow.exists { let f = agreeNow.frame; app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).tap() }
            Thread.sleep(forTimeInterval: 3); taps += 1
        }
        let f = sent("fx_terms_1", timeout: 20)
        XCTAssertEqual(f["name"], "Pat Example")
    }

    /// I allowed the app to accept site terms for me, and every paragraph of this prompt was read by a person and passed: the app presses I Agree itself, fills the form and
    /// sends it, with nothing left for me.
    func testAPromptWhoseParagraphsWereReviewedIsAcceptedForMeWhenIAllowedIt() {
        _ = solveAndSend("termsok-1", extra: ["-uitest-approve-terms"])
        let f = sent("fx_termsok_1")
        XCTAssertEqual(f["name"], "Pat Example", "\(f)")
    }

    /// The same allowance does not cover a prompt no person has reviewed: it is left for me, as without the allowance.
    func testAnUnreviewedPromptIsLeftForMeEvenWhenIAllowedTermsInGeneral() {
        let app = solveAndSend("terms-1", extra: ["-uitest-approve-terms"])
        Thread.sleep(forTimeInterval: 15)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "terms-unreviewed"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'accept its terms'")).firstMatch.waitForExistence(timeout: 40), "the app says the terms are mine to accept; sent so far: \(server.requests)")
        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(server.sentSites.isEmpty, "nothing was accepted or sent for me: \(server.requests)")
    }

    /// A phone box that only takes "(123) 456-7890": the app retypes the number in the shape the box asks for.
    func testAPhoneBoxThatWantsParenthesesAndADashGetsThePhoneInThatShape() {
        _ = solveAndSend("phoneformat-1", extra: ["-uitest-seed-multi"])
        let f = sent("fx_phoneformat_1")
        XCTAssertNotNil(f["phone"]?.range(of: "^\\(\\d{3}\\) \\d{3}-\\d{4}$", options: .regularExpression), "the phone is in the box's shape: \(f)")
    }

    /// A country-code menu beside the phone box already says +1, so the box takes the number alone (digits only), and the menu is left as it is.
    func testAPhoneBoxBesideACountryCodeMenuTakesTheNumberAlone() {
        _ = solveAndSend("phonecountry-1", extra: ["-uitest-seed-multi"])
        let f = sent("fx_phonecountry_1")
        XCTAssertEqual(f["phone"], "7735550101", "digits only, no +1, spaces or punctuation: \(f)")
        XCTAssertEqual(f["cc"], "us", "the menu was left on its own choice")
    }

    /// A home-made state menu (a box showing "Choose state" over a list that opens when it is pressed, as saymine's portals draw it; 360mediadirect.com): the app
    /// opens it and picks the person's state, so the form is not left waiting on "This field is mandatory".
    func testAHomeMadeStateMenuIsOpenedAndGetsThePersonsState() {
        _ = solveAndSend("customstate-1")
        let f = sent("fx_customstate_1")
        XCTAssertEqual(f["state"], "Illinois", "\(f)")
    }

    /// A State menu that is built only once Country is set (adagio.io): the app reads the form again after filling, so the new menu gets the person's state and
    /// the form is sent, rather than "the form needs a choice we cannot make for you (State)".
    func testAStateMenuThatAppearsOnceCountryIsSetGetsThePersonsState() {
        _ = solveAndSend("dependentstate-1")
        let f = sent("fx_dependentstate_1")
        XCTAssertEqual(f["country"], "US", "\(f)"); XCTAssertEqual(f["state"], "IL", "\(f)")
    }

    /// A privacy page whose only way on is a "Submit a Privacy Request" link that opens a new tab (01advertising.com, to its Termly form): the app opens it in the
    /// same page, fills the form there and sends it.
    func testARequestLinkThatOpensANewTabIsFollowedAndItsFormSent() {
        _ = solveAndSend("blanklink-1")
        let f = sent("fx_blanklink_1")
        XCTAssertEqual(f["email"], "pat@example.com", "\(f)")
    }

    /// A date-of-birth box that wants yyyy-mm-dd: the app types the date in the shape the box accepts.
    func testADateBoxThatWantsYearMonthDayGetsTheBirthDateInThatShape() {
        _ = solveAndSend("dateformat-1")
        let f = sent("fx_dateformat_1")
        XCTAssertNotNil(f["dob"]?.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression), "the date is in the box's shape: \(f)")
    }

    /// Hidden boxes bots fill (off-screen, display none, invisible): the app leaves them empty, so the site does not take the request for a bot's.
    func testHiddenBoxesBotsFillAreLeftEmpty() {
        _ = solveAndSend("bottrap-1")
        let f = sent("fx_bottrap_1")
        XCTAssertEqual(f["name"], "Pat Example")
        XCTAssertEqual(f["website"] ?? "", "", "the off-screen box is empty: \(f)")
        XCTAssertEqual(f["company"] ?? "", "", "the display:none box is empty: \(f)")
        XCTAssertEqual(f["leave_empty"] ?? "", "", "the invisible box is empty: \(f)")
    }

    /// A page with a disabled email box and a bare "Continue" button: the app presses Continue, then fills the box that opened up and sends.
    func testABareContinueButtonIsPressedToOpenTheEmailBoxThenTheFormIsSent() {
        _ = solveAndSend("introcontinue-1")
        let f = sent("fx_introcontinue_1")
        XCTAssertEqual(f["email"], "pat@example.com", "the box opened by Continue got the email: \(f)")
    }

    /// A score-based reCAPTCHA that refuses a press a script made: the app does not claim the request went through; only my own press sends it.
    func testAFormThatRefusesAScriptedPressIsOnlySentByMyOwnPress() {
        let app = solveAndSend("recaptchafail-1")
        XCTAssertTrue(app.webViews.staticTexts["Opt out of fx_recaptchafail_1"].waitForExistence(timeout: 40), "the page loaded")
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'could not be verified'")).firstMatch.waitForExistence(timeout: 40), "the page refused the scripted press")
        XCTAssertTrue(server.sentSites.isEmpty, "nothing counted as sent: \(server.requests)")
        let button = app.webViews.buttons["Submit request"]
        var taps = 0
        while server.sentSites.isEmpty && taps < 6 {
            if button.exists { button.tap() }
            Thread.sleep(forTimeInterval: 3); taps += 1
        }
        _ = sent("fx_recaptchafail_1", timeout: 20)
    }

    /// Boxes named only by a heading they point at (aria-labelledby, no label element): the app still knows which is the name and which the email.
    func testBoxesLabelledOnlyByAriaAreFilledWithTheRightValues() {
        _ = solveAndSend("arialabel-1")
        let f = sent("fx_arialabel_1")
        XCTAssertEqual(f["n1"], "Pat Example"); XCTAssertEqual(f["e1"], "pat@example.com")
    }

    /// "I am the person this request is about": for my own profile the app ticks that plain self-statement and nothing else (not the
    /// the agent box), and sends.
    func testOnlyThePlainSelfStatementIsTickedForTheOwnerAndTheFormIsSent() {
        _ = solveAndSend("selfstatement-1")
        let f = sent("fx_selfstatement_1")
        XCTAssertEqual(f["self"], "yes", "the self-statement was ticked: \(f)")
        XCTAssertNil(f["agent"], "the agent box was not: \(f)")
    }

    /// The same page for a family member's profile: nothing is ticked on their behalf, so the form is not sent.
    func testNothingIsTickedForAFamilyProfileAndTheFormIsNotSent() {
        let app = solveAndSend("selfstatement-1", extra: ["-uitest-seed-family"])
        XCTAssertTrue(app.webViews.staticTexts["Opt out of fx_selfstatement_1"].waitForExistence(timeout: 40), "the page loaded")
        Thread.sleep(forTimeInterval: 10)
        XCTAssertTrue(server.sentSites.isEmpty, "no self-statement was ticked for a family profile: \(server.requests)")
    }

    /// A page with two opt-out forms (one for the sale, one for Mobile ID; the page stays when one is sent, as many sites do): the app sends each and says there are two.
    func testASecondOptOutFormOnThePageIsSentToo() {
        let app = solveAndSend("twoforms-1")
        let both = server.waitForSent(timeout: 40) { $0.filter { $0 == "fx_twoforms_1" }.count >= 2 }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "twoforms"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(both, "both forms were sent: \(server.requests)")
        let forms = Set(server.requests.filter { $0.site == "fx_twoforms_1" && $0.path == "send" }.compactMap { $0.fields["form"] })
        XCTAssertEqual(forms, ["main", "mobileid"], "each form was sent once: \(server.requests)")
        _ = app
    }

    /// A page with no form but an email address to write to: nothing is sent, and the app offers to email instead.
    func testAPageThatOnlyGivesAnEmailAddressOffersToSendAnEmail() {
        let app = solveAndSend("noformemail-1")
        XCTAssertTrue(app.buttons["assisted-write-email"].waitForExistence(timeout: 40), "the email is offered: Write the email")
        XCTAssertTrue(server.sentSites.isEmpty)
    }

    /// A name search whose results are built by script (the site needs a real browser): the scan waits for them and still finds my listing.
    func testAScanOfASiteWhoseResultsAreBuiltByScriptFindsMyListing() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset", "-uitest-seed-profile"] + server.launchArguments
        app.launch()
        app.tabBars.buttons["Sites"].tap()
        XCTAssertTrue(app.scrollUntilExists(app.buttons["scan-exposure"]))
        app.buttons["scan-exposure"].tap()
        app.buttons["start-scan"].tap()
        XCTAssertTrue(app.staticTexts["scan-summary"].waitForExistence(timeout: 90))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'scriptlisted-1.fixture.test'")).firstMatch.exists, "the script-built listing was found")
    }
}
