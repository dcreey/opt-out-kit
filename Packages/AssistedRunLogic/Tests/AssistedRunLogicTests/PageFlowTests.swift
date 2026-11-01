import XCTest
import OptOutKitCore
@testable import AssistedRunLogic

/// The two things every flow does the same way: read one press of send, and watch the page for what the person did.
@MainActor
final class PageFlowTests: XCTestCase {
    private typealias Page = SemiAutomatedFlowTests.Page

    func testEveryAnswerToASendHasOneMeaningInEveryFlow() async {
        let cases: [(SubmitOutcome, SendStep)] = [
            (.submitted(awaitingEmail: true), .sent(awaitingEmail: true, moreForms: false)),
            (.challenged(PageFlow.nextStepMarker), .nextStep),
            (.challenged("a reCAPTCHA that rejected the automatic send"), .handToPerson),
            (.challenged("a bot check"), .checkAppeared("a bot check")),
            (.rejected("bad field"), .notConfirmed(.rejected("bad field"))),
            (.failed("no success message was shown"), .notConfirmed(.failed("no success message was shown"))),
            (.filledNotSubmitted, .dryRun),
        ]
        for (answer, step) in cases {
            let page = Page(sends: [answer])
            let got = await PageFlow.sendOnce(page)
            XCTAssertEqual(got, step, "\(answer)")
        }
    }

    func testASentFormSaysWhetherAnotherFormIsReadyAndFillsIt() async {
        let page = Page(); page.extraForms = 1
        let first = await PageFlow.sendOnce(page); let second = await PageFlow.sendOnce(page)
        XCTAssertEqual(first, .sent(awaitingEmail: false, moreForms: true))
        XCTAssertEqual(second, .sent(awaitingEmail: false, moreForms: false))
    }

    func testWatchingFindsAConfirmationTheInstructionsAlreadyOnThePageAreNotOne() async {
        let page = Page(); page.texts = ["Your request is submitted only after you enter the code.", "Your request is submitted only after you enter the code.\nThank you. Your request has been received."]
        var base = await page.pageText(), scrolls = 0
        let seen = await PageFlow.watch(page, baseline: &base, autoScrolls: &scrolls)
        XCTAssertEqual(seen, .confirmed(awaitingEmail: false))
    }

    func testWatchingFillsANewFormAndScrollsToAnOptOutButtonOnlyForARealChange() async {
        let page = Page(); page.texts = ["form", "form\nA new window with fields"]; page.adoptScript = [true]
        var base = await page.pageText(), scrolls = 0
        let a = await PageFlow.watch(page, baseline: &base, autoScrolls: &scrolls)
        XCTAssertEqual(a, .newFormFilled)
        let p2 = Page(); p2.texts = ["form", "form\nOpt out of the sale of my data"]
        var b2 = await p2.pageText(); var s2 = 0
        let still = await PageFlow.watch(p2, baseline: &b2, autoScrolls: &s2, domChanged: false)
        XCTAssertEqual(still, .nothing); XCTAssertEqual(p2.scrolls, 0, "the person's own scrolling never moves the page")
        let p3 = Page(); p3.texts = ["form", "form\nOpt out of the sale of my data"]
        var b3 = await p3.pageText(); var s3 = 0
        _ = await PageFlow.watch(p3, baseline: &b3, autoScrolls: &s3, domChanged: true)
        XCTAssertEqual(p3.scrolls, 1); XCTAssertEqual(s3, 1)
        var s4 = 2; var b4 = "form"; p3.texts = ["form", "form\nOpt out of the sale of my data again"]
        _ = await PageFlow.watch(p3, baseline: &b4, autoScrolls: &s4, domChanged: true)
        XCTAssertEqual(p3.scrolls, 1, "never more than twice per site")
    }

    func testAnEmptyPageOrAnUnchangedOneSaysNothing() async {
        let page = Page(); page.texts = ["same", "same", ""]
        var base = await page.pageText(), scrolls = 0
        let a = await PageFlow.watch(page, baseline: &base, autoScrolls: &scrolls)
        let b = await PageFlow.watch(page, baseline: &base, autoScrolls: &scrolls)
        XCTAssertEqual(a, .nothing); XCTAssertEqual(b, .nothing)
    }
}
