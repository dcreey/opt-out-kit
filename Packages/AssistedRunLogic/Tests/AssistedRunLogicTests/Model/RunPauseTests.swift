import XCTest
import OptOutKitCore
@testable import AssistedRunLogic

/// A run that stops before finishing (iOS takes back its background time, the app leaves the screen, the app is closed) is never carried on by itself: when the
/// app is next on screen the person is asked "Carry on with the opt-out run?" (decided 2026-11-24). And everything that happened is in the run log, which the
/// run export carries, so an export says why a run stopped and where each site was.
@MainActor
final class RunPauseTests: XCTestCase {
    private struct Slow: FormSubmitter {
        func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome {
            try? await Task.sleep(nanoseconds: 50_000_000); return .submitted(awaitingEmail: false)
        }
    }

    private let key = FixedKey()
    private func model(_ phone: HeadlessPlatform, url: URL = FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed")) -> AppModel {
        AppModel(store: HouseholdStore(url: url, keys: key), defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!, platform: phone)
    }

    private func ready(_ m: AppModel) -> Person {
        var me = m.people.first { $0.relationship == .me }!
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"
        me.addresses = [Address(street: "1 Main St", city: "Somewhere", state: "IL", zip: "62701")]
        m.update(me); m.setContactEmail("pat@example.com")
        m.setAuto(scan: false, optOut: true)
        return me
    }

    private func events(_ m: AppModel) -> [String] { m.currentRunLog().entries.map(\.event) }

    /// iOS takes back the run's time while the person is away: the run pauses after the site in progress and says why. It does not start again by itself, not
    /// even when the due-check comes round; back on screen, the person is asked, and "Not now" leaves it waiting. "Carry on" carries it on. The log has it all.
    func testAPausedRunAsksBeforeCarryingOnAndTheLogSaysWhy() async throws {
        let phone = HeadlessPlatform()
        let m = model(phone)
        let me = ready(m)
        let run = Task { await m.runAutoOptOut(for: me, submitter: Slow()) }
        var waited = 0
        while (m.autoProgress?.done ?? 0) < 2 && waited < 300 { try await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
        phone.appIsActive = false
        m.appDidEnterBackground()
        m.continuedRunExpired(appActive: false)
        await run.value
        let done = (m.optOutRun[me.id] ?? []).count
        XCTAssertEqual(m.autoSettings.optOutResumePending, true, "the run stopped part-way")
        XCTAssertEqual(m.autoSettings.pauseReason, AppModel.pausedBackgroundTimeEnded, "and says why")
        XCTAssertNotNil(m.autoSettings.pausedAt)

        await m.runDueAutomation()
        XCTAssertEqual((m.optOutRun[me.id] ?? []).count, done, "the due-check does not carry it on by itself")
        XCTAssertFalse(m.askToResume, "nobody is asked while the app is away")

        phone.appIsActive = true
        m.appDidBecomeActive()
        XCTAssertTrue(m.askToResume, "back on screen, the person is asked")
        XCTAssertTrue(m.resumeQuestion.contains("background"), m.resumeQuestion)
        m.declineResume()
        XCTAssertFalse(m.askToResume)
        XCTAssertEqual(m.autoSettings.optOutResumePending, true, "Not now: the run still waits")
        XCTAssertNil(m.autoBusy)

        let log = m.currentRunLog().entries
        for e in [RunLog.Event.runStarted, .background, .backgroundTimeEnded, .paused, .site, .runEnded, .resumeAsked, .resumeDeclined] {
            XCTAssertTrue(log.contains { $0.event == e.rawValue }, "the log has \(e.rawValue): \(log.map(\.event))")
        }
        XCTAssertEqual(log.first { $0.event == RunLog.Event.backgroundTimeEnded.rawValue }?.appActive, false, "with whether the app was on screen")
        XCTAssertNotNil(log.first { $0.event == RunLog.Event.backgroundTimeEnded.rawValue }?.awayFor, "and how long it had been away")
        XCTAssertEqual(log.filter { $0.event == RunLog.Event.site.rawValue }.count, done, "one entry per site's result")
        XCTAssertEqual(log.last { $0.event == RunLog.Event.paused.rawValue }?.detail, AppModel.pausedBackgroundTimeEnded)

        // The export carries the log and the reason.
        let files = m.runExportFiles(for: me, rows: m.activityRows(for: me))
        let json = try XCTUnwrap(String(data: files[0].data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"log\""), "the export has the run log")
        XCTAssertTrue(json.contains(AppModel.pausedBackgroundTimeEnded), "and why the run paused")
        XCTAssertTrue(json.contains("\"background-time-ended\""))

        // Asked again on the next return; Carry on carries it on, and the pause is cleared.
        phone.appIsActive = false; m.appDidEnterBackground(); phone.appIsActive = true
        m.appDidBecomeActive()
        XCTAssertTrue(m.askToResume)
        m.resumeRun()
        waited = 0
        while m.autoBusy == nil && waited < 100 { try await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
        while m.autoBusy != nil && waited < 3000 { try await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
        XCTAssertGreaterThan((m.optOutRun[me.id] ?? []).count, 0)
        XCTAssertNil(m.autoSettings.pauseReason, "carried on: no longer paused")
        XCTAssertTrue(events(m).contains(RunLog.Event.resumeAccepted.rawValue))
        XCTAssertTrue(m.currentRunLog().entries.contains { $0.event == RunLog.Event.runStarted.rawValue && ($0.detail ?? "").contains("carried on") }, "the log says it was carried on")
    }

    /// A run cut off by the app closing (nothing wrote a pause): opened again, the app asks, and the log says the run was found cut off. The log is kept in the
    /// database, sealed, so it is there after the app opens again.
    func testARunCutOffByAClosedAppAsksWhenTheAppOpensAgain() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed")
        let first = model(HeadlessPlatform(), url: url)
        let me = ready(first)
        let run = Task { await first.runAutoOptOut(for: me, submitter: Slow()) }
        var waited = 0
        while (first.autoProgress?.done ?? 0) < 2 && waited < 300 { try await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
        try await Task.sleep(nanoseconds: 300_000_000)          // the log is written off the main thread
        // The app is closed here: what is saved says a run is under way, and nothing wrote a pause.
        let again = model(HeadlessPlatform(), url: url)
        first.stopAutoOptOut(); await run.value
        XCTAssertEqual(again.autoSettings.optOutResumePending, true)
        XCTAssertNil(again.autoSettings.pausedAt)
        XCTAssertFalse(again.askToResume)
        again.appDidBecomeActive()
        XCTAssertTrue(again.askToResume, "the person is asked")
        XCTAssertEqual(again.autoSettings.pauseReason, AppModel.pausedAppClosed)
        XCTAssertTrue(again.resumeQuestion.contains("closed"), again.resumeQuestion)
        XCTAssertTrue(events(again).contains(RunLog.Event.runStarted.rawValue), "the log from before the close is still there")
        XCTAssertTrue(events(again).contains(RunLog.Event.site.rawValue))
        XCTAssertTrue(events(again).contains(RunLog.Event.foundCutOff.rawValue))
        // A run the person stopped is not asked about.
        again.declineResume()
        let more = Task { await again.runAutoOptOut(for: again.people.first { $0.relationship == .me }!, submitter: Slow()) }
        waited = 0
        while (again.autoProgress?.done ?? 0) < 1 && waited < 300 { try await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
        again.stopAutoOptOut(); await more.value
        again.appDidBecomeActive()
        XCTAssertFalse(again.askToResume, "stopped by the person: not asked")
    }

    /// Every kind of stop the person did not ask for ends in the question. iOS ending a scheduled background task mid-run: the run stops after the site in
    /// progress, says why, and (the app being on screen) asks at once rather than at the next return. A memory warning during a run is in the log.
    func testEveryStopThePersonDidNotAskForEndsInTheQuestion() async throws {
        let phone = HeadlessPlatform()
        let m = model(phone)
        let me = ready(m)
        let run = Task { await m.runAutoOptOut(for: me, submitter: Slow()) }
        var waited = 0
        while (m.autoProgress?.done ?? 0) < 2 && waited < 300 { try await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
        m.memoryWarning()
        m.scheduledTaskEnded()
        await run.value
        XCTAssertEqual(m.autoSettings.optOutResumePending, true)
        XCTAssertEqual(m.autoSettings.pauseReason, AppModel.pausedScheduledTaskEnded)
        XCTAssertTrue(m.askToResume, "on screen when it stopped: asked at once")
        XCTAssertTrue(m.resumeQuestion.contains("background"), m.resumeQuestion)
        for e in [RunLog.Event.memoryWarning, .scheduledTaskEnded, .paused, .resumeAsked] {
            XCTAssertTrue(events(m).contains(e.rawValue), "\(e.rawValue): \(events(m))")
        }
        XCTAssertEqual(phone.notifications.filter { $0 == "paused" }.count, 1, "and the paused notification went out")
        // Carry on runs it, whatever else the due-check would wait for.
        m.resumeRun()
        waited = 0
        while m.autoBusy == nil && waited < 100 { try await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
        XCTAssertEqual(m.autoBusy, "optout", "Carry on started the run")
        m.stopAutoOptOut()
        while m.autoBusy != nil && waited < 3000 { try await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
        XCTAssertFalse(m.askToResume, "stopped by the person: not asked")
    }

    /// Each site blocked by a human check says so first, wherever its line is shown: in the sites that need the person, and in the ones the run leaves to them.
    /// A site sent twice without a confirmation and a field no profile can fill say what they are too, not "Waits for the next full re-test".
    func testEverySiteBlockedByAHumanCheckSaysSo() {
        let now = Date()
        for d in ["a reCAPTCHA checkbox", "an hCaptcha", "a Cloudflare check", "a code to type"] {
            let item = AppModel.ReviewItem(id: "x", domain: "x.com", outcome: "challenged", detail: d, date: now, hasScreenshot: false)
            XCTAssertTrue(item.label.hasPrefix("Blocked by a human check"), item.label)
            XCTAssertTrue(item.label.contains(d), item.label)
            XCTAssertTrue(AppModel.leftForPersonLine(OptOutAttempt(date: now, outcome: "challenged", detail: d)).hasPrefix("Blocked by a human check"))
        }
        XCTAssertEqual(AppModel.humanCheckLine("a human check"), "Blocked by a human check: only you can clear it")
        let cert = AppModel.ReviewItem(id: "x", domain: "x.com", outcome: "challenged", detail: "a certification box that you must tick yourself", date: now, hasScreenshot: false)
        XCTAssertEqual(cert.label, "Stopped: a certification box that you must tick yourself", "a certification box is not a human check")
        XCTAssertEqual(AppModel.leftForPersonLine(OptOutAttempt(date: now, outcome: "failed", detail: AutoOptOut.sentUnconfirmed)), "Sent twice without a confirmation: check it yourself")
        let field = "This form asks for something we do not have (\"Social Media Platform\")."
        XCTAssertEqual(AppModel.leftForPersonLine(OptOutAttempt(date: now, outcome: "failed", detail: field)), "Needs you: " + field)
        XCTAssertEqual(AppModel.leftForPersonLine(nil), "Waits for the next full re-test")
    }

    /// What a page says after sending when it wants a human check ("Please complete the verification challenge", as the Superset forms; "Please complete the
    /// security verification", jmr-media.com; "Please complete the security check.", instantly.ai) is read as a human check, never as an error or no answer.
    func testAPageAskingForAHumanCheckAfterSendingIsAHumanCheck() {
        for text in ["Please complete the verification challenge", "Please correct the following:\nPlease complete the security verification",
                     "Please complete the security check.", "Please verify you are human", "Captcha is required"] {
            XCTAssertEqual(FormRun.classifyConfirmed(text), .challenged(FormRun.humanCheckAfterSending), text)
        }
        XCTAssertTrue(AutoOptOut.isHumanCheck(outcome: "challenged", detail: FormRun.humanCheckAfterSending))
        for text in ["Success!", "Thank you, your request was received", "No data was found, try other criteria..."] {
            XCTAssertNotEqual(FormRun.classifyConfirmed(text), .challenged(FormRun.humanCheckAfterSending), text)
        }
    }
}
