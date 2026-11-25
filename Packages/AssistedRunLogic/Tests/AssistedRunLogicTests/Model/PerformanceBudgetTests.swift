import XCTest
import OptOutKitCore
@testable import AssistedRunLogic

/// How quick the screens stay with a phone's history (docs/TESTING.md, "Performance"). On 2026-11-24 the app stalled every few seconds during a run: the Queue
/// tab worked the semi-automated queue out three times each time it was drawn, some 200 ms apiece with about 830 sites of history, and a run redraws after
/// every site. What the screens cost depends on how much the app holds, not on how many sites a run sends, so this holds the whole catalog with months of
/// history (`seedHistoryForTesting`) and sends to five sites only.
///
/// Times, so the budgets are generous: several times what a Mac's debug build takes now, far under what the stall took. Exact counts of the work behind them
/// are in `ResumeAppTests.testTheQueueTabWorksTheQueueOutOncePerPlanAndKeepsItThroughARun` and `VerifyTaskTests.testTheQueueLooksAtEachFormOnceForATypedCode`.
@MainActor
final class PerformanceBudgetTests: XCTestCase {
    /// What one redraw during a run asks of the model: the Queue tab, the Sites tab and the automatic opt-out page.
    static let redrawBudget: TimeInterval = 0.25
    /// The first redraw after a run, which rebuilds the plan once.
    static let afterRunBudget: TimeInterval = 1.0

    private struct QuickSender: FormSubmitter {
        func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome {
            try? await Task.sleep(nanoseconds: 30_000_000); return .submitted(awaitingEmail: false)
        }
    }

    private func redraw(_ m: AppModel, _ me: Person) -> TimeInterval {
        let start = Date()
        _ = m.dailyGoals; _ = m.remainingKinds; _ = m.verifyRemaining; _ = m.activitySummary; _ = m.pendingFollowUps          // the Queue tab
        _ = m.siteRows()                                                                                                   // the Sites tab
        _ = m.activityInputs(for: me); _ = m.runDatesLine                                                                   // the automatic page
        return Date().timeIntervalSince(start)
    }

    func testTheScreensStayQuickDuringARunWithAPhonesHistory() async throws {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        var me = try XCTUnwrap(m.selectedPerson)
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"; me.emails = ["pat@example.com"]
        me.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")]
        m.update(me); m.setContactEmail("pat@example.com")
        m.seedHistoryForTesting()
        XCTAssertGreaterThan(m.directory.count, 500, "the catalog the app ships")
        XCTAssertGreaterThan(m.progress.optOutAttempts.values.map(\.count).reduce(0, +), 5000, "with months of history")
        _ = redraw(m, me)          // the first draw builds the plan and the forms' fill plans

        // A run, stopped after five sites, with the screens redrawn throughout as they are on the phone.
        let run = Task { await m.runAutoOptOut(for: me, submitter: QuickSender()) }
        var times: [TimeInterval] = [], waited = 0
        while (m.autoProgress?.done ?? 0) < 5 && waited < 1500 {
            if m.autoBusy == "optout" { times.append(redraw(m, me)) }
            try await Task.sleep(nanoseconds: 20_000_000); waited += 1
        }
        m.stopAutoOptOut(); await run.value
        XCTAssertGreaterThanOrEqual(times.count, 5, "redrawn during the run")
        let sorted = times.sorted(), median = sorted[sorted.count / 2], worst = sorted.last ?? 0
        let afterRun = redraw(m, me)
        let pageStart = Date(); _ = m.allRunsRows(for: me); let allRunsPage = Date().timeIntervalSince(pageStart)
        let report = String(format: "redraws during the run: %d, median %.0f ms, worst %.0f ms; first after the run %.0f ms; every site, all runs %.0f ms", times.count, median * 1000, worst * 1000, afterRun * 1000, allRunsPage * 1000)
        print("PerformanceBudget: " + report)
        add(XCTAttachment(string: report))
        XCTAssertLessThan(median, Self.redrawBudget, "a redraw during a run is too slow: \(report)")
        XCTAssertLessThan(afterRun, Self.afterRunBudget, "the redraw after a run is too slow: \(report)")
        XCTAssertLessThan(allRunsPage, Self.afterRunBudget, "opening \"Every site, all runs\" is too slow: \(report)")
    }
}
