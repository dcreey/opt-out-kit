import Foundation
import BackgroundTasks
import UserNotifications
import OptOutKitCore

/// Runs automatic opt-out checks when the app opens and, best effort, in the background.
/// iOS decides when background work actually runs, so the foreground run is the reliable one.
@MainActor
enum CheckScheduler {
    static let taskID = "dev.optoutkit.app.recheck"
    static let scanTaskID = "dev.optoutkit.app.scan"        // daily: scan for listings
    static let optOutTaskID = "dev.optoutkit.app.optout"    // weekly: send opt-out requests

    static func register(model: AppModel) {
        registerAutomation(model: model)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            let work = Task { @MainActor in
                await model.runDueChecks()
                schedule(after: 6 * 3600)
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// iOS decides when these actually run, and a background run may not be able to use the hidden web view; the app also
    /// catches up whenever it is opened (see OptOutKitApp), which is the reliable path.
    static func registerAutomation(model: AppModel) {
        // When iOS ends a scheduled task, a run it started stops after the site in progress and waits for the person ("Carry on?").
        BGTaskScheduler.shared.register(forTaskWithIdentifier: scanTaskID, using: nil) { task in
            let work = Task { @MainActor in await model.runDueAutomation(); task.setTaskCompleted(success: true) }
            task.expirationHandler = { Task { @MainActor in model.scheduledTaskEnded() }; work.cancel() }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: optOutTaskID, using: nil) { task in
            let work = Task { @MainActor in await model.runDueAutomation(); task.setTaskCompleted(success: true) }
            task.expirationHandler = { Task { @MainActor in model.scheduledTaskEnded() }; work.cancel() }
        }
    }

    static func scheduleAutomation(_ settings: AutoSettings) {
        if settings.scanEnabled {
            let request = BGAppRefreshTaskRequest(identifier: scanTaskID)
            request.earliestBeginDate = (settings.lastScan ?? Date()).addingTimeInterval(AutoSettings.scanEvery)
            try? BGTaskScheduler.shared.submit(request)
        }
        if settings.optOutEnabled {
            let request = BGProcessingTaskRequest(identifier: optOutTaskID)
            request.requiresNetworkConnectivity = true
            request.earliestBeginDate = settings.nextOptOutDate() ?? Date().addingTimeInterval(AutoSettings.optOutEvery)
            try? BGTaskScheduler.shared.submit(request)
        }
    }

    /// Generic on purpose: no names or site names on the lock screen.
    static func notifyOptOut(sent: Int, needYou: Int) {
        guard sent + needYou > 0 else { return }
        var parts: [String] = []
        if sent > 0 { parts.append("sent \(sent) opt-out request\(sent == 1 ? "" : "s")") }
        if needYou > 0 { parts.append("\(needYou) site\(needYou == 1 ? " needs" : "s need") you") }
        let content = UNMutableNotificationContent()
        content.title = "Exnay"
        content.body = parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst()
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// A run was cut off by the app leaving the front: ask iOS to give it time again soon. Best effort; opening the app is what reliably resumes it.
    static func scheduleResume() {
        let request = BGProcessingTaskRequest(identifier: optOutTaskID)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Generic on purpose: no site names on the lock screen.
    static func notifyPaused() {
        let content = UNMutableNotificationContent()
        content.title = "Exnay"
        content.body = "Your opt-out run is paused. Open Exnay to carry on where it stopped."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "optout-paused", content: content, trigger: nil))
    }

    static func schedule(after seconds: TimeInterval = 6 * 3600) {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Asked once, when the first opt-out is submitted, so the prompt arrives with a reason.
    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Lock-screen text is generic on purpose: no names or site names.
    static func notify(_ events: [CheckEvent]) {
        guard !events.isEmpty else { return }
        let verified = events.filter { if case .verified = $0 { return true } else { return false } }.count
        let relisted = events.count - verified
        var parts: [String] = []
        if verified > 0 { parts.append("\(verified) opt-out\(verified == 1 ? "" : "s") confirmed") }
        if relisted > 0 { parts.append("\(relisted) listing\(relisted == 1 ? "" : "s") back online") }
        let content = UNMutableNotificationContent()
        content.title = "Exnay"
        content.body = parts.joined(separator: ", ")
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}


/// Keeps an opt-out run that the person started going while they use another app (iOS 26 and later). The system shows its progress as a Live
/// Activity and the person can cancel it there. The run itself is the same one the app always does (see `AppModel.runAutoOptOut`); this only
/// asks iOS for the time. If iOS refuses, or this is an older iOS, the caller falls back to finishing the current site and resuming on reopen.
@available(iOS 26.0, *)
@MainActor
final class ContinuedRun {
    static let identifier = "dev.optoutkit.app.optout.run"
    private static var registered = false
    private static weak var current: ContinuedRun?

    private var task: BGContinuedProcessingTask?
    private var done = 0, total = 0
    private var onExpire: () -> Void = {}
    private var completed = false
    var onGranted: (() -> Void)?
    /// While one site is slow (a page load can take most of a minute), progress still moves a little, so iOS does not take it for a stalled task.
    private var heartbeat: Timer?
    private var lastReport = Date()

    /// True once iOS has accepted the run and handed us its task: only then is it safe to stay running in the background.
    var isGranted: Bool { task != nil && !completed }

    /// Submits the request. False when iOS would not take it (so the caller uses the fallback).
    func start(total: Int, onExpire: @escaping () -> Void) -> Bool {
        self.total = total; self.onExpire = onExpire
        Self.current = self
        if !Self.registered {
            Self.registered = true
            BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: nil) { task in
                guard let task = task as? BGContinuedProcessingTask else { return }
                Task { @MainActor in Self.current?.attach(task) ?? task.setTaskCompleted(success: false) }
            }
        }
        let request = BGContinuedProcessingTaskRequest(identifier: Self.identifier, title: "Opting you out", subtitle: "Starting…")
        request.strategy = .queue
        do { try BGTaskScheduler.shared.submit(request); NSLog("ContinuedRun: submitted"); return true }
        catch { NSLog("ContinuedRun: refused: \(error)"); return false }
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        NSLog("ContinuedRun: granted")
        self.task = task
        onGranted?()
        task.expirationHandler = { [weak self] in
            Task { @MainActor in NSLog("ContinuedRun: expired"); self?.onExpire(); self?.finish(success: false) }
        }
        push()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.push() } }
    }

    func report(done: Int, total: Int) { self.done = done; self.total = total; lastReport = Date(); push() }

    /// Progress in hundredths of a site: each finished site is 100 units, and the site in progress creeps up to 90 while it runs.
    private func push() {
        guard let task, !completed else { return }
        let creep = min(90, Int(Date().timeIntervalSince(lastReport) / 2))
        task.progress.totalUnitCount = Int64(max(total, 1) * 100)
        task.progress.completedUnitCount = Int64(done * 100 + creep)
        task.updateTitle("Opting you out", subtitle: "\(done) of \(total) sites")
    }

    func finish(success: Bool) {
        guard !completed else { return }
        completed = true
        heartbeat?.invalidate(); heartbeat = nil
        task?.setTaskCompleted(success: success)
        if Self.current === self { Self.current = nil }
    }
}
