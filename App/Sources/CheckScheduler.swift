import Foundation
import BackgroundTasks
import UserNotifications
import OptOutKitCore

/// Runs automatic opt-out checks when the app opens and, best effort, in the background.
/// iOS decides when background work actually runs, so the foreground run is the reliable one.
@MainActor
enum CheckScheduler {
    static let taskID = "dev.optoutkit.app.recheck"

    static func register(model: AppModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            let work = Task { @MainActor in
                await model.runDueChecks()
                schedule(after: 6 * 3600)
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
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
        content.title = "Opt-Out Kit"
        content.body = parts.joined(separator: ", ")
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
