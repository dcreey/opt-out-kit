import Foundation

/// Which nudge a reminder is: the day after the last opt-out ("keep your streak"), then three days, a week and a month of silence, then every month.
public enum ReminderStage: String, Sendable { case streak, threeDays, week, month }

public struct PlannedReminder: Equatable, Sendable {
    public var id: String
    public var stage: ReminderStage
    public var fireDate: Date
    public var title: String
    public var body: String
}

/// The reminders that nudge a person back to opting out. Each one has its own fixed date counted from the last day a request was sent, so it fires
/// at most once: there is no repeating trigger, and a later request moves every date forward (the cycle starts again). Dates already past are dropped,
/// never fired late.
public enum Reminders {
    /// Local time of day a reminder arrives: the morning, between 08:01 and 08:15. The minute is spread by a fixed function of the reminder and its day, so it
    /// differs from one reminder to the next but does not change when the set is replanned (every launch and every return to the app).
    public static let hour = 8
    public static let minutes = 1...15
    static func minute(id: String, on date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        var seed = (c.year ?? 0) &* 372 &+ (c.month ?? 0) &* 31 &+ (c.day ?? 0)
        for u in id.unicodeScalars { seed = seed &* 31 &+ Int(u.value) }
        return minutes.lowerBound + abs(seed % minutes.count)
    }
    public static let idPrefix = "reminder-"
    /// Days after the last request: a streak nudge, then three days, a week and a month; after that one every 30 days.
    static let offsets: [(stage: ReminderStage, days: Int)] = [(.streak, 1), (.threeDays, 3), (.week, 7), (.month, 30)]

    /// - Parameters:
    ///   - lastActive: the day the last request was sent (or the day the app was first opened, before any request).
    ///   - streak: consecutive days with a request, counting back from `lastActive`'s day; the streak nudge needs one.
    ///   - target: the kind of broker to go after next.
    ///   - monthlyRepeats: how many further monthly nudges to line up after the first month one (iOS keeps at most 64 pending).
    public static func plan(lastActive: Date, streak: Int, target: BrokerCategory?, now: Date = Date(), calendar: Calendar = .current, monthlyRepeats: Int = 6) -> [PlannedReminder] {
        let day = calendar.startOfDay(for: lastActive)
        var steps = offsets.map { (stage: $0.stage, days: $0.days, id: $0.stage.rawValue) }
        for i in 1...max(1, monthlyRepeats) where monthlyRepeats > 0 { steps.append((.month, 30 * (i + 1), "month-\(i + 1)")) }
        return steps.compactMap { step in
            if step.stage == .streak && streak < 1 { return nil }
            guard let date = calendar.date(byAdding: .day, value: step.days, to: day),
                  let fire = calendar.date(bySettingHour: hour, minute: minute(id: step.id, on: date, calendar: calendar), second: 0, of: date), fire > now else { return nil }
            let text = message(step.stage, streak: streak, target: target)
            return PlannedReminder(id: idPrefix + step.id, stage: step.stage, fireDate: fire, title: text.title, body: text.body)
        }
    }

    /// Short enough for a lock screen: what to go after next and the worst that can happen if it stays out there.
    public static func message(_ stage: ReminderStage, streak: Int, target: BrokerCategory?) -> (title: String, body: String) {
        let kind = target?.title ?? L10n.t("Data brokers")
        let worst = worstCase(target)
        switch stage {
        case .streak:
            return (L10n.t("Keep your streak going"), L10n.f("%lld-day streak. Next up: %@. Worst case, %@. Remove a few more today.", streak, kind, worst))
        case .threeDays:
            return (L10n.t("3 days since your last opt-out"), L10n.f("Next up: %@. Worst case, %@. Each site you remove is less of you out there.", kind, worst))
        case .week:
            return (L10n.t("It has been a week"), L10n.f("%@ sites still list you. Worst case, %@. A short session helps.", kind, worst))
        case .month:
            return (L10n.t("A month since you opted out"), L10n.f("Brokers re-list people. Next up: %@. Worst case, %@. Check back and remove more.", kind, worst))
        }
    }

    /// The worst that can happen for one kind of broker, in a few words.
    public static func worstCase(_ kind: BrokerCategory?) -> String {
        switch kind {
        case .people_search: return L10n.t("strangers can look up your home address")
        case .location_data: return L10n.t("your daily movements are tracked and sold")
        case .healthcare: return L10n.t("your health data is sold or leaked")
        case .arrests: return L10n.t("old records cost you jobs and housing")
        case .marketing_data: return L10n.t("scammers buy lists that include you")
        case .fraud_identity: return L10n.t("your identity details feed fraud")
        case .financial: return L10n.t("your credit and money habits are for sale")
        case .lead_generation: return L10n.t("your number lands on endless call lists")
        case .real_estate: return L10n.t("your property details show where you live")
        case .consumer_reporting: return L10n.t("screening reports hurt jobs and housing")
        case .recruiting: return L10n.t("your work history is shared without you")
        case .political: return L10n.t("your views and donations are profiled")
        case .automotive: return L10n.t("your driving data raises your costs")
        case .genealogy: return L10n.t("your family details are searchable")
        case .b2b: return L10n.t("your work details fuel spam and phishing")
        case .adtech: return L10n.t("ad trackers follow you across apps")
        case .marketing_services: return L10n.t("your mailbox fills with junk mail")
        case .other, nil: return L10n.t("your data is sold without you knowing")
        }
    }
}
