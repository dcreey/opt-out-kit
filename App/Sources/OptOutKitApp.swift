import SwiftUI
import MessageUI
import WebKit
import OptOutKitCore

@main
struct OptOutKitApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppPlatformHolder.current = IOSPlatform()          // before the model is made
        Keyboard.install()
        MainThreadWatch.startIfAsked()
        #if DEBUG
        // UI tests run without animations: every screen change otherwise waits for its animation, and the tests are slower and flakier for it.
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-uitest") }) || ProcessInfo.processInfo.environment["UITEST_NO_ANIMATIONS"] == "1" {
            UIView.setAnimationsEnabled(false)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
                .overlay(alignment: .topLeading) { if ProcessInfo.processInfo.arguments.contains("-uitest-watch-main") { MainStallsLabel() } }
                .onOpenURL { if let link = AppModel.sharedLink(in: $0) { model.incomingLink = link } }
                .task { CheckScheduler.register(model: model) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.appDidEnterBackground() }
            if phase == .active { model.appDidBecomeActive() }
            guard phase == .active, !ProcessInfo.processInfo.arguments.contains("-uitest-reset") else { return }
            Task { await model.runDueChecks(); await model.runDueAutomation() }
            CheckScheduler.schedule()
        }
    }
}


#if DEBUG
/// UI tests use this so they never touch the real internet: every site "lists" anyone whose name contains Pat.
struct FakeScanFetcher: PageFetcher {
    func fetch(_ url: URL) async throws -> FetchedPage {
        FetchedPage(status: 200, text: "directory search results Pat Example no result sorry")
    }
}
#endif


#if DEBUG
/// UI tests use this so they never contact a real site: every other site "sends", the rest are stopped by a human check.
struct FakeSubmitter: FormSubmitter {
    func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome {
        if dryRun { return .filledNotSubmitted }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-fake-submit-delay"), args.indices.contains(i + 1), let secs = Double(args[i + 1]) { try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000)) }
        return form.page.absoluteString.count % 2 == 0 ? .submitted(awaitingEmail: true) : .challenged("a human check")
    }

    /// A drawn stand-in for the page, so the review screens have something to show without loading a site.
    func submitCapturing(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitEvidence {
        let outcome = await submit(form, plan: plan, dryRun: dryRun)
        let text = "\(form.page.host ?? "site")\nFake page after sending"
        let image = await MainActor.run {
            UIGraphicsImageRenderer(size: CGSize(width: 390, height: 800)).image { ctx in
                UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 390, height: 800))
                (text as NSString).draw(in: CGRect(x: 20, y: 300, width: 350, height: 120), withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
            }
        }
        return SubmitEvidence(outcome: outcome, screenshot: image.jpegData(compressionQuality: 0.5))
    }
}
#endif
