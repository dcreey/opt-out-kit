import Foundation

/// How a site's opt-out gets done, in terms of who does the work. This is what people see; the provisional A-D tiers stay internal.
public enum OptOutMethod: String, CaseIterable, Sendable {
    case automatic, semiAutomatic, guided, manual

    public var title: String {
        switch self {
        case .automatic: return "Automatic opt-out"
        case .semiAutomatic: return "Semi-automated, with prompts for you"
        case .guided: return "Guided, you do the steps"
        case .manual: return "Manual, you find the page"
        }
    }

    public var explanation: String {
        switch self {
        case .automatic: return "The app fills in the site's form and sends it on its own."
        case .semiAutomatic: return "The app fills in the form and sends it. You solve the bot check (and confirm an email if the site sends one)."
        case .guided: return "The app opens the right page and walks you through each step. Some steps need things only you can do."
        case .manual: return "We could not read this site's opt-out page. Look for its privacy or \"do not sell\" link and follow it yourself."
        }
    }
}

public struct MethodVerdict: Equatable, Sendable {
    public var method: OptOutMethod
    /// The reason in plain words, for the site page and the pipeline report.
    public var reason: String
}

public enum OptOutMethods {
    /// A person with every detail a form could ask for, so the answer does not depend on who is using the app.
    private static func complete(confirmingIdentity: Bool) -> Person { Person(displayName: "Complete", relationship: confirmingIdentity ? .me : .otherFamily, names: [NameEntry(kind: .legal, name: "Pat Example")],
                                         addresses: [Address(street: "1 Main St", city: "Springfield", state: "IL")],
                                         emails: ["pat@example.com"], phones: ["555-0100"], birthdate: "1980-01-01", confirmsOwnIdentity: confirmingIdentity) }

    /// `confirmingIdentity` is true for the account owner when they have allowed "I am this person" boxes to be ticked for them.
    public static func classify(_ e: DirectoryEntry, confirmingIdentity: Bool = false, challengedBefore: Bool = false) -> MethodVerdict {
        let signals = e.signals ?? []
        guard let form = e.optOutForm else {
            if e.optOutURL != nil { return MethodVerdict(method: .guided, reason: "We found the opt-out page but could not read a form on it, so we take you there.") }
            switch e.automation {
            case .blocked: return MethodVerdict(method: .manual, reason: "The site refuses automated visits, so we could not find its opt-out page.")
            case .needsBrowser: return MethodVerdict(method: .manual, reason: "The site is built so that we could not read it to find the opt-out page.")
            case .robotsDisallowed: return MethodVerdict(method: .manual, reason: "The site asks bots not to visit, so we left it alone.")
            case .unreachable: return MethodVerdict(method: .manual, reason: "The site did not respond when we looked.")
            default: return MethodVerdict(method: .manual, reason: "We could not find an opt-out page on this site.")
            }
        }
        let plan = FormFiller.plan(for: form, signals: signals, person: complete(confirmingIdentity: confirmingIdentity))
        switch plan.verdict {
        case .needsYou(let why): return MethodVerdict(method: .guided, reason: why)
        case .needsData(let what): return MethodVerdict(method: .guided, reason: "The form asks for \(what.joined(separator: ", ")), which we do not hold.")
        case .ready:
            if challengedBefore {
                return MethodVerdict(method: .semiAutomatic, reason: "A recent automatic send was stopped by a check on the site, so you solve it.")
            }
            guard let live = e.liveCheck else {
                // Never measured on a real page: a captcha script on the page is only a hint, so stay cautious.
                if signals.contains(where: { $0.hasPrefix("captcha_") }) {
                    return MethodVerdict(method: .semiAutomatic, reason: "The page mentions a bot check and we have not loaded it to see whether one appears.")
                }
                return MethodVerdict(method: .automatic, reason: "A plain form we can fill in and send, with no bot check seen.")
            }
            // Measured: what really blocked the form when the page was loaded.
            for blocker in live.blockers {
                if blocker.hasPrefix("certify:"), confirmingIdentity, FormFiller.isSelfIdentityBox(String(blocker.dropFirst(8))) { continue }
                let what = blocker.hasPrefix("check") ? "a bot check" : blocker.hasPrefix("terms") ? "a terms prompt" : "a confirmation box"
                return MethodVerdict(method: .semiAutomatic, reason: "We fill in and send the form; the page shows \(what) that you handle.")
            }
            return MethodVerdict(method: .automatic, reason: "Loaded \(live.checked): nothing blocks the form. If the site adds a check when sending, we stop and ask you.")
        }
    }

    /// A hand-written broker flow always has steps a person takes part in.
    public static func classify(_ b: Broker) -> MethodVerdict {
        MethodVerdict(method: .guided, reason: "A hand-written walkthrough with \(b.steps.count) steps.")
    }

    public static func markdown(brokers: [Broker], entries: [DirectoryEntry]) -> String {
        var rows: [(String, MethodVerdict)] = brokers.map { ($0.name, classify($0)) }
        rows += Directory.unguided(entries, brokers: brokers).map { ($0.domain, classify($0)) }
        var out = "# How each site's opt-out gets done\n\nGenerated by `broker-pipeline --methods-report`. \(rows.count) sites.\n\n| Method | Sites |\n|---|---|\n"
        for m in OptOutMethod.allCases { out += "| \(m.title) | \(rows.filter { $0.1.method == m }.count) |\n" }
        for m in OptOutMethod.allCases {
            let list = rows.filter { $0.1.method == m }.sorted { $0.0 < $1.0 }
            out += "\n## \(m.title) (\(list.count))\n\n\(m.explanation)\n\n"
            for (name, v) in list { out += "- **\(name)**: \(v.reason)\n" }
        }
        return out
    }
}
