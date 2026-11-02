import Foundation
import OptOutKitCore

/// What one press of a page's send button turned out to be. Every flow (Solve and send, Email links, the monthly run, the guide) reads a send the same way,
/// through `PageFlow.sendOnce`, and only differs in what it does next: wait for the person, give up on this site, or go on to another site.
enum SendStep: Equatable {
    /// This form went through. `moreForms`: another opt-out form on the same page is now filled in and ready.
    case sent(awaitingEmail: Bool, moreForms: Bool)
    /// The form moved on to its next step (Next, then Submit): fill it and press again.
    case nextStep
    /// The page's bot check refuses a scripted press (a score-based reCAPTCHA): only the person's own press can get past it.
    case handToPerson
    /// A check or a prompt came up after pressing: the person clears it and the send is tried again.
    case checkAppeared(String)
    /// Pressed, and the page did not say it went through (an error, or no confirmation wording).
    case notConfirmed(SubmitOutcome)
    /// A dry run: filled, nothing sent.
    case dryRun
}

@MainActor
enum PageFlow {
    static let nextStepMarker = "the form moved on to its next step"
    static let rejectedMarker = "rejected the automatic send"

    /// "Refresh the page" in every flow: a form that fails and asks for a refresh is reloaded, then the person's details are put back once the page has settled.
    static func reloadThenRefill(reload: () -> Void, refill: () async -> Void, settle: UInt64 = 3_500_000_000) async {
        reload()
        try? await Task.sleep(nanoseconds: settle)
        await refill()
    }

    /// Presses send on the page's current form and says what that was.
    static func sendOnce(_ page: AssistedPage) async -> SendStep {
        switch await page.send() {
        case .submitted(let email): return .sent(awaitingEmail: email, moreForms: await page.moreForms())
        case .challenged(let why):
            if why == nextStepMarker { return .nextStep }
            if why.contains(rejectedMarker) { return .handToPerson }
            return .checkAppeared(why)
        case .filledNotSubmitted: return .dryRun
        case let other: return .notConfirmed(other)
        }
    }

    /// What reading the page found since the last look.
    enum Watched: Equatable { case confirmed(awaitingEmail: Bool), newFormFilled, nothing }

    /// Reads what is on screen. A confirmation the person caused (they pressed the page's own button) is the result. Otherwise the screen changed: a new privacy form
    /// may have appeared (a window opened, the next step), which is filled in; or an opt-out button came into view, which is scrolled to (at most twice per site, and
    /// never for the person's own scrolling).
    static func watch(_ page: AssistedPage, baseline: inout String, autoScrolls: inout Int, force: Bool = false, domChanged: Bool = false, question: SentQuestion? = nil) async -> Watched {
        // The person has the cursor in a box: no reading that could fill, click or scroll. The change is looked at once they are done, since the baseline is not moved.
        if await page.userIsTyping() { return .nothing }
        let now = await page.pageText()
        // A form that opens with an animation may still be collapsed on the first look, so after a change the page is read again a few times even when the text is the same.
        guard !now.isEmpty, now != baseline || force else { return .nothing }
        let added = FormRun.newText(before: baseline, after: now)
        baseline = now
        if case .submitted(let email) = FormRun.classifyConfirmed(added) {
            // A verification code still to type is the next step of the form, not the end of it.
            if await page.awaitingCode() { return .nothing }
            // Nothing the person pressed since the fill: the site may have shown this by itself, so they are asked rather than assumed to have sent it.
            if let question, await page.pressesSinceFill() == 0 {
                return await question.ask(awaitingEmail: email) ? .confirmed(awaitingEmail: email) : .nothing
            }
            return .confirmed(awaitingEmail: email)
        }
        if await page.adoptNewForm() { return .newFormFilled }
        if domChanged, autoScrolls < 2, FormRun.mentionsOptOutControl(added) { if await page.scrollToOptOut() { autoScrolls += 1 } }
        return .nothing
    }
}
