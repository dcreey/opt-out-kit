import XCTest
import OptOutKitCore
@testable import AssistedRunLogic

/// The semi-automated flow (Solve and send), pinned behavior by behavior on scripted pages and drivers, with no web view and no simulator. This is the flow
/// the others are built to match, so every rule it follows is written down here: what each blocker shows, when it sends, what each answer means, how it watches
/// the page, how a listing is picked, what is counted, and what happens between sites.
@MainActor
final class SemiAutomatedFlowTests: XCTestCase {

    // MARK: scripted pages

    @MainActor final class Page: AssistedPage {
        var blockerScript: [[AssistedBlocker]]
        var sendScript: [SubmitOutcome]
        var texts: [String] = []
        var changedScript: [Bool] = []
        var adoptScript: [Bool] = []
        var scrollResult = true
        private(set) var polls = 0, refills = 0, sends = 0, scrolls = 0, adopts = 0, textReads = 0, closed = false, presented = false
        var extraForms = 0
        init(blockers: [[AssistedBlocker]] = [[]], sends: [SubmitOutcome] = [.submitted(awaitingEmail: false)]) { blockerScript = blockers; sendScript = sends }
        func blockers() async -> [AssistedBlocker] { defer { polls += 1 }; return blockerScript[min(polls, blockerScript.count - 1)] }
        func refill() async { refills += 1 }
        func send() async -> SubmitOutcome { defer { sends += 1 }; return sendScript[min(sends, sendScript.count - 1)] }
        func pageText() async -> String { guard !texts.isEmpty else { return "" }; defer { textReads += 1 }; return texts[min(textReads, texts.count - 1)] }
        func changed() async -> Bool { changedScript.isEmpty ? false : changedScript[min(max(0, polls - 1), changedScript.count - 1)] }
        func adoptNewForm() async -> Bool { defer { adopts += 1 }; return adoptScript.isEmpty ? false : adoptScript[min(adopts, adoptScript.count - 1)] }
        var waitingForCode = false, typing = false, presses: Int? = nil
        func pressesSinceFill() async -> Int? { presses }
        func userIsTyping() async -> Bool { typing }
        func awaitingCode() async -> Bool { waitingForCode }
        func scrollToOptOut() async -> Bool { scrolls += 1; return scrollResult }
        func moreForms() async -> Bool { if extraForms > 0 { extraForms -= 1; return true }; return false }
        var formsRemaining: Int { extraForms }
        func present() { presented = true }
        func close() { closed = true }
    }

    @MainActor final class Search: SearchPage {
        var url: URL?
        private(set) var closed = false
        init(_ url: URL?) { self.url = url }
        func currentURL() -> URL? { url }
        func close() { closed = true }
    }

    @MainActor final class Driver: AssistedDriver {
        var pages: [String: [Page?]]               // per host: what each prepare returns, the last repeating
        var searches: [String: Search] = [:]
        var reasons: [String: String] = [:]
        var held: [String: Page] = [:]               // what prepareHeld returns per host (a page opened and held for the person)
        private(set) var prepared: [String] = [], listingURLs: [URL?] = []
        init(_ pages: [String: Page?]) { self.pages = pages.mapValues { [$0] } }
        func prepare(_ form: OptOutForm, plan: FillPlan) async -> AssistedPage? { await prepare(form, plan: plan, listingURL: nil) }
        func prepare(_ form: OptOutForm, plan: FillPlan, listingURL: URL?) async -> AssistedPage? {
            let host = form.page.host ?? ""; prepared.append(host); listingURLs.append(listingURL)
            guard var list = pages[host], !list.isEmpty else { return nil }
            let next = list.count > 1 ? list.removeFirst() : list[0]
            pages[host] = list
            return next
        }
        func prepareHeld(_ form: OptOutForm, plan: FillPlan, fillNothing: Bool) async -> AssistedPage? { if let h = held[form.page.host ?? ""] { return h }; return await prepare(form, plan: plan) }
        func openSearch(_ url: URL) async -> SearchPage? { searches[url.host ?? ""] }
        func failureReason(for form: OptOutForm) -> String? { reasons[form.page.host ?? ""] }
    }

    private final class Sink { var rows: [(domain: String, result: AutoOptOutResult)] = []; var results: [AutoOptOutResult] { rows.map(\.result) } }

    private func item(_ host: String, email: String? = nil, fields: [FormField]? = nil, fallback: String? = nil, search: URL? = nil, emailOnly: Bool = false) -> AssistedRunner.Item {
        func form(_ h: String) -> OptOutForm { OptOutForm(page: URL(string: "https://\(h)/optout")!, method: "post", action: nil, fields: fields ?? [FormField(type: "email", name: "email", label: "Email")], hops: 1) }
        let f = form(host)
        let entry = DirectoryEntry(id: host.replacingOccurrences(of: ".", with: "_"), domain: host, name: host, bucket: "direct", tier: .B, automation: .guided, optOutForm: f, contactEmail: email)
        var it = AssistedRunner.Item(entry: entry, form: f, plan: FillPlan(values: [], verdict: .ready))
        if let fallback { it.fallbackForm = form(fallback) }
        it.searchURL = search; it.emailOnly = emailOnly
        return it
    }

    private func make(_ items: [AssistedRunner.Item], _ driver: Driver, _ sink: Sink, wait: TimeInterval = 5) -> AssistedRunner {
        let r = AssistedRunner(items: items, driver: driver) { e, res in sink.rows.append((e.domain, res)) }
        r.pollInterval = 0.01; r.pauseAfterSent = 0; r.waitLimit = wait; r.watchInterval = 0.02
        return r
    }

    private func until(_ cond: @autoclosure () -> Bool, seconds: Double = 3) async { let end = Date().addingTimeInterval(seconds); while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 4_000_000) } }
    private func start(_ r: AssistedRunner) -> Task<Void, Never> { Task { @MainActor in await r.run() } }
    private func finish(_ run: Task<Void, Never>, _ r: AssistedRunner) async {
        await until(r.finished)
        XCTAssertTrue(r.finished, "the run did not finish")
        if r.finished { await run.value } else { run.cancel() }
    }

    // MARK: what each blocker shows, and that nothing is sent until it is gone

    func testEachBlockerShowsItsOwnPhaseAndNothingIsSentWhileItIsUp() async {
        let cases: [(AssistedBlocker, AssistedRunner.Phase)] = [(.terms, .waitingForTerms), (.certify("I certify"), .waitingForCertification), (.choose("Request type"), .waitingForChoice("Request type")), (.check("a human check"), .waitingForCheck)]
        for (blocker, phase) in cases {
            let page = Page(blockers: [[blocker], [blocker], [blocker], []]); let sink = Sink()
            let r = make([item("a.example")], Driver(["a.example": page]), sink)
            var seen: [AssistedRunner.Phase] = []
            r.phaseChanged = { seen.append($0) }
            await finish(start(r), r)
            XCTAssertTrue(seen.contains(phase), "\(blocker) shows \(phase)")
            XCTAssertEqual(page.sends, 1, "sent once, after it cleared"); XCTAssertGreaterThanOrEqual(page.polls, 4)
        }
    }

    func testTermsOutrankACertificationWhichOutranksAChoiceWhichOutranksACheck() async {
        let page = Page(blockers: [[.check("c"), .choose("x"), .certify("y"), .terms], [.check("c"), .choose("x"), .certify("y")], [.check("c"), .choose("x")], [.check("c")], []])
        let r = make([item("a.example")], Driver(["a.example": page]), Sink())
        var seen: [AssistedRunner.Phase] = []
        r.phaseChanged = { seen.append($0) }          // every change, in order (a timer that sampled the phase missed the last one on CI's slower machine)
        await finish(start(r), r)
        let order = seen.filter { [.waitingForTerms, .waitingForCertification, .waitingForCheck].contains($0) || { if case .waitingForChoice = $0 { return true } else { return false } }($0) }
        XCTAssertEqual(order.first, .waitingForTerms); XCTAssertTrue(order.contains(.waitingForCertification)); XCTAssertEqual(order.last, .waitingForCheck)
    }

    func testTheFormIsFilledAgainJustBeforeEverySend() async {
        let page = Page(blockers: [[.check("c")], []])
        let r = make([item("a.example")], Driver(["a.example": page]), Sink())
        await finish(start(r), r)
        XCTAssertGreaterThanOrEqual(page.refills, 1, "a check can reload the form, so the details go back in before sending")
    }

    func testAWaitThatNeverEndsTimesOutAndIsRecordedForThePersonToFinish() async {
        let page = Page(blockers: [[.check("c")]]); let sink = Sink()
        let r = make([item("a.example")], Driver(["a.example": page]), sink, wait: 0.15)
        await finish(start(r), r)
        XCTAssertEqual(page.sends, 0)
        XCTAssertEqual(sink.results, [.needsYou("timed out waiting for the check")])
    }

    // MARK: what each answer to a send means

    func testASentFormIsRecordedOnceWithItsEmailFlag() async {
        let sink = Sink()
        let r = make([item("a.example"), item("b.example")], Driver(["a.example": Page(sends: [.submitted(awaitingEmail: true)]), "b.example": Page()]), sink)
        await finish(start(r), r)
        XCTAssertEqual(sink.rows.map(\.domain), ["a.example", "b.example"])
        XCTAssertEqual(sink.results, [.submitted(awaitingEmail: true), .submitted(awaitingEmail: false)])
        XCTAssertEqual(r.sentCount, 2); XCTAssertEqual(r.sentAwaitingEmail, 1, "one of them waits on an email link")
        XCTAssertEqual(r.celebrate, 2)
    }

    func testAnErrorAfterSendingWaitsForThePersonAndIsRecordedAsFailedIfTheyMoveOn() async {
        for answer in [SubmitOutcome.rejected("bad field"), .failed("no success message was shown")] {
            let sink = Sink()
            let r = make([item("a.example")], Driver(["a.example": Page(sends: [answer])]), sink)
            let run = start(r)
            await until({ if case .needsMore = r.phase { return true } else { return false } }())
            if case .needsMore = r.phase {} else { XCTFail("waits for the person after \(answer)") }
            XCTAssertFalse(r.finished)
            r.next(); await finish(run, r)
            if case .failed = sink.results.first {} else { XCTFail("recorded as failed: \(sink.results)") }
            XCTAssertNotNil(r.previousNote, "the next site's screen says why the last one did not go")
        }
    }

    /// Reported: "Send an email instead" on a site whose form had not gone through, "Yes, I sent it" on return, and the app said the form did not go through and offered the email again.
    func testEmailingASiteWhoseFormDidNotGoThroughRecordsItAsEmailedAndOffersNothing() async {
        let sink = Sink()
        let r = make([item("a.example", email: "privacy@a.example")], Driver(["a.example": Page(sends: [.failed("no success message was shown")])]), sink)
        let run = start(r)
        await until({ if case .needsMore = r.phase { return true } else { return false } }())
        r.finishByEmail()
        await finish(run, r)
        XCTAssertEqual(sink.results, [.emailed], "emailed, not failed")
        XCTAssertNil(r.emailOffer, "no second offer to write the email")
    }

    func testARateLimitIsNotHeldAgainstTheSite() async {
        let sink = Sink()
        let r = make([item("a.example")], Driver(["a.example": Page(sends: [.failed(AutoOptOut.rateLimited)])]), sink)
        let run = start(r)
        await until({ if case .needsMore = r.phase { return true } else { return false } }())
        r.next(); await finish(run, r)
        XCTAssertEqual(sink.results, [.needsYou(AutoOptOut.rateLimited)], "no failed attempt is recorded against the site")
    }

    /// A form that searches before it removes answered "No data was found": the site is recorded as not listed (done), not as a failed send, and the page
    /// stays for the person until they move on.
    func testASiteWhoseSearchFindsNoRecordIsRecordedAsNotListed() async {
        let sink = Sink()
        let r = make([item("a.example")], Driver(["a.example": Page(sends: [.notListed])]), sink)
        let run = start(r)
        await until({ if case .needsMore(let why) = r.phase { return why == AutoOptOut.noRecordFound } else { return false } }())
        r.next(); await finish(run, r)
        XCTAssertEqual(sink.results, [.notListed])
    }

    func testACheckThatAppearsAfterSendingIsWaitedForAgainThenSentAgain() async {
        let page = Page(sends: [.challenged("a human check"), .challenged("a human check"), .submitted(awaitingEmail: false)]); let sink = Sink()
        let r = make([item("a.example")], Driver(["a.example": page]), sink)
        await finish(start(r), r)
        XCTAssertEqual(page.sends, 3); XCTAssertEqual(sink.results, [.submitted(awaitingEmail: false)])
    }

    func testAPageThatKeepsChallengingStopsAfterThreeAttempts() async {
        let page = Page(sends: [.challenged("a human check")]); let sink = Sink()
        let r = make([item("a.example")], Driver(["a.example": page]), sink)
        await finish(start(r), r)
        XCTAssertEqual(page.sends, 3, "three tries")
        XCTAssertEqual(sink.results, [.challenged("the check came back")])
    }

    func testADryRunFillsAndRecordsThatNothingWasSent() async {
        let sink = Sink()
        let r = make([item("a.example")], Driver(["a.example": Page(sends: [.filledNotSubmitted])]), sink)
        await finish(start(r), r)
        XCTAssertEqual(sink.results, [.dryRunReady]); XCTAssertEqual(r.sentCount, 0)
    }

    // MARK: watching the page while the person works

    func testAConfirmationThePersonCausedIsNoticedWhileTheCheckIsStillUp() async {
        let page = Page(blockers: [[.check("c")]]); page.texts = ["Opt out form", "Opt out form", "Your request has been received. Thank you."]; let sink = Sink()
        let r = make([item("a.example")], Driver(["a.example": page]), sink)
        await finish(start(r), r)
        XCTAssertEqual(page.sends, 0, "they pressed the page's own button; the app did not")
        XCTAssertEqual(sink.results, [.submitted(awaitingEmail: false)])
    }

    func testAConfirmationAfterAFailedSendIsNoticedAndFinishesTheSite() async {
        let page = Page(sends: [.failed("no success message was shown")]); page.texts = ["form", "form", "Thank you. Your request has been submitted."]; let sink = Sink()
        let r = make([item("a.example"), item("b.example")], Driver(["a.example": page, "b.example": Page()]), sink)
        await finish(start(r), r)
        XCTAssertEqual(sink.results.first, .submitted(awaitingEmail: false)); XCTAssertEqual(sink.rows.count, 2, "and it went on to the next site")
    }

    func testANewFormThatAppearsIsFilledAndTheScreenSaysSo() async {
        let page = Page(blockers: [[.check("c")]]); page.texts = ["form", "form with a new window open"]; page.adoptScript = [true]; page.changedScript = [true]
        let r = make([item("a.example")], Driver(["a.example": page]), Sink(), wait: 0.3)
        let run = start(r)
        await until(r.notice != nil)
        XCTAssertEqual(r.notice, "A new form appeared and we filled it in. Check it.")
        r.skip(); await finish(run, r)
    }

    func testTheOptOutButtonIsScrolledToAtMostTwiceAndOnlyForAChangeInThePage() async {
        let page = Page(blockers: [[.check("c")]]); page.texts = ["form", "Opt out of the sale", "Opt out of the sale of my data now", "Opt out of the sale today", "Opt out of the sale again"]; page.changedScript = [true]
        let r = make([item("a.example")], Driver(["a.example": page]), Sink(), wait: 0.4)
        let run = start(r)
        await until(page.textReads >= 5)
        r.skip(); await finish(run, r)
        XCTAssertEqual(page.scrolls, 2, "never more than twice per site, so the page does not jump under the person")
        let still = Page(blockers: [[.check("c")]]); still.texts = ["form", "Opt out of the sale"]; still.changedScript = [false]
        let r2 = make([item("a.example")], Driver(["a.example": still]), Sink(), wait: 0.3)
        let run2 = start(r2); await until(still.textReads >= 2); r2.skip(); await finish(run2, r2)
        XCTAssertEqual(still.scrolls, 0, "a change in the words alone (the person scrolling) never moves the page")
    }

    // MARK: Mark as done

    func testMarkAsDoneWhileWaitingOnACheckFinishesTheSiteAsSent() async {
        let sink = Sink()
        let r = make([item("a.example")], Driver(["a.example": Page(blockers: [[.check("c")]])]), sink)
        let run = start(r); await until(r.phase == .waitingForCheck)
        await r.markDone(); await finish(run, r)
        XCTAssertEqual(sink.results, [.submitted(awaitingEmail: false)])
    }

    func testMarkAsDoneOnAPageThatMentionsAnEmailAsksWhetherAnEmailFollows() async {
        let cases: [(FinishQuestion.Answer, AutoOptOutResult)] = [(.emailFollows, .submitted(awaitingEmail: true)), (.unsure, .submitted(awaitingEmail: true)), (.done, .submitted(awaitingEmail: false))]
        for (answer, expected) in cases {
            let page = Page(blockers: [[.check("c")]]); page.texts = ["Check your email to confirm your request."]; let sink = Sink()
            let r = make([item("a.example")], Driver(["a.example": page]), sink); r.asksAboutFollowUp = true
            let run = start(r); await until(r.phase == .waitingForCheck)
            let tap = Task { @MainActor in await r.markDone() }
            await until(r.finishQuestion.pending != nil)
            XCTAssertEqual(r.finishQuestion.pending?.pageSaidEmail, true); XCTAssertEqual(r.finishQuestion.pending?.allowsNotYet, true)
            r.finishQuestion.answer(answer); await tap.value; await finish(run, r)
            XCTAssertEqual(sink.results, [expected], "\(answer)")
        }
    }

    func testAPageWhoseFormCannotBeReadAndWithNoEmailIsOpenedAndHeldNotSkippedAndNeverSent() async {
        let page = Page(blockers: [[]]); page.texts = ["Opt out here."]; let sink = Sink()
        let d = Driver(["a.example": nil]); d.reasons["a.example"] = "noform"; d.held["a.example"] = page
        let r = make([item("a.example")], d, sink)
        let run = start(r)
        await until(r.page != nil)
        XCTAssertNotNil(r.page, "the page is on screen for the person"); XCTAssertEqual(page.sends, 0)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(page.sends, 0, "nothing is sent for the person on a held page"); XCTAssertTrue(sink.results.isEmpty)
        r.skip(); await finish(run, r)
    }

    func testMarkAsDoneThenNotYetKeepsTheSiteOpen() async {
        let page = Page(blockers: [[.check("c")]]); page.texts = ["Thanks."]; let sink = Sink()
        let r = make([item("a.example")], Driver(["a.example": page]), sink); r.asksAboutFollowUp = true
        let run = start(r); await until(r.phase == .waitingForCheck)
        let tap = Task { @MainActor in await r.markDone() }
        await until(r.finishQuestion.pending != nil)
        r.finishQuestion.answer(.notYet); await tap.value
        XCTAssertTrue(sink.results.isEmpty); XCTAssertFalse(r.finished)
        r.skip(); await finish(run, r)
    }

    func testAPageThatSaysItIsEntirelyDoneIsNotAskedAbout() async {
        let page = Page(); page.texts = ["Your removal request has been completed. You are all set."]; let sink = Sink()
        let r = make([item("a.example")], Driver(["a.example": page]), sink); r.asksAboutFollowUp = true
        await finish(start(r), r)
        XCTAssertNil(r.finishQuestion.pending); XCTAssertEqual(sink.results, [.submitted(awaitingEmail: false)])
    }

    func testASendWithNoWordOnWhatFollowsIsAskedAboutWhereAPersonIsOnScreen() async {
        let cases: [(FinishQuestion.Answer, AutoOptOutResult)] = [(.done, .submitted(awaitingEmail: false)), (.emailFollows, .submitted(awaitingEmail: true)), (.unsure, .submitted(awaitingEmail: true))]
        for (answer, expected) in cases {
            let page = Page(); page.texts = ["Thank you. Your request was received."]; let sink = Sink()
            let r = make([item("a.example")], Driver(["a.example": page]), sink); r.asksAboutFollowUp = true
            let run = start(r)
            await until(r.finishQuestion.pending != nil)
            XCTAssertEqual(r.finishQuestion.pending?.site, "a.example"); XCTAssertEqual(r.finishQuestion.pending?.allowsNotYet, true)
            XCTAssertTrue(sink.results.isEmpty, "nothing is saved as done before the answer")
            r.finishQuestion.answer(answer); await finish(run, r)
            XCTAssertEqual(sink.results, [expected], "\(answer)")
        }
    }

    func testNotYetAfterASendKeepsThePersonOnTheSiteAndAsksAgainOnNext() async {
        let page = Page(); page.texts = ["Thank you. Your request was received."]; let sink = Sink()
        let r = make([item("a.example")], Driver(["a.example": page]), sink); r.asksAboutFollowUp = true
        let run = start(r)
        await until(r.finishQuestion.pending != nil)
        r.finishQuestion.answer(.notYet)
        await until(r.awaitingNext)
        XCTAssertNil(r.finishQuestion.pending); XCTAssertEqual(r.index, 0, "still on the site")
        r.next()
        await until(r.finishQuestion.pending != nil)
        r.finishQuestion.answer(.done); await finish(run, r)
        XCTAssertEqual(sink.results.last, .submitted(awaitingEmail: false))
    }

    func testSkippingWhileAskedCountsAsNotSure() async {
        let page = Page(); page.texts = ["Thank you. Your request was received."]; let sink = Sink()
        let r = make([item("a.example")], Driver(["a.example": page]), sink); r.asksAboutFollowUp = true
        let run = start(r)
        await until(r.finishQuestion.pending != nil)
        r.skip(); await finish(run, r)
        XCTAssertEqual(sink.results.first, .submitted(awaitingEmail: true), "a send that was never confirmed finished waits on an email")
    }

    func testTheBackgroundRunNeverAsksAnything() async {
        let page = Page(); page.texts = ["Thank you. Your request was received."]; let sink = Sink()
        let r = make([item("a.example")], Driver(["a.example": page]), sink)     // asksAboutFollowUp stays false
        await finish(start(r), r)
        XCTAssertNil(r.finishQuestion.pending); XCTAssertEqual(sink.results, [.submitted(awaitingEmail: false)])
    }

    // MARK: sites that are not a plain form

    func testASiteWhereTheAppNeverPressesSendIsLeftToThePersonToFinish() async {
        let blockWidget = item("usatrace.com")
        let page = Page(); let sink = Sink()
        let r = make([blockWidget], Driver(["usatrace.com": page]), sink)
        let run = start(r)
        await until({ if case .needsMore = r.phase { return true } else { return false } }())
        XCTAssertEqual(page.sends, 0, "a block-profile page has no form of ours to send")
        await r.markDone(); await finish(run, r)
        XCTAssertEqual(sink.results, [.submitted(awaitingEmail: false)])
    }

    func testAPageThatWillNotLoadIsTriedInItsEnglishFormThenSkippedWithTheReason() async {
        let sink = Sink()
        let english = Page()
        let d = Driver(["a.example": nil, "en.a.example": english])
        let r = make([item("a.example", fallback: "en.a.example")], d, sink)
        await finish(start(r), r)
        XCTAssertEqual(d.prepared, ["a.example", "en.a.example"], "the translated page first, then the English one")
        XCTAssertEqual(sink.results, [.submitted(awaitingEmail: false)])
        let d2 = Driver(["b.example": nil]); let sink2 = Sink()
        let r2 = make([item("b.example")], d2, sink2)
        await finish(start(r2), r2)
        XCTAssertEqual(sink2.results, [.needsYou(AssistedRunner.unloadable)]); XCTAssertEqual(r2.skippedCount, 1)
    }

    func testAPageWithNoFormIsSkippedWithTheReasonWhenNoAddressIsKnown() async {
        let d = Driver(["a.example": nil]); d.reasons["a.example"] = "noform"; let sink = Sink()
        let r = make([item("a.example")], d, sink)
        await finish(start(r), r)
        XCTAssertEqual(sink.results, [.needsYou(AssistedRunner.noForm)]); XCTAssertNotNil(r.previousNote)
    }

    // MARK: picking the person's own listing

    func testTheListingIsPickedThenTheFormOpensWithItsAddress() async {
        let search = URL(string: "https://people.example/search?name=pat")!
        let d = Driver(["people.example": Page()]); let sp = Search(search); d.searches["people.example"] = sp
        let sink = Sink()
        let r = make([item("people.example", search: search)], d, sink)
        let run = start(r)
        await until(r.phase == .pickingListing)
        XCTAssertEqual(r.phase, .pickingListing)
        r.confirmListing()
        XCTAssertEqual(r.phase, .pickingListing, "the search page itself is not a listing: nothing is chosen")
        XCTAssertNotNil(r.notice, "and the person is told to tap their profile first")
        sp.url = URL(string: "https://people.example/pat-example-il")!
        r.confirmListing()
        await finish(run, r)
        XCTAssertEqual(d.listingURLs.last??.absoluteString, "https://people.example/pat-example-il", "the form is opened with the picked listing")
        XCTAssertEqual(sink.results, [.submitted(awaitingEmail: false)]); XCTAssertTrue(sp.closed)
    }

    func testNotListedSendsNothingAndIsRecordedAsSuch() async {
        let search = URL(string: "https://people.example/search?name=pat")!
        let d = Driver(["people.example": Page()]); d.searches["people.example"] = Search(search)
        let sink = Sink()
        let r = make([item("people.example", search: search)], d, sink)
        let run = start(r); await until(r.phase == .pickingListing)
        r.notListed(); await finish(run, r)
        XCTAssertEqual(sink.results, [.skippedNotListed]); XCTAssertTrue(d.prepared.isEmpty, "the form was never opened")
    }

    // MARK: between sites

    func testTheNextSiteIsLoadingWhileThePersonWorksOnTheCurrentOne() async {
        let d = Driver(["a.example": Page(blockers: [[.check("c")]]), "b.example": Page()])
        let r = make([item("a.example"), item("b.example")], d, Sink())
        let run = start(r); await until(r.phase == .waitingForCheck)
        await until(d.prepared.contains("b.example"))
        XCTAssertTrue(d.prepared.contains("b.example"), "the second page loads in the background")
        XCTAssertEqual(r.index, 0)
        r.skip(); await finish(run, r)
    }

    func testEverySitesPageIsClosedWhenItsTurnEnds() async {
        let a = Page(), b = Page(blockers: [[.check("c")]])
        let r = make([item("a.example"), item("b.example")], Driver(["a.example": a, "b.example": b]), Sink())
        let run = start(r); await until(r.phase == .waitingForCheck)
        XCTAssertTrue(a.closed); XCTAssertTrue(b.presented, "the page the person works on is shown")
        r.skip(); await finish(run, r)
        XCTAssertTrue(b.closed)
    }

    func testSkippedAndSentSitesAreCountedSeparately() async {
        let sink = Sink()
        let r = make([item("a.example"), item("b.example"), item("c.example")],
                     Driver(["a.example": Page(), "b.example": Page(blockers: [[.check("c")]]), "c.example": Page()]), sink)
        let run = start(r); await until(r.index == 1 && r.phase == .waitingForCheck)
        r.skip(); await finish(run, r)
        XCTAssertEqual(sink.results, [.submitted(awaitingEmail: false), .needsYou("skipped"), .submitted(awaitingEmail: false)])
        XCTAssertEqual(r.skippedCount, 1); XCTAssertEqual(r.sentCount, 2); XCTAssertEqual(r.celebrate, 2)
    }

    func testTheRunIsOnlyFinishedAfterTheLastSite() async {
        let r = make([item("a.example"), item("b.example")], Driver(["a.example": Page(blockers: [[.check("c")]]), "b.example": Page(blockers: [[.check("c")]])]), Sink())
        let run = start(r); await until(r.phase == .waitingForCheck)
        XCTAssertFalse(r.finished); r.skip()
        await until(r.index == 1 && r.phase == .waitingForCheck)
        XCTAssertFalse(r.finished); r.skip(); await finish(run, r)
        XCTAssertTrue(r.finished)
    }

    // MARK: several forms, steps, and what happens when the person turned sending off

    func testEveryFormOfAPageIsSentAndTheScreenSaysWhichOne() async {
        let page = Page(); page.extraForms = 2; let sink = Sink()
        let r = make([item("a.example")], Driver(["a.example": page]), sink)
        var seen = Set<Int>()
        let watcher = Task { @MainActor in while !r.finished { seen.insert(r.pageForms.current * 10 + r.pageForms.total); try? await Task.sleep(nanoseconds: 1_000_000) } }
        page.blockerScript = [[]]
        await finish(start(r), r); watcher.cancel()
        XCTAssertEqual(page.sends, 3); XCTAssertEqual(sink.rows.count, 1)
    }

    func testWithSendingForThePersonOffNothingIsPressedAndMovingOnIsNotAFailure() async {
        let page = Page(); let sink = Sink()
        let r = make([item("a.example")], Driver(["a.example": page]), sink)
        r.autoSubmit = { false }
        let run = start(r); await until(r.phase == .manualSend)
        XCTAssertEqual(page.sends, 0); r.next(); await finish(run, r)
        XCTAssertEqual(sink.results, [.needsYou("you sent it yourself and we saw no confirmation")])
    }

    func testMovingOnAfterAnAutoSendConfirmationNeedsNoTapButManualDoes() async {
        for auto in [true, false] {
            let page = Page(); page.texts = ["form", "form", "Thank you. Your request has been received."]
            let r = make([item("a.example"), item("b.example")], Driver(["a.example": page, "b.example": Page(blockers: [[.check("c")]])]), Sink())
            r.autoSubmit = { auto }
            let run = start(r)
            if auto { await until(r.index == 1); XCTAssertEqual(r.index, 1, "Auto-send on: it moves on by itself") }
            else { await until(r.awaitingNext); try? await Task.sleep(nanoseconds: 120_000_000); XCTAssertEqual(r.index, 0, "Auto-send off: it waits for Next site"); r.next(); await until(r.index == 1) }
            r.skip(); await finish(run, r)
        }
    }
}

/// A form a real page load showed to need the person (an agent's details, questions the app cannot read, a file): the app fills in and never presses send.
@MainActor
final class NeedsPersonTests: XCTestCase {
    func testOnlyThoseFormsAreHandsOff() {
        func item(_ blockers: [String]) -> AssistedRunner.Item {
            let f = OptOutForm(page: URL(string: "https://x.example/optout")!, method: "post", action: nil, fields: [FormField(type: "email", name: "email", label: "Email")], hops: 1)
            var e = DirectoryEntry(id: "x_example", domain: "x.example", name: "X", bucket: "direct", tier: .B, automation: .guided, optOutForm: f, contactEmail: nil)
            e.liveForm = LiveFormCheck(checked: "2026-11-09", found: true, page: "https://x.example/optout", blockers: blockers)
            return AssistedRunner.Item(entry: e, form: f, plan: FillPlan(values: [], verdict: .ready))
        }
        for b in ["agent", "other", "file", "business"] { XCTAssertTrue(item([b]).handsOff, b) }
        XCTAssertFalse(item([]).handsOff); XCTAssertFalse(item(["check:a human check"]).handsOff, "a human check the person clears is the ordinary semi-automated case")
    }

    func testAPageWithNoReadableFormIsHeldForThePersonAndAShowOnlyPageFillsNothing() {
        let f = OptOutForm(page: URL(string: "https://y.example/optout")!, method: "post", action: nil, fields: [], hops: 1)
        var e = DirectoryEntry(id: "y_example", domain: "y.example", name: "Y", bucket: "direct", tier: .B, automation: .guided, optOutURL: f.page, contactEmail: nil)
        let held = AssistedRunner.Item(entry: e, form: f, plan: FillPlan(values: [], verdict: .ready))
        XCTAssertTrue(held.noReadableForm); XCTAssertTrue(held.handsOff); XCTAssertEqual(held.mode, .fillsAndHolds)
        e.noFill = true
        let shown = AssistedRunner.Item(entry: e, form: f, plan: FillPlan(values: [], verdict: .ready))
        XCTAssertEqual(shown.mode, .showsOnly); XCTAssertTrue(shown.handsOff)
    }
}
