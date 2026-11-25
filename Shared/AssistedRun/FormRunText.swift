import Foundation
import OptOutKitCore

/// Reading page text: what a confirmation looks like, what is new on screen. No web view in here, so it is tested without a simulator.
enum FormRun {
    /// The failure text for a page that is gone, so callers can tell a moved link from other failures and try to heal it.
    static let pageGone = "the page was gone (not found)"
    /// The failure text for a page the site would not show to this phone (`LinkRules.refusesAccess`): the link is right, the connection was refused.
    static let pageRefused = "the site would not show its page to this phone (it blocked the connection; a VPN can cause this)"

    /// The lines of `after` that were not in `before`.
    nonisolated static func newText(before: String, after: String) -> String {
        let seen = Set(before.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        return after.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !seen.contains($0) }.joined(separator: "\n")
    }

    /// Only a success reading, for text that may be anything: error and unknown readings come back as failed.
    nonisolated static func classifyConfirmed(_ text: String) -> SubmitOutcome {
        // A page the person just navigated to (or the next step of a form) is all "new text", and its instructions and consent wording talk about submitting
        // ("your request is submitted only after you enter the code", "you state that this request has been submitted by the individual"). Lines that explain
        // or ask are not a confirmation of what happened.
        let kept = text.split(whereSeparator: \.isNewline).map(String.init).filter { !isInstruction($0) && !isCheckStatus($0) }.joined(separator: "\n")
        if text.isEmpty { return .failed("") }
        // A sub-form that sends a code to the person's email ("Verify Email") is a step, not the end: the page says a code was sent, or asks for it, and the person types it in.
        // Only what the page reports counts; a form's standing instructions ("submitted only after you enter the code") are already left out of `kept`.
        // A code the site did not accept ("That code is not right", "invalid code", "the code expired") is a refusal, even though the page also asks for the code again.
        if rejectsCode(text) { return .rejected(wrongCodeReason) }          // read before the instruction lines are dropped: "Invalid code. Please enter it again." is one
        if asksForCode(kept) { return .failed("the page is waiting for a code from the person") }
        // "Please complete the verification challenge" under a Cloudflare box that only appeared, or was only enforced, once the form was sent: a human check.
        if asksForHumanCheck(text) { return .challenged(humanCheckAfterSending) }
        // A form that searches before it removes ("enter your information to find the data to remove") answering "No data was found": nothing to opt out of.
        // Read before the error wording, since such pages often add "try again" or "fix the following errors".
        if saysNoRecordFound(kept) { return .notListed }
        return kept.isEmpty ? .failed("no success message was shown") : classify(kept)
    }

    /// What a site that asked for a human check only after the form was sent is reported as (a human check: the person's to clear, `AutoOptOut.isHumanCheck`).
    nonisolated static let humanCheckAfterSending = "a human check the page asked for after sending"

    /// New text that asks the person to pass a check ("Please complete the verification challenge", "Please complete the security check", "Verify you are
    /// human"), as the Superset, jmr-media and instantly.ai forms answered a send. A check's own passing status ("Success!") is not this.
    nonisolated static func asksForHumanCheck(_ text: String) -> Bool {
        text.range(of: "(complete|finish|pass|solve) the (verification|security|captcha|human|bot|robot) ?(challenge|check|verification|test)?|(verify|confirm|prove) (that )?you('| a)?re (a )?human|(verify|confirm) you are not a (robot|bot)|captcha (is )?(required|failed|missing|not (completed|solved))|(failed|missing) (the )?(captcha|human|security) (check|verification|challenge)",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What a site that did not accept the emailed code is reported as.
    nonisolated static let wrongCodeReason = "the site did not accept the code"

    /// New text that says the code the person typed was wrong, expired or not accepted.
    nonisolated static func rejectsCode(_ text: String) -> Bool {
        text.range(of: "(code|otp|passcode)[^.\\n]{0,40}(not (right|correct|valid|accepted)|incorrect|invalid|did not match|does not match|doesn.t match|didn.t match|expired|wrong)|(incorrect|invalid|wrong|expired) (verification |security |one[- ]?time |confirmation )?(code|otp|passcode)",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A human check's own status line ("Success!" when a Cloudflare check passes, "Verified", "You are verified"): it says the check passed, not that the request
    /// was received. A check that passed by itself while the run waited was read as a confirmation, and the site recorded as sent with nothing pressed.
    nonisolated static func isCheckStatus(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).range(of: "^(success!?|verified!?|verification (complete|successful)!?|you are verified!?|you('re| are) (a )?human!?|i'?m not a robot|verifying\\.*)$",
                                                        options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A line that tells the person what to do or what will happen, or asks for their consent, with no sign that it already did.
    nonisolated static func isInstruction(_ line: String) -> Bool {
        let opts: String.CompareOptions = [.regularExpression, .caseInsensitive]
        // Consent and choice wording is never a confirmation, even when it says "submitted" or "processed".
        if line.range(of: "\\byou (agree|state|acknowledge|confirm|certify|consent)\\b|\\bby (submitting|clicking|checking|signing)\\b|\\bi agree\\b|will be (processed|reviewed|handled|completed)|within \\d+ (business )?(days|hours)|select (one|from|your)|list below|your choices|\\(required\\)", options: opts) != nil { return true }
        if line.range(of: "thank you|thanks for|has been (received|submitted|sent|processed)|have been (received|submitted)|was (received|submitted|sent)|successfully|is complete", options: opts) != nil { return false }
        return line.range(of: "^\\s*(note:|\\*)|\\b(if you|if we|when you|once you|until you|before you|after you|clicking|click|select this|does not submit|not submit|only after|to process|unless|you must|please (enter|provide|select|choose))\\b", options: opts) != nil
    }

    /// New text that says a code was sent to the person, or asks them to type one, so the request is not finished until they do.
    nonisolated static func asksForCode(_ text: String) -> Bool {
        text.range(of: "(enter|type|input|submit|paste) (the |your |a |this )?((\\d+|six|four|five)[- ]?(digit|character) |verification |confirmation |one[- ]?time |security |email |e-?mail |authentication )*(code|otp|passcode)|\\botp\\b|(check|look in|see) (your|the) (e-?mail|inbox|messages?)[^.]{0,40}\\bcode|\\bcode (has been |was |is being |is |will be |gets )?(sent|e-?mailed|emailed)|(sent|e-?mailed|emailed) (you |to you |the address[^.]{0,30} )?(an? |the )?([a-z0-9-]+ )?code|[0-9]-digit code",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// New text that says the whole opt-out is done (the page a confirmation email's link ends on), stricter than a send confirmation: "thank you" alone is not enough.
    nonisolated static func looksFinished(_ text: String) -> Bool {
        text.range(of: "(removal|opt.?out|deletion|request|verification) (is |has been |was )?(now )?(complete[d]?|confirmed|successful(ly)?|verified|finali[sz]ed)|(has|have) been (removed|deleted|suppressed|opted.?out)|(successfully|now) (removed|deleted|opted.?out|unsubscribed|verified|confirmed)|you (have|'ve) been (removed|opted.?out|unsubscribed)|(record|profile|listing|information)s? (has |have |was |were )?(been )?(removed|deleted|suppressed)|e-?mail (address )?(has been |is )?(verified|confirmed)|you are all set|you're all set",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// New text after a press that says the site's search found no record of the person ("No data was found, try other criteria", "We could not find any records").
    /// A line that only explains what happens if nothing is found ("If no records are found, ...") does not count.
    nonisolated static func saysNoRecordFound(_ text: String) -> Bool {
        let thing = "(matching )?(data|records?|results?|matches|listings?|profiles?|information|people|persons?|entries)"
        let says = "\\bno \(thing)( (was|were|has been|have been|could be))? found\\b|\\b(could ?n.?t|could not|did ?n.?t|did not|were unable to|was unable to|unable to) (find|locate) (any|a|your) \(thing)|\\bwe found no \(thing)|\\b0 (results|records|matches)( were)? found|\\bno \(thing) (match|matched) your (search|criteria|information)"
        return text.split(whereSeparator: \.isNewline).contains { line in
            line.range(of: "^\\s*(if|when|in case)\\b|\\bif (no|we|you)\\b", options: [.regularExpression, .caseInsensitive]) == nil
                && line.range(of: says, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// A page that says it is still working on the request ("Processing your request", "Please wait", "Do not close this page"): sent, but not confirmed.
    /// The page's send button now reads "Submitting…", "Sending…" (cashmereai.com) or "Processing..." (equifax.com and theworknumber.com, read before their
    /// answer came): the press went through and the site has not answered yet.
    nonisolated static func saysSending(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { $0.range(of: "^\\s*(submitting|sending|processing)(\\.{3}|…)?\\s*$", options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// New text after a press that says the button is still at work ("Submitting…", "Processing...") and nothing that says the site refused, wants a code or a
    /// check: sent, not confirmed. Standing words that only read as a reply ("All requests will be processed within 15 days", beside equifax.com's
    /// "Processing...") do not stop it, as they did when any reading but "no success message" counted as the site answering.
    nonisolated static func sentButUnanswered(_ newText: String) -> Bool {
        guard saysSending(newText), !rejectsCode(newText), !asksForCode(newText) else { return false }
        switch classify(newText) {
        case .rejected, .challenged: return false
        case .failed(let why): return why == "no success message was shown"
        default: return true
        }
    }

    nonisolated static func saysStillWorking(_ text: String) -> Bool {
        text.range(of: "processing your (request|submission)|being processed|please wait|do not (close|leave|refresh) (this|the) (page|window)|still (working|processing)", options: [.regularExpression, .caseInsensitive]) != nil
            && !looksFinished(text)
    }

        /// New text on the page that offers an opt-out or removal (a listing's "Opt out" button after a search).
    nonisolated static func mentionsOptOutControl(_ text: String) -> Bool {
        text.range(of: "opt.?(me.?)?out|remove (me|my|this)|do not sell", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Whether a page says an email will follow with more to do (a confirmation link, a verification message, "check your inbox").
    /// Wording that only says the site may write to you, or asks to "confirm your identity" without an email, is not enough.
    nonisolated static func mentionsEmailFollowUp(_ text: String) -> Bool {
        text.lowercased().range(of: "check your (e-?mail|inbox|spam)|(emailed|e-?mailed|sent) (you |the address[^.]{0,30})?an? (confirmation|verification) (link|e-?mail|message)|confirm your (e-?mail|request)|(sent|sending|emailed|e-?mailed) (you )?an? (e-?mail|message|link)|(we|you)('ll| will| are going to)? (send|email|receive) (you )?(an? )?[^.]{0,40}(confirmation|verification|follow-?up) (e-?mail|link|message)|verif(y|ication)[^.]{0,30}(e-?mail|link)|follow-?up e-?mail|link (in|from) (the|that|our|this) e-?mail|click (on )?the (confirmation )?link|e-?mail (with|containing) (a |the )?(link|instructions|next steps)|additional (information|steps) (will be|is|are) (sent|required)", options: .regularExpression) != nil
    }

    /// True when the page says, with confidence, that the whole request is finished and no email follows: its text says so and does not mention an email step.
    /// Anything less and a person is asked ("Is it completely done?").
    nonisolated static func finishIsCertain(_ text: String) -> Bool {
        looksFinished(text) && !mentionsEmailFollowUp(text)
    }

    /// "This field is mandatory" / "This field is required" / "Required field" under a box: the reason, naming the box (the nearest line above that is not
    /// the box's placeholder, "Choose state"), or nil when the page says no such thing.
    nonisolated static func requiredBoxLeftEmpty(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let says = try! NSRegularExpression(pattern: "^(this (field|question) is (mandatory|required)|(this )?field (is )?(mandatory|required)|required field|(this )?(field )?cannot be (empty|blank)|please (fill in|complete) this field)\\.?$", options: .caseInsensitive)
        guard let i = lines.firstIndex(where: { says.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) else { return nil }
        let placeholder = try! NSRegularExpression(pattern: "^(choose|select|pick|please (choose|select)|enter|type)\\b|^-+", options: .caseInsensitive)
        let name = lines[..<i].reversed().prefix(3).first { $0.count <= 40 && placeholder.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) == nil }
            .map { $0.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces) }
        if let name, !name.isEmpty { return "the site says a required box was left empty: \(name)" }
        return "the site says a required box was left empty"
    }

    /// What a site that takes requests only from some countries is reported as.
    nonisolated static let wrongCountry = "the site does not take requests from the country the phone was connecting from (a VPN can cause this)"

    nonisolated static func classify(_ text: String) -> SubmitOutcome {
        // "No further action is required at this time" (jmr-media.com's confirmation) says nothing is missing: it is not the error wording "is required".
        let t = text.lowercased().replacingOccurrences(of: "no (further|other|additional|more) (action|steps?)[^.\\n]{0,20} (is|are) (required|needed)|nothing (else|more|further) is (required|needed)",
                                                       with: " ", options: .regularExpression)
        // A form that takes requests only from some countries ("Sorry, this form does not accept submissions from your country", the arrests sites, when the phone
        // connected through a VPN or from abroad): the site refused, and says why.
        if t.range(of: "(does not|doesn.t|do not|cannot|can.t) accept (submissions|requests|entries) from your (country|region|location)|not available (in|from) your (country|region|location)", options: .regularExpression) != nil {
            return .rejected(wrongCountry)
        }
        // A bare "Too many requests" page: the site is limiting us, which says nothing about the form. Reported as that, not as a failed attempt.
        if t.range(of: "too many requests|rate.?limit(ed)?|error 429|429 too many", options: .regularExpression) != nil { return .failed(AutoOptOut.rateLimited) }
        // A required box left empty ("This field is mandatory" under "State"): said as that, with the box's name when the page shows it above the message.
        if let missing = requiredBoxLeftEmpty(text) { return .rejected(missing) }
        // An error comes first: "problem with your submission" pages often also contain the word "request".
        if t.range(of: "problem with your submission|review the fields|fields? (have|has) an error|error occurred|something went wrong|please (try again|correct)|is required|invalid|could not be (processed|verified)", options: .regularExpression) != nil {
            return .rejected("the site showed an error after sending")
        }
        let success = t.range(of: "follow-?up e-?mail|(we|you)('ll| will) (send|email|receive)[^.]{0,40}(e-?mail|link)|thank you|thanks for|success(ful(ly)?)?\\b|request (has been |was )?(received|submitted|processed|sent|logged|recorded)|(profile|listing|record)s? (has |have |was |were |is |are )?(now |been |successfully )*blocked|(successfully|been) blocked|we (will|'ll) (process|review|be in touch|contact)|your (request|submission) (is|has been)|we (have )?received (your|the)|thank you[.,!]? we|we have received|has been (received|submitted|processed)|check your (e-?mail|inbox)|confirm your (e-?mail|request)|sent you an? e-?mail|verification (e-?mail|link)|allow up to [0-9]+ days|will be (removed|processed|deleted)|opt-?out (has been |was |is )?(received|processed|successful|recorded)|submit+ed to be (opted.?out|removed|deleted)|please allow [0-9]+ (business )?days", options: .regularExpression) != nil
        let needsEmail = mentionsEmailFollowUp(t)
        if success { return .submitted(awaitingEmail: needsEmail) }
        if t.range(of: "please enter|please provide", options: .regularExpression) != nil {
            return .rejected("the site flagged a field or asked to try again")
        }
        return .failed("no success message was shown")
    }
}
