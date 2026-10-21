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
        BGTaskScheduler.shared.register(forTaskWithIdentifier: scanTaskID, using: nil) { task in
            let work = Task { @MainActor in await model.runDueAutomation(); task.setTaskCompleted(success: true) }
            task.expirationHandler = { work.cancel() }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: optOutTaskID, using: nil) { task in
            let work = Task { @MainActor in await model.runDueAutomation(); task.setTaskCompleted(success: true) }
            task.expirationHandler = { work.cancel() }
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
            request.earliestBeginDate = (settings.lastOptOut ?? Date()).addingTimeInterval(AutoSettings.optOutEvery)
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
        content.title = "Opt-Out Kit"
        content.body = parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst()
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
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
