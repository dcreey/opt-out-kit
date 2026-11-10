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
        case .notStarted: return L10n.t("Not started")
        case .inProgress: return L10n.t("In progress")
        case .partial(let d, let n): return L10n.f("Partial: %@ of %@ profiles opted out", d, n)
        case .submitted: return L10n.t("Submitted, verifying")
        case .complete: return L10n.t("Verified removed")
        case .relisted: return L10n.t("Listed again")
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
        case .A: return L10n.t("A simple form and an email link")
        case .B: return L10n.t("A form plus a CAPTCHA that you solve")
        case .C: return L10n.t("A guided walkthrough with a phone, ID or account step")
        case .D: return L10n.t("Email or letter only")
        }
    }

    private static var signals: [String: String] { [
        "captcha": L10n.t("You solve a CAPTCHA"),
        "email_link": L10n.t("Sends you a confirmation email"),
        "time_limited_link": L10n.t("The email link expires quickly"),
        "phone_verify": L10n.t("Needs a phone code or call"),
        "app_only": L10n.t("Works only in a real browser"),
        "third_party_refused": L10n.t("You must submit it yourself"),
        "search_first": L10n.t("You find your listing first"),
    ] }

    private static var profiled: [String: String] { [
        "captcha_turnstile": L10n.t("A human check (Cloudflare Turnstile)"),
        "captcha_recaptcha": L10n.t("A human check (reCAPTCHA)"),
        "captcha_hcaptcha": L10n.t("A human check (hCaptcha)"),
        "captcha_perimeterx": L10n.t("A human check (PerimeterX)"),
        "captcha_datadome": L10n.t("A human check (DataDome)"),
        "email_input": L10n.t("Asks for your email"),
        "name_input": L10n.t("Asks for your name"),
        "listing_url_input": L10n.t("Asks for the link to your listing"),
        "phone_input": L10n.t("Asks for a phone number"),
        "phone_verify": L10n.t("May verify by phone call or text"),
        "id_required": L10n.t("May ask for ID or notarization"),
        "file_upload": L10n.t("Asks you to upload a file"),
        "login_required": L10n.t("Needs an account login"),
        "account_hint": L10n.t("Mentions creating an account"),
        "mail_option": L10n.t("Mentions mailing a request"),
        "email_contact": L10n.t("Lists an email address for requests"),
        "script_rendered_page": L10n.t("Page is built by JavaScript"),
        "script_rendered_form": L10n.t("Form is built by JavaScript"),
        "bot_check_on_home": L10n.t("Shows a human check before anything else"),
    ] }

    public static func signal(_ tag: String) -> String {
        signals[tag] ?? profiled[tag] ?? (tag.hasPrefix("portal_") ? L10n.t("Uses a privacy-request portal") : tag.replacingOccurrences(of: "_", with: " "))
    }

    public static func field(_ tag: String) -> String {
        switch tag {
        case "full_name": return L10n.t("Full name")
        case "email": return L10n.t("Email address")
        case "phone": return L10n.t("Phone number")
        case "birthdate": return L10n.t("Birthdate")
        case "address": return L10n.t("Address")
        default: return tag.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
