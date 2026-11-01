import XCTest
import OptOutKitCore
@testable import AssistedRunLogic

/// The email step of the assisted run, end to end without a screen: a runner on a site that failed (offer dialog) or that has no form (no-form
/// screen), the handoff the screen displays, and the person's taps. These ran into "no confirmation after Send an email" and "Skip does nothing".
@MainActor
final class EmailHandoffTests: XCTestCase {
    private final class NoPageDriver: AssistedDriver {
        let noForm: Bool
        init(noForm: Bool) { self.noForm = noForm }
        func prepare(_ form: OptOutForm, plan: FillPlan) async -> AssistedPage? { nil }
        func failureReason(for form: OptOutForm) -> String? { noForm ? "noform" : nil }
    }
    private let link = URL(string: "mailto:privacy@x.example")!

    private struct Rig {
        let runner: AssistedRunner, handoff: EmailHandoff, run: Task<Void, Never>
        let reported: Box, marked: Box, launched: Box
    }
    private final class Box { var results: [AutoOptOutResult] = []; var count = 0 }

    private func start(noForm: Bool, email: String? = "privacy@x.example") async -> Rig {
        let form = OptOutForm(page: URL(string: "https://x.example/optout")!, method: "post", action: nil, fields: [FormField(type: "email", name: "email", label: "Email")], hops: 1)
        let entry = DirectoryEntry(id: "x_example", domain: "x.example", name: "x.example", bucket: "direct", tier: .B, automation: .guided, optOutForm: form, contactEmail: email)
        let reported = Box(), marked = Box(), launched = Box()
        let r = AssistedRunner(items: [AssistedRunner.Item(entry: entry, form: form, plan: FillPlan(values: [], verdict: .ready))], driver: NoPageDriver(noForm: noForm)) { _, res in reported.results.append(res) }
        r.pollInterval = 0.01; r.pauseAfterSent = 0
        let h = EmailHandoff(runner: r)
        h.markEmailed = { _ in marked.count += 1 }
        let run = Task { @MainActor in await r.run() }
        for _ in 0..<400 where r.emailOffer == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotNil(r.emailOffer, "the email is offered")
        return Rig(runner: r, handoff: h, run: run, reported: reported, marked: marked, launched: launched)
    }
    private func join(_ rig: Rig) async {
        for _ in 0..<600 where !rig.runner.finished { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(rig.runner.finished, "the run did not finish")
        if rig.runner.finished { await rig.run.value } else { rig.run.cancel() }
    }
    private func batch(_ rig: Rig) -> EmailBatch { EmailBatch.single(entries: [rig.runner.emailOffer!]).first! }
    private func openExternal(_ rig: Rig) {
        rig.handoff.open(batch(rig), composesInApp: false, url: link) { _ in rig.launched.count += 1 }
    }

    // MARK: another mail app: it cannot tell us, so the question is asked, and nothing covers it

    func testOtherMailAppAsksDidYouSendItImmediatelyOnTheNoFormScreen() async {
        let rig = await start(noForm: true)
        openExternal(rig)
        XCTAssertEqual(rig.launched.count, 1)
        XCTAssertNotNil(rig.handoff.confirming, "the question is waiting for the person's return")
        rig.handoff.answer(sent: true)
        await join(rig)
        XCTAssertEqual(rig.marked.count, 1); XCTAssertEqual(rig.reported.results.last, .emailed); XCTAssertTrue(rig.runner.finished)
    }

    func testOtherMailAppAsksDidYouSendItAfterAFailedSiteAndTheOfferDialogStaysAway() async {
        let rig = await start(noForm: false)
        XCTAssertFalse(rig.handoff.active)
        openExternal(rig)
        XCTAssertNotNil(rig.handoff.confirming)
        XCTAssertTrue(rig.handoff.active, "the screen hides the offer dialog while the question is up")
        rig.handoff.answer(sent: true)
        await join(rig)
        XCTAssertEqual(rig.reported.results.last, .emailed); XCTAssertEqual(rig.marked.count, 1)
    }

    func testNoToDidYouSendItSavesNothingAndKeepsTheNoFormScreen() async {
        let rig = await start(noForm: true)
        openExternal(rig)
        rig.handoff.answer(sent: false)
        XCTAssertEqual(rig.marked.count, 0); XCTAssertFalse(rig.runner.finished)
        XCTAssertNotNil(rig.runner.emailOffer, "still waiting for the person")
        rig.runner.skip(); await join(rig)
    }

    func testNoAfterAFailedSiteMovesOn() async {
        let rig = await start(noForm: false)
        openExternal(rig)
        rig.handoff.answer(sent: false)
        await join(rig)
        XCTAssertEqual(rig.marked.count, 0); XCTAssertTrue(rig.runner.finished)
    }

    func testNoLinkToOpenDoesNotLeaveTheOfferStuck() async {
        let rig = await start(noForm: false)
        rig.handoff.open(batch(rig), composesInApp: false, url: nil) { _ in XCTFail("nothing to open") }
        await join(rig)
        XCTAssertTrue(rig.runner.finished)
    }

    // MARK: in-app Mail composer

    func testSendingInTheComposerFinishesTheSite() async {
        let rig = await start(noForm: true)
        let b = batch(rig)
        rig.handoff.open(b, composesInApp: true, url: nil) { _ in }
        XCTAssertNotNil(rig.handoff.composing)
        rig.handoff.composing = nil                       // the sheet clears its binding before it reports
        rig.handoff.composeFinished(b, sent: true)
        await join(rig)
        XCTAssertEqual(rig.marked.count, 1); XCTAssertEqual(rig.reported.results.last, .emailed)
    }

    func testCancellingTheComposerMarksNothing() async {
        let rig = await start(noForm: true)
        let b = batch(rig)
        rig.handoff.open(b, composesInApp: true, url: nil) { _ in }
        rig.handoff.composeFinished(b, sent: false)
        XCTAssertEqual(rig.marked.count, 0); XCTAssertFalse(rig.runner.finished)
        rig.runner.skip(); await join(rig)
    }

    // MARK: skip

    func testSkipOnTheNoFormScreenMovesOn() async {
        let rig = await start(noForm: true)
        rig.runner.skip(); await join(rig)
        XCTAssertTrue(rig.runner.finished); XCTAssertEqual(rig.marked.count, 0)
    }

    func testSkipWhileTheEmailOfferIsUpMovesOn() async {
        let rig = await start(noForm: false)
        rig.runner.skip()
        await join(rig)
        XCTAssertTrue(rig.runner.finished, "Skip this site answers the offer instead of leaving the run waiting")
        XCTAssertNil(rig.runner.emailOffer)
    }
}
