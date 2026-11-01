import Foundation
import OptOutKitCore

/// Reading page text: what a confirmation looks like, what is new on screen. No web view in here, so it is tested without a simulator.
enum FormRun {
    /// The failure text for a page that is gone, so callers can tell a moved link from other failures and try to heal it.
    static let pageGone = "the page was gone (not found)"

    /// The lines of `after` that were not in `before`.
    nonisolated static func newText(before: String, after: String) -> String {
        let seen = Set(before.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        return after.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !seen.contains($0) }.joined(separator: "\n")
    }

    /// Only a success reading, for text that may be anything: error and unknown readings come back as failed.
    nonisolated static func classifyConfirmed(_ text: String) -> SubmitOutcome {
        // A page the person just navigated to is all "new text", and its instructions talk about submitting ("your request is submitted only after
        // you enter the code"). Lines that explain what will happen are not a confirmation of what did.
        let kept = text.split(whereSeparator: \.isNewline).map(String.init).filter { !isInstruction($0) }.joined(separator: "\n")
        return kept.isEmpty ? .failed("") : classify(kept)
    }

    /// A line that tells the person what to do or what will happen, with no sign that it already did.
    nonisolated static func isInstruction(_ line: String) -> Bool {
        let opts: String.CompareOptions = [.regularExpression, .caseInsensitive]
        if line.range(of: "thank you|thanks for|has been (received|submitted|sent|processed)|have been (received|submitted)|was (received|submitted|sent)|successfully|is complete", options: opts) != nil { return false }
        return line.range(of: "^\\s*(note:|\\*)|\\b(if you|if we|when you|once you|until you|before you|after you|clicking|click|select this|does not submit|not submit|only after|to process|unless|you must|please (enter|provide|select|choose))\\b", options: opts) != nil
    }

    /// New text that says the whole opt-out is done (the page a confirmation email's link ends on), stricter than a send confirmation: "thank you" alone is not enough.
    nonisolated static func looksFinished(_ text: String) -> Bool {
        text.range(of: "(removal|opt.?out|deletion|request|verification) (is |has been |was )?(now )?(complete[d]?|confirmed|successful(ly)?|verified|finali[sz]ed)|(has|have) been (removed|deleted|suppressed|opted.?out)|(successfully|now) (removed|deleted|opted.?out|unsubscribed|verified|confirmed)|you (have|'ve) been (removed|opted.?out|unsubscribed)|(record|profile|listing|information)s? (has |have |was |were )?(been )?(removed|deleted|suppressed)|e-?mail (address )?(has been |is )?(verified|confirmed)|you are all set|you're all set",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// New text on the page that offers an opt-out or removal (a listing's "Opt out" button after a search).
    nonisolated static func mentionsOptOutControl(_ text: String) -> Bool {
        text.range(of: "opt.?(me.?)?out|remove (me|my|this)|do not sell", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Whether a page says an email will follow with more to do (a confirmation link, a verification message, "check your inbox").
    nonisolated static func mentionsEmailFollowUp(_ text: String) -> Bool {
        text.lowercased().range(of: "check your (e-?mail|inbox|spam)|(emailed|e-?mailed|sent) (you |the address[^.]{0,30})?an? (confirmation|verification) (link|e-?mail|message)|confirm your (e-?mail|request|identity)|(sent|send|sending|email|emailed|e-?mail) (you )?an? (e-?mail|message|link)|(we|you)('ll| will| have| are going to)? (send|email|receive)[^.]{0,40}(e-?mail|link)|verif(y|ication)[^.]{0,30}(e-?mail|link)|follow-?up e-?mail|link (in|from) (the|that|our|this) e-?mail|click (on )?the (confirmation )?link|e-?mail (with|containing) (a |the )?(link|instructions|next steps)|additional (information|steps) (will be|is|are) (sent|required)", options: .regularExpression) != nil
    }

    nonisolated static func classify(_ text: String) -> SubmitOutcome {
        let t = text.lowercased()
        // A bare "Too many requests" page: the site is limiting us, which says nothing about the form. Reported as that, not as a failed attempt.
        if t.range(of: "too many requests|rate.?limit(ed)?|error 429|429 too many", options: .regularExpression) != nil { return .failed(AutoOptOut.rateLimited) }
        // An error comes first: "problem with your submission" pages often also contain the word "request".
        if t.range(of: "problem with your submission|review the fields|fields? (have|has) an error|error occurred|something went wrong|please (try again|correct)|is required|invalid|could not be (processed|verified)", options: .regularExpression) != nil {
            return .rejected("the site showed an error after sending")
        }
        let success = t.range(of: "follow-?up e-?mail|(we|you)('ll| will) (send|email|receive)[^.]{0,40}(e-?mail|link)|thank you|thanks for|success(ful(ly)?)?\\b|request (has been |was )?(received|submitted|processed|sent|logged|recorded)|(profile|listing|record)s? (has |have |was |were |is |are )?(now |been |successfully )*blocked|(successfully|been) blocked|we (will|'ll) (process|review|be in touch|contact)|your (request|submission) (is|has been)|we (have )?received (your|the)|thank you[.,!]? we|we have received|has been (received|submitted|processed)|check your (e-?mail|inbox)|confirm your (e-?mail|request)|sent you an? e-?mail|verification (e-?mail|link)|allow up to [0-9]+ days|will be (removed|processed|deleted)|opt-?out (has been|was) (received|processed|successful)", options: .regularExpression) != nil
        let needsEmail = mentionsEmailFollowUp(t)
        if success { return .submitted(awaitingEmail: needsEmail) }
        if t.range(of: "please enter|please provide", options: .regularExpression) != nil {
            return .rejected("the site flagged a field or asked to try again")
        }
        return .failed("no success message was shown")
    }
}
