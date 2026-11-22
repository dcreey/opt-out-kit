import Foundation
import OptOutKitCore

/// Everything `AppModel` needs from the phone itself: the screen's idle timer, background time, notifications and reminders, the advertising ID, the Keychain, the clipboard,
/// and the web views that fill and send forms. The model asks this and never touches UIKit, UserNotifications or WebKit, so it compiles for the Mac and its tests run there
/// (`Packages/AssistedRunLogic`, `swift test`, no simulator). The app gives it the real one at launch (`IOSPlatform`); until then (and in the Mac tests) it is `HeadlessPlatform`,
/// which does nothing and sends nothing. docs/TESTING.md, "What runs where".
@MainActor
protocol AppPlatform: AnyObject {
    // The screen and the app's time
    func setKeepScreenAwake(_ on: Bool)
    var appIsActive: Bool { get }
    /// Asks for the extra time iOS gives an app that left the front (0: none). `onExpire` is called when it runs out.
    func beginBackgroundTask(_ name: String, onExpire: @escaping @Sendable () -> Void) -> Int
    func endBackgroundTask(_ id: Int)
    /// Posted when the phone's protected data (the Keychain and files) becomes readable after it started.
    var protectedDataAvailableName: Notification.Name? { get }
    func canOpen(_ url: URL) -> Bool
    var canComposeMail: Bool { get }
    func copyToClipboard(_ value: String, forSeconds seconds: TimeInterval)

    // Notifications and reminders
    func requestNotificationPermission()
    func scheduleAutomation(_ settings: AutoSettings)
    func scheduleResume()
    func notifyPaused()
    func notifyOptOut(sent: Int, needYou: Int)
    func notify(_ events: [CheckEvent])
    func updateReminders(summary: ActivitySummary, target: BrokerCategory?)

    /// iOS 26: the run's own background time, shown as a Live Activity. Nil when iOS did not give it (or on an older iOS).
    func startContinuedRun(total: Int, onExpire: @escaping () -> Void) -> ContinuedRunning?

    // The advertising ID
    func advertisingIDIsAsked(by entries: [DirectoryEntry]) -> Bool
    var advertisingIDNotYetAsked: Bool { get }
    func currentAdvertisingID() async -> String?

    // The Keychain key the household is sealed with
    nonisolated func defaultKeys() -> KeyProviding

    // The web views that fill, send and read pages
    func makeSubmitter(person: Person?, advertisingID: String?) -> FormSubmitter
    func makeAssistedDriver(person: Person?, termsPolicy: TermsPolicy?) -> AssistedDriver
    func makeInspector() -> PageInspector
    func makeGuidedPageMaker() -> GuidedPageMaker
    /// The two ways the exposure scan reads a site: plain requests, and (for pages built by script) a hidden web view.
    func makeScanFetchers(termsPolicy: TermsPolicy?) -> (plain: PageFetcher, browser: PageFetcher?)
    func makeTermsPolicy(library: TermsLibrary, approval: TermsApproval?, onAccepted: @escaping @Sendable (ConsentLogEntry) -> Void) -> TermsPolicy
    /// A submitter that sends nothing and says every other site went through (the demo run of the UI tests; debug builds only).
    func makeDemoSubmitter() -> FormSubmitter
    /// True when sending is done by something that needs no politeness pause between sites (a fixture or a fake).
    var sendsWithoutPause: Bool { get }
}

/// What iOS 26's continued processing task offers the model.
@MainActor
protocol ContinuedRunning: AnyObject {
    var isGranted: Bool { get }
    func report(done: Int, total: Int)
    func finish(success: Bool)
}

/// The platform the model uses unless it is given another: the app sets it at launch (`IOSPlatform`).
@MainActor
enum AppPlatformHolder {
    nonisolated(unsafe) static var current: AppPlatform = HeadlessPlatform()
}

/// A platform with no phone behind it: nothing is scheduled, notified or sent. What the Mac tests run the model on, and what a unit test gets unless the app launched.
@MainActor
final class HeadlessPlatform: AppPlatform {
    var keepScreenAwake = false
    var appIsActive = true
    private var nextTask = 1
    private(set) var clipboard: [String] = []
    private(set) var notifications: [String] = []
    nonisolated init() {}

    var protectedDataAvailableName: Notification.Name? { nil }
    var canComposeMail: Bool { false }
    var advertisingIDNotYetAsked: Bool { false }
    var sendsWithoutPause: Bool { true }

    func setKeepScreenAwake(_ on: Bool) { keepScreenAwake = on }
    func beginBackgroundTask(_ name: String, onExpire: @escaping @Sendable () -> Void) -> Int { defer { nextTask += 1 }; return nextTask }
    func endBackgroundTask(_ id: Int) {}
    func canOpen(_ url: URL) -> Bool { false }
    func copyToClipboard(_ value: String, forSeconds seconds: TimeInterval) { clipboard.append(value) }
    func requestNotificationPermission() { notifications.append("permission") }
    func scheduleAutomation(_ settings: AutoSettings) {}
    func scheduleResume() { notifications.append("resume") }
    func notifyPaused() { notifications.append("paused") }
    func notifyOptOut(sent: Int, needYou: Int) { notifications.append("optout \(sent) \(needYou)") }
    func notify(_ events: [CheckEvent]) { notifications.append("events \(events.count)") }
    func updateReminders(summary: ActivitySummary, target: BrokerCategory?) {}
    func startContinuedRun(total: Int, onExpire: @escaping () -> Void) -> ContinuedRunning? { nil }
    func advertisingIDIsAsked(by entries: [DirectoryEntry]) -> Bool { false }
    func currentAdvertisingID() async -> String? { nil }
    nonisolated func defaultKeys() -> KeyProviding { FixedKey() }
    func makeSubmitter(person: Person?, advertisingID: String?) -> FormSubmitter { NoWebSubmitter() }
    func makeAssistedDriver(person: Person?, termsPolicy: TermsPolicy?) -> AssistedDriver { NoWebDriver() }
    func makeInspector() -> PageInspector { NoWebInspector() }
    func makeGuidedPageMaker() -> GuidedPageMaker { NoWebGuidedPageMaker() }
    func makeDemoSubmitter() -> FormSubmitter { NoWebSubmitter() }
    func makeScanFetchers(termsPolicy: TermsPolicy?) -> (plain: PageFetcher, browser: PageFetcher?) { (NoWebFetcher(), nil) }
    func makeTermsPolicy(library: TermsLibrary, approval: TermsApproval?, onAccepted: @escaping @Sendable (ConsentLogEntry) -> Void) -> TermsPolicy {
        LibraryTermsPolicy(library: library, approval: approval, fetchDocument: { _ in nil }, onAccepted: onAccepted)
    }
}

private struct NoWebSubmitter: FormSubmitter {
    func submit(_ form: OptOutForm, plan: FillPlan, dryRun: Bool) async -> SubmitOutcome { .failed("no web view here") }
}
private struct NoWebFetcher: PageFetcher {
    func fetch(_ url: URL) async throws -> FetchedPage { throw URLError(.unsupportedURL) }
}
private struct NoWebInspector: PageInspector {
    func snapshot(_ url: URL) async -> PageSnapshot? { nil }
}
@MainActor
private struct NoWebGuidedPageMaker: GuidedPageMaker { func make() -> GuidedPage { NoWebGuidedPage() } }
/// A guided page with no browser behind it: loads nothing, shows nothing, sends nothing.
@MainActor
private final class NoWebGuidedPage: GuidedPage {
    var webView: AnyObject? { nil }
    func load(_ url: URL) async {}
    func currentURL() -> URL? { nil }
    func visibleText() async -> String { "" }
    func fill(_ values: [FieldValue]) async -> Int { 0 }
    func blockers() async -> [AssistedBlocker] { [] }
    func send(_ values: [FieldValue]) async -> SubmitOutcome { .failed("no web view here") }
    func close() {}
}
private struct NoWebDriver: AssistedDriver {
    func prepare(_ form: OptOutForm, plan: FillPlan) async -> AssistedPage? { nil }
    func prepare(_ form: OptOutForm, plan: FillPlan, listingURL: URL?) async -> AssistedPage? { nil }
    func failureReason(for form: OptOutForm) -> String? { nil }
    func discoveredEmail(for form: OptOutForm) -> String? { nil }
    func openSearch(_ url: URL) async -> SearchPage? { nil }
    func prepareHeld(_ form: OptOutForm, plan: FillPlan, fillNothing: Bool) async -> AssistedPage? { nil }
}
