import SwiftUI
import UIKit
import MessageUI
import OptOutKitCore

/// The phone behind `AppModel` (`AppPlatform`): the screen's idle timer, background time, notifications and reminders, the advertising ID, the Keychain, the clipboard and
/// the web views. The Mac tests run the model on `HeadlessPlatform` instead.
@MainActor
final class IOSPlatform: AppPlatform {
    func setKeepScreenAwake(_ on: Bool) { UIApplication.shared.isIdleTimerDisabled = on }
    var appIsActive: Bool { UIApplication.shared.applicationState == .active }
    func beginBackgroundTask(_ name: String, onExpire: @escaping @Sendable () -> Void) -> Int {
        UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: onExpire).rawValue
    }
    func endBackgroundTask(_ id: Int) { UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id)) }
    var protectedDataAvailableName: Notification.Name? { UIApplication.protectedDataDidBecomeAvailableNotification }
    func canOpen(_ url: URL) -> Bool { UIApplication.shared.canOpenURL(url) }
    var canComposeMail: Bool { MFMailComposeViewController.canSendMail() }
    func copyToClipboard(_ value: String, forSeconds seconds: TimeInterval) {
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: value]], options: [.expirationDate: Date().addingTimeInterval(seconds)])
    }

    func requestNotificationPermission() { CheckScheduler.requestNotificationPermission() }
    func scheduleAutomation(_ settings: AutoSettings) { CheckScheduler.scheduleAutomation(settings) }
    func scheduleResume() { CheckScheduler.scheduleResume() }
    func notifyPaused() { CheckScheduler.notifyPaused() }
    func notifyOptOut(sent: Int, needYou: Int) { CheckScheduler.notifyOptOut(sent: sent, needYou: needYou) }
    func notify(_ events: [CheckEvent]) { CheckScheduler.notify(events) }
    func updateReminders(summary: ActivitySummary, target: BrokerCategory?) { ReminderScheduler.update(summary: summary, target: target) }

    func startContinuedRun(total: Int, onExpire: @escaping () -> Void) -> ContinuedRunning? {
        guard #available(iOS 26.0, *) else { return nil }
        let run = ContinuedRun()
        return run.start(total: total, onExpire: onExpire) ? run : nil
    }

    func advertisingIDIsAsked(by entries: [DirectoryEntry]) -> Bool { AdvertisingID.isAsked(by: entries) }
    var advertisingIDNotYetAsked: Bool { AdvertisingID.status == .notDetermined }
    func currentAdvertisingID() async -> String? { await AdvertisingID.current() }

    nonisolated func defaultKeys() -> KeyProviding { KeychainKey() }

    func makeSubmitter(person: Person?, advertisingID: String?) -> FormSubmitter {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-fake-submit") { return FakeSubmitter() }
        #endif
        return WebFormSubmitter(person: person, advertisingID: advertisingID)
    }
    func makeAssistedDriver(person: Person?, termsPolicy: TermsPolicy?) -> AssistedDriver { WebAssistedDriver(person: person, advertisingID: nil, termsPolicy: termsPolicy) }
    func makeInspector() -> PageInspector { WebPageInspector() }
    func makeGuidedPageMaker() -> GuidedPageMaker { WebGuidedPageMaker() }
    func makeScanFetchers(termsPolicy: TermsPolicy?) -> (plain: PageFetcher, browser: PageFetcher?) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uitest-fake-scan") { return (FakeScanFetcher(), nil) }
        #endif
        return (URLSessionFetcher(), WebViewFetcher(termsPolicy: termsPolicy))
    }
    func makeTermsPolicy(library: TermsLibrary, approval: TermsApproval?, onAccepted: @escaping @Sendable (ConsentLogEntry) -> Void) -> TermsPolicy {
        LibraryTermsPolicy(library: library, approval: approval, fetchDocument: { link in
            // No termsPolicy here: a terms page that shows its own prompt is never accepted.
            try? await WebViewFetcher(maxWait: 8).fetch(link).text
        }, onAccepted: onAccepted)
    }
    func makeDemoSubmitter() -> FormSubmitter {
        #if DEBUG
        return FakeSubmitter()
        #else
        return WebFormSubmitter(person: nil, advertisingID: nil)
        #endif
    }
    var sendsWithoutPause: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uitest-fake-submit") || Fixtures.active
        #else
        false
        #endif
    }
}

@available(iOS 26.0, *)
extension ContinuedRun: ContinuedRunning {}
