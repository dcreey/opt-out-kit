import Foundation

/// A plain-English summary of what accepting these sites' terms means, shown before a person allows the app to accept
/// them. Written from the actual texts (see `basis`), not from the app's matching list. It is a summary, not legal advice,
/// and it must be re-read and updated whenever the reviewed list changes.
enum TermsSummary {
    struct Section: Identifiable {
        let id: String
        let title: String
        let bullets: [String]
    }

    static let basis = Loc.t("Based on the acceptable-use prompt, Terms of Service and Privacy Policy of alabamaarrests.org, usrecords.net and sdarrests.org (the same network of about 44 sites), plus the notice shown by CourtRecords.us. Read 2026-10-21. Other sites in a group can differ.")

    static let sections: [Section] = [
        Section(id: "network", title: Loc.t("The arrests, warrants and records network (about 44 sites)"), bullets: [
            Loc.t("Visiting is agreeing. You are bound by the terms just by using the site, and again by tapping \"I agree\"."),
            Loc.t("Use it lawfully only. No stalking or harassing anyone, and no using a false identity to get information."),
            Loc.t("You may not search for public officials, minors or celebrities. If someone you add to Exnay is one of those, do not scan or accept for them."),
            Loc.t("You must be 18 or older."),
            Loc.t("You promise to cover the site's costs. A broad \"indemnity\" clause says you hold the site, its advertisers and partners harmless from any claim arising from your use of the site or breaking these terms."),
            Loc.t("You carry the risk. The records are \"as-is\" and can be wrong, they are not legal advice, and the site disclaims every warranty and limits its liability to nothing."),
            Loc.t("Do not copy the site's content. Anything you send them unasked, they may use and republish."),
            Loc.t("They can change the terms at any time without telling you."),
            Loc.t("They earn money from referrals. Search forms and links pay them commissions, and a registration through the site opens a separate third-party paid membership area they do not control. Exnay never registers or pays."),
        ]),
        Section(id: "privacy", title: Loc.t("What their privacy policy says about you"), bullets: [
            Loc.t("They log visits: your IP address, browser, pages viewed, clicks and scrolling, and where you came from."),
            Loc.t("They and their advertisers may set tracking cookies that follow purchases and target ads. Exnay's browser keeps no cookies between visits and turns down cookie banners."),
            Loc.t("They say they will not sell or rent information you give them without consent, except for law enforcement, court orders or their own legal defence."),
            Loc.t("They give no security guarantee and say they are not responsible for breaches. Your data may be stored or moved to other countries."),
            Loc.t("They may change the policy without notice, and visiting counts as consent."),
        ]),
        Section(id: "courtrecords", title: Loc.t("CourtRecords.us notice (state court-records sites)"), bullets: [
            Loc.t("It is not a consumer reporting agency. You agree not to use what you find for credit, insurance, employment or tenant decisions."),
            Loc.t("It says it cannot confirm that its information is accurate or complete."),
            Loc.t("Tapping \"I agree\" means you accept its Terms of Service and Privacy Policy. Only a preliminary people search is free; full records need an account or purchase."),
            Loc.t("I read only this notice, not that site's full terms."),
        ]),
        Section(id: "what", title: Loc.t("What this means for you"), bullets: [
            Loc.t("Accepting does not cost money. The prompts and terms I read have no fee, subscription or arbitration clause."),
            Loc.t("The biggest commitment is the indemnity clause, and it already applies to anyone who visits the site."),
            Loc.t("None of the three terms pages I read bans automated access, but the app only accepts when no paragraph does."),
            Loc.t("Results are unproven. A listing found here can be wrong, so Exnay treats it as a lead, not proof."),
        ]),
    ]
}
