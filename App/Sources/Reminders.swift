import Foundation
import UserNotifications
import OptOutKitCore

/// Local reminders that bring a person back to opting out (the plan and wording are `Reminders` in the core package). Every reminder is a one-time
/// notification with its own date, and the whole set is replaced each time the app comes to the front or leaves it, so a new opt-out moves them all
/// and none can repeat. See docs/REMINDERS.md.
enum ReminderScheduler {
    private static let firstLaunchKey = "reminders.firstLaunch"

    /// The date the reminders count from when no request has been sent yet.
    private static func firstLaunch(_ defaults: Preferences = AppPreferences.current) -> Date {
        if let d = defaults.object(forKey: firstLaunchKey) as? Date { return d }
        let now = Date(); defaults.set(now, forKey: firstLaunchKey); return now
    }

    static func update(summary: ActivitySummary, target: BrokerCategory?) {
        let plan = Reminders.plan(lastActive: summary.lastDay ?? firstLaunch(), streak: summary.streak, target: target)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            // Permission is asked once, with the first opt-out; until it is given there is nothing to schedule.
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            center.getPendingNotificationRequests { pending in
                center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(Reminders.idPrefix) })
                for r in plan {
                    let content = UNMutableNotificationContent()
                    content.title = r.title
                    content.body = r.body
                    let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: r.fireDate)
                    center.add(UNNotificationRequest(identifier: r.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
                }
            }
        }
    }
}
