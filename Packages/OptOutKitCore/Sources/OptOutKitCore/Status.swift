import Foundation

/// Where one person stands with one broker.
public enum PersonStatus: Equatable, Sendable {
    case notStarted
    case inProgress(stepsDone: Int, of: Int)
    case done(on: Date, recheckDue: Date)          // submitted, not yet confirmed by a check
    case verified(since: Date)                     // automatic checks confirm the listing is gone
    case relisted(on: Date)                        // a check found the person listed again
}

public struct BrokerStatus: Equatable, Sendable {
    public var person: Person
    public var status: PersonStatus
}

/// One line that sums a broker up across every profile in the household.
public enum StatusSummary: Equatable, Sendable {
    case notStarted
    case inProgress
    case partial(done: Int, of: Int)
    case submitted        // everyone submitted; checks have not confirmed removal yet
    case complete         // everyone verified removed
    case relisted         // someone was found listed again

    /// True once every person has submitted, whether or not a check has confirmed it.
    public var isFinished: Bool { self == .submitted || self == .complete }

    public var label: String {
        switch self {
        case .notStarted: return "Not started"
        case .inProgress: return "In progress"
        case .partial(let d, let n): return "Partial: \(d) of \(n) profiles opted out"
        case .submitted: return "Submitted, verifying"
        case .complete: return "Verified removed"
        case .relisted: return "Listed again"
        }
    }
}

public extension Household {
    func statuses(for broker: Broker) -> [BrokerStatus] {
        people.map { person in
            let p = progress(for: person.id)
            if let when = p.doneAt[broker.id] {
                switch p.verification(for: broker.id) {
                case .verified(let since): return BrokerStatus(person: person, status: .verified(since: since))
                case .relisted(let on): return BrokerStatus(person: person, status: .relisted(on: on))
                case .unverified: break
                }
                let due = Calendar.current.date(byAdding: .day, value: broker.recheckDays, to: when) ?? when
                return BrokerStatus(person: person, status: .done(on: when, recheckDue: due))
            }
            let n = p.completedSteps[broker.id]?.count ?? 0
            return BrokerStatus(person: person,
                                status: n == 0 ? .notStarted : .inProgress(stepsDone: n, of: broker.steps.count))
        }
    }

    func summary(for broker: Broker) -> StatusSummary {
        let all = statuses(for: broker).map(\.status)
        if all.contains(where: { if case .relisted = $0 { return true } else { return false } }) { return .relisted }
        let verified = all.filter { if case .verified = $0 { return true } else { return false } }.count
        let submitted = all.filter { if case .done = $0 { return true } else { return false } }.count
        let done = verified + submitted
        if !all.isEmpty, verified == all.count { return .complete }
        if !all.isEmpty, done == all.count { return .submitted }
        if done > 0 { return .partial(done: done, of: all.count) }
        if all.contains(where: { if case .inProgress = $0 { return true } else { return false } }) { return .inProgress }
        return .notStarted
    }
}

/// Plain-English text for the registry's technical tags, for the broker details page.
public enum Describe {
    public static func tier(_ tier: Tier) -> String {
        switch tier {
        case .A: return "A simple form and an email link"
        case .B: return "A form plus a CAPTCHA that you solve"
        case .C: return "A guided walkthrough with a phone, ID or account step"
        case .D: return "Email or letter only"
        }
    }

    private static let signals: [String: String] = [
        "captcha": "You solve a CAPTCHA",
        "email_link": "Sends you a confirmation email",
        "time_limited_link": "The email link expires quickly",
        "phone_verify": "Needs a phone code or call",
        "app_only": "Works only in a real browser",
        "third_party_refused": "You must submit it yourself",
        "search_first": "You find your listing first",
    ]

    private static let profiled: [String: String] = [
        "captcha_turnstile": "A bot check (Cloudflare Turnstile)",
        "captcha_recaptcha": "A bot check (reCAPTCHA)",
        "captcha_hcaptcha": "A bot check (hCaptcha)",
        "captcha_perimeterx": "A bot check (PerimeterX)",
        "captcha_datadome": "A bot check (DataDome)",
        "email_input": "Asks for your email",
        "name_input": "Asks for your name",
        "listing_url_input": "Asks for the link to your listing",
        "phone_input": "Asks for a phone number",
        "phone_verify": "May verify by phone call or text",
        "id_required": "May ask for ID or notarization",
        "file_upload": "Asks you to upload a file",
        "login_required": "Needs an account login",
        "account_hint": "Mentions creating an account",
        "mail_option": "Mentions mailing a request",
        "email_contact": "Lists an email address for requests",
        "script_rendered_page": "Page is built by JavaScript",
        "script_rendered_form": "Form is built by JavaScript",
        "bot_check_on_home": "Shows a bot check before anything else",
    ]

    public static func signal(_ tag: String) -> String {
        signals[tag] ?? profiled[tag] ?? (tag.hasPrefix("portal_") ? "Uses a privacy-request portal" : tag.replacingOccurrences(of: "_", with: " "))
    }

    public static func field(_ tag: String) -> String {
        switch tag {
        case "full_name": return "Full name"
        case "email": return "Email address"
        case "phone": return "Phone number"
        case "birthdate": return "Birthdate"
        case "address": return "Address"
        default: return tag.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
