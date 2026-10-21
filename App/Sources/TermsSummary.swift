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

    static let basis = "Based on the acceptable-use prompt, Terms of Service and Privacy Policy of alabamaarrests.org, usrecords.net and sdarrests.org (the same network of about 44 sites), plus the notice shown by CourtRecords.us. Read 2026-10-21. Other sites in a group can differ."

    static let sections: [Section] = [
        Section(id: "network", title: "The arrests, warrants and records network (about 44 sites)", bullets: [
            "Visiting is agreeing. You are bound by the terms just by using the site, and again by tapping \"I agree\".",
            "Use it lawfully only. No stalking or harassing anyone, and no using a false identity to get information.",
            "You may not search for public officials, minors or celebrities. If someone you add to Opt-Out Kit is one of those, do not scan or accept for them.",
            "You must be 18 or older.",
            "You promise to cover the site's costs. A broad \"indemnity\" clause says you hold the site, its advertisers and partners harmless from any claim arising from your use of the site or breaking these terms.",
            "You carry the risk. The records are \"as-is\" and can be wrong, they are not legal advice, and the site disclaims every warranty and limits its liability to nothing.",
            "Do not copy the site's content. Anything you send them unasked, they may use and republish.",
            "They can change the terms at any time without telling you.",
            "They earn money from referrals. Search forms and links pay them commissions, and a registration through the site opens a separate third-party paid membership area they do not control. Opt-Out Kit never registers or pays.",
        ]),
        Section(id: "privacy", title: "What their privacy policy says about you", bullets: [
            "They log visits: your IP address, browser, pages viewed, clicks and scrolling, and where you came from.",
            "They and their advertisers may set tracking cookies that follow purchases and target ads. Opt-Out Kit's browser keeps no cookies between visits and turns down cookie banners.",
            "They say they will not sell or rent information you give them without consent, except for law enforcement, court orders or their own legal defence.",
            "They give no security guarantee and say they are not responsible for breaches. Your data may be stored or moved to other countries.",
            "They may change the policy without notice, and visiting counts as consent.",
        ]),
        Section(id: "courtrecords", title: "CourtRecords.us notice (state court-records sites)", bullets: [
            "It is not a consumer reporting agency. You agree not to use what you find for credit, insurance, employment or tenant decisions.",
            "It says it cannot confirm that its information is accurate or complete.",
            "Tapping \"I agree\" means you accept its Terms of Service and Privacy Policy. Only a preliminary people search is free; full records need an account or purchase.",
            "I read only this notice, not that site's full terms.",
        ]),
        Section(id: "what", title: "What this means for you", bullets: [
            "Accepting does not cost money. The prompts and terms I read have no fee, subscription or arbitration clause.",
            "The biggest commitment is the indemnity clause, and it already applies to anyone who visits the site.",
            "None of the three terms pages I read bans automated access, but the app only accepts when no paragraph does.",
            "Results are unproven. A listing found here can be wrong, so Opt-Out Kit treats it as a lead, not proof.",
        ]),
    ]
}
