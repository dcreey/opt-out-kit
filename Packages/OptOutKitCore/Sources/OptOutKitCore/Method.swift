import Foundation

/// How a site's opt-out gets done, in terms of who does the work. This is what people see; the provisional A-D tiers stay internal.
public enum OptOutMethod: String, CaseIterable, Sendable {
    case automatic, semiAutomatic, guided, manual

    public var title: String {
        switch self {
        case .automatic: return L10n.t("Automatic opt-out")
        case .semiAutomatic: return L10n.t("Semi-automated, with prompts for you")
        case .guided: return L10n.t("Guided, you do the steps")
        case .manual: return L10n.t("Manual, you find the page")
        }
    }

    public var explanation: String {
        switch self {
        case .automatic: return L10n.t("The app fills in the site's form and sends it on its own.")
        case .semiAutomatic: return L10n.t("The app fills in the form and sends it. You solve the bot check (and confirm an email if the site sends one).")
        case .guided: return L10n.t("The app opens the right page and walks you through each step. Some steps need things only you can do.")
        case .manual: return L10n.t("We could not read this site's opt-out page. Look for its privacy or \"do not sell\" link and follow it yourself.")
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
                                         addresses: [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")],
                                         emails: ["pat@example.com"], phones: ["555-0100"], birthdate: "1980-01-01", confirmsOwnIdentity: confirmingIdentity) }

    /// `confirmingIdentity` is true for the account owner when they have allowed "I am this person" boxes to be ticked for them.
    public static func classify(_ e: DirectoryEntry, confirmingIdentity: Bool = false, challengedBefore: Bool = false, failedBefore: Bool = false) -> MethodVerdict {
        let signals = e.signals ?? []
        // What a real page load showed that only the person can answer (a business field, an agent, a file, a state menu without their state,
        // questions the app cannot read). These hold whether the form was read from the page or found live.
        if let live = e.liveForm {
            if live.blockers.contains("business") { return MethodVerdict(method: .guided, reason: L10n.t("This form asks for business details, so we take you to the page and walk you through it.")) }
            if live.blockers.contains("agent") { return MethodVerdict(method: .guided, reason: L10n.t("This form asks for an authorized agent's details, so we take you to the page and walk you through it.")) }
            if live.blockers.contains("state") { return MethodVerdict(method: .guided, reason: L10n.t("This form's menu does not offer every state, so we take you to the page and walk you through it.")) }
            if live.blockers.contains("other") { return MethodVerdict(method: .guided, reason: L10n.t("This form has questions the app cannot read, so we take you to the page and walk you through it.")) }
            if live.blockers.contains("file") { return MethodVerdict(method: .guided, reason: L10n.t("This form asks for a file or a signature, so we take you to the page and walk you through it.")) }
        }
        guard let form = e.optOutForm else {
            if let live = e.liveForm, live.found {
                if e.runCheck?.result == "failed" { return MethodVerdict(method: .guided, reason: L10n.t("A real run did not go through, so you do this one with a guide.")) }
                return MethodVerdict(method: .semiAutomatic, reason: L10n.t("The opt-out form appears when the page loads in a browser. We fill it in; you clear any check it shows."))
            }
            if let mail = e.contactEmail {
                return MethodVerdict(method: .guided, reason: L10n.f("This site takes opt-outs by email: write to %@. We prepare the message for you.", mail))
            }
            if e.optOutURL != nil { return MethodVerdict(method: .guided, reason: L10n.t("We found the opt-out page, but the app cannot fill in its form for you, so we take you there and walk you through it.")) }
            switch e.automation {
            case .blocked: return MethodVerdict(method: .manual, reason: L10n.t("The site refuses automated visits, so we could not find its opt-out page."))
            case .needsBrowser: return MethodVerdict(method: .manual, reason: L10n.t("The site is built so that we could not read it to find the opt-out page."))
            case .robotsDisallowed: return MethodVerdict(method: .manual, reason: L10n.t("The site asks bots not to visit, so we left it alone."))
            case .unreachable: return MethodVerdict(method: .manual, reason: L10n.t("The site did not respond when we looked."))
            default: return MethodVerdict(method: .manual, reason: L10n.t("We could not find an opt-out page on this site."))
            }
        }
        // A form that wants the address of the person's own listing is workable when the site can be searched by name: the app
        // searches, the person taps their listing, the app fills the rest.
        let listing: URL? = FormFiller.needsListing(form) && e.hasListingSearch ? URL(string: "https://example.com/listing") : nil
        let plan = FormFiller.plan(for: form, signals: signals, person: complete(confirmingIdentity: confirmingIdentity), listingURL: listing)
        switch plan.verdict {
        case .needsYou(let why): return MethodVerdict(method: .guided, reason: why)
        case .needsData(let what): return MethodVerdict(method: .guided, reason: L10n.f("The form asks for %@, which we do not hold.", what.joined(separator: ", ")))
        case .ready:
            if listing != nil {
                return MethodVerdict(method: .semiAutomatic, reason: L10n.t("We search the site for you; you tap your own listing and clear the check, and we fill in and send the rest."))
            }
            // A reviewed real run beats every guess made from reading the page.
            if let run = e.runCheck {
                if run.result == "failed" {
                    return MethodVerdict(method: .guided, reason: L10n.f("A real run on %@ did not go through (%@), so you do this one with a guide.", run.date, run.note ?? "-"))
                }
                // Confirmed counts unless the page also shows something this person must clear (a bot check, a box they may not tick).
                let personMustClear = (e.liveCheck?.blockers ?? []).contains { b in
                    !(b.hasPrefix("certify:") && confirmingIdentity && FormFiller.isSelfIdentityBox(String(b.dropFirst(8))))
                }
                if run.result == "confirmed", !failedBefore, !challengedBefore, !personMustClear {
                    return MethodVerdict(method: .automatic, reason: L10n.f("A real run on %@ showed this site's confirmation.", run.date))
                }
            }
            if failedBefore {
                return MethodVerdict(method: .guided, reason: L10n.t("The app tried this site automatically and it did not go through, so you do it with a guide."))
            }
            if challengedBefore {
                return MethodVerdict(method: .semiAutomatic, reason: L10n.t("A recent automatic send was stopped by a check on the site, so you solve it."))
            }
            guard let live = e.liveCheck else {
                // Never loaded on a real page, so we cannot promise nothing will ask for a check. Anything a person might have to
                // solve is not fully automated: it is semi-automated until a real load shows the form is clear.
                if signals.contains(where: { $0.hasPrefix("captcha_") }) {
                    return MethodVerdict(method: .semiAutomatic, reason: L10n.t("The page mentions a bot check and we have not loaded it to see whether one appears."))
                }
                return MethodVerdict(method: .semiAutomatic, reason: L10n.t("We have not loaded this form on a real page yet, so a check might appear. You solve it if one does."))
            }
            // Measured: what really blocked the form when the page was loaded.
            for blocker in live.blockers {
                if blocker.hasPrefix("certify:"), confirmingIdentity, FormFiller.isSelfIdentityBox(String(blocker.dropFirst(8))) { continue }
                let what = blocker.hasPrefix("check") ? "a bot check" : blocker.hasPrefix("terms") ? "a terms prompt" : "a confirmation box"
                return MethodVerdict(method: .semiAutomatic, reason: L10n.f("We fill in and send the form; the page shows %@ that you handle.", what))
            }
            // Nothing blocked the form at load, but a real send is what proves a site takes it with no human check: until a reviewed real run
            // confirms it (`run_check: confirmed`), we fill it in and the person ticks whatever check appears.
            return MethodVerdict(method: .semiAutomatic, reason: L10n.f("Loaded %@: nothing blocked the form. We fill it in and send it; you tick any check the site shows. A confirmed real run would make it automatic.", live.checked))
        }
    }

    /// A hand-written flow: semi-automated when its own site's form only needs the person's listing picked, else guided.
    public static func classify(_ b: Broker, in entries: [DirectoryEntry]) -> MethodVerdict {
        if let e = Directory.entry(for: b, in: entries), let form = e.optOutForm, FormFiller.needsListing(form) {
            let v = classify(e)
            if v.method == .semiAutomatic { return v }
        }
        return classify(b)
    }

    /// A hand-written broker flow without a fillable form always has steps a person takes part in.
    public static func classify(_ b: Broker) -> MethodVerdict {
        MethodVerdict(method: .guided, reason: L10n.f("A hand-written walkthrough with %@ steps.", b.steps.count))
    }

    public static func markdown(brokers: [Broker], entries: [DirectoryEntry]) -> String {
        var rows: [(String, MethodVerdict)] = brokers.map { ($0.name, classify($0, in: entries)) }
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
