import Foundation

/// How a site's opt-out gets done, in terms of who does the work. This is what people see; the provisional A-D tiers stay internal.
public enum OptOutMethod: String, CaseIterable, Sendable {
    case automatic, semiAutomatic, emailOnly, manual

    public var title: String {
        switch self {
        case .automatic: return L10n.t("Automatic opt-out")
        case .semiAutomatic: return L10n.t("Semi-automated, with prompts for you")
        case .emailOnly: return L10n.t("Email only, you send one message")
        case .manual: return L10n.t("Later, no route yet")
        }
    }

    public var explanation: String {
        switch self {
        case .automatic: return L10n.t("The app fills in the site's form and sends it on its own.")
        case .semiAutomatic: return L10n.t("The app opens the page and fills in what it can. You solve the human check, finish anything it cannot fill, and tap Mark as done (and confirm an email if the site sends one).")
        case .emailOnly: return L10n.t("This site takes opt-outs by email and has no form. The app writes one message per address, naming every site it handles; you read it and tap Send.")
                case .manual: return L10n.t("We have not found a page or an email for this site yet. It is not a task today: we will find the link or address and unlock it later.")
        }
    }
}

public struct MethodVerdict: Equatable, Sendable {
    public var method: OptOutMethod
    /// The reason in plain words, for the site page and the pipeline report.
    public var reason: String
    public init(method: OptOutMethod, reason: String) { self.method = method; self.reason = reason }
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
            if live.blockers.contains("business") { return MethodVerdict(method: .semiAutomatic, reason: L10n.t("This form asks for business details, so nothing of yours is filled in: we show you the page and you decide.")) }
            if live.blockers.contains("agent") { return MethodVerdict(method: .semiAutomatic, reason: L10n.t("This form asks for an authorized agent's details. We fill in what we can; you finish the rest in the page and press its own button.")) }
            if live.blockers.contains("other") { return MethodVerdict(method: .semiAutomatic, reason: L10n.t("This form has questions the app cannot read. We fill in what we can; you answer the rest in the page and press its own button.")) }
            if live.blockers.contains("file") {
                // A face photo or a signature is never handed over for the person: on a site that carries a caution nothing is filled in at all.
                if e.caution != nil { return MethodVerdict(method: .semiAutomatic, reason: L10n.t("This form asks for a file or a signature, so nothing of yours is filled in: we show you the page.")) }
                return MethodVerdict(method: .semiAutomatic, reason: L10n.t("This form asks for a file or a signature. We fill in what we can; you add the file and press the page's own button."))
            }
        }
        guard let form = e.optOutForm else {
            if let live = e.liveForm, live.found {
                if e.runCheck?.result == "failed" { return MethodVerdict(method: .semiAutomatic, reason: L10n.t("A real run did not go through, so we fill in what we can and you finish it in the page.")) }
                // A form found on the live page that a reviewed real run showed to be confirmed, with nothing on it a person must clear.
                let mustClear = live.blockers.contains { $0.hasPrefix("check") || $0.hasPrefix("certify") || $0.hasPrefix("terms") || $0 == "code" }
                if let run = e.runCheck, run.result == "confirmed", !failedBefore, !challengedBefore, !mustClear {
                    return MethodVerdict(method: .automatic, reason: L10n.f("A real run on %@ showed this site's confirmation.", run.date))
                }
                return MethodVerdict(method: .semiAutomatic, reason: L10n.t("The opt-out form appears when the page loads in a browser. We fill it in; you clear any check it shows."))
            }
            // A link that is only the site's front page holds nothing to fill: email when there is an address, else we open the site and the person looks.
            if let url = e.optOutURL, url.path.isEmpty || url.path == "/", url.query == nil {
                if let mail = e.contactEmail { return MethodVerdict(method: .emailOnly, reason: L10n.f("This site takes opt-outs by email: write to %@. We prepare the message for you.", mail)) }
                return MethodVerdict(method: .manual, reason: L10n.t("We could not find an opt-out page on this site."))
            }
            if e.optOutURL != nil {
                if let mail = e.contactEmail { return MethodVerdict(method: .semiAutomatic, reason: L10n.f("We found the opt-out page: we open it, fill in what we can, and you do the rest and tap Mark as done. If the page does not work, write to %@ instead.", mail)) }
                return MethodVerdict(method: .semiAutomatic, reason: L10n.t("We found the opt-out page but cannot read its form: we open it, click through to the form if it hides behind a button, fill in what we can, and you do the rest and tap Mark as done."))
            }
            if let mail = e.contactEmail {
                return MethodVerdict(method: .emailOnly, reason: L10n.f("This site takes opt-outs by email: write to %@. We prepare the message for you.", mail))
            }
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
        case .needsYou(let why): return MethodVerdict(method: .semiAutomatic, reason: why)
        case .needsData(let what): return MethodVerdict(method: .semiAutomatic, reason: L10n.f("The form asks for %@, which we do not hold.", what.joined(separator: ", ")))
        case .ready:
            if listing != nil {
                return MethodVerdict(method: .semiAutomatic, reason: L10n.t("We search the site for you; you tap your own listing and clear the check, and we fill in and send the rest."))
            }
            // A reviewed real run beats every guess made from reading the page.
            if let run = e.runCheck {
                if run.result == "failed" {
                    return MethodVerdict(method: .semiAutomatic, reason: L10n.f("A real run on %@ did not go through (%@), so we fill the form in and you send it yourself.", run.date, run.note ?? "-"))
                }
                // Confirmed counts unless the page also shows something this person must clear (a human check, a box they may not tick).
                let personMustClear = (e.liveCheck?.blockers ?? []).contains { b in
                    !(b.hasPrefix("certify:") && confirmingIdentity && FormFiller.isSelfIdentityBox(String(b.dropFirst(8))))
                }
                if run.result == "confirmed", !failedBefore, !challengedBefore, !personMustClear {
                    return MethodVerdict(method: .automatic, reason: L10n.f("A real run on %@ showed this site's confirmation.", run.date))
                }
            }
            if failedBefore {
                return MethodVerdict(method: .semiAutomatic, reason: L10n.t("The app tried this site automatically and it did not go through, so we fill it in and you send it yourself."))
            }
            if challengedBefore {
                return MethodVerdict(method: .semiAutomatic, reason: L10n.t("A recent automatic send was stopped by a check on the site, so you solve it."))
            }
            guard let live = e.liveCheck else {
                // Never loaded on a real page, so we cannot promise nothing will ask for a check. Anything a person might have to
                // solve is not fully automated: it is semi-automated until a real load shows the form is clear.
                if signals.contains(where: { $0.hasPrefix("captcha_") }) {
                    return MethodVerdict(method: .semiAutomatic, reason: L10n.t("The page mentions a human check and we have not loaded it to see whether one appears."))
                }
                return MethodVerdict(method: .semiAutomatic, reason: L10n.t("We have not loaded this form on a real page yet, so a check might appear. You solve it if one does."))
            }
            // Measured: what really blocked the form when the page was loaded.
            for blocker in live.blockers {
                if blocker.hasPrefix("certify:"), confirmingIdentity, FormFiller.isSelfIdentityBox(String(blocker.dropFirst(8))) { continue }
                let what = blocker.hasPrefix("check") ? "a human check" : blocker.hasPrefix("terms") ? "a terms prompt" : "a confirmation box"
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

    /// A hand-written broker flow without a fillable form is still semi-automatic: its steps open the pages and fill what they can.
    public static func classify(_ b: Broker) -> MethodVerdict {
        MethodVerdict(method: .semiAutomatic, reason: L10n.f("A hand-written flow with %@ steps: the app opens each page and fills in what it can, and you do the rest.", b.steps.count))
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
