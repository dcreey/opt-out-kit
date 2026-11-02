import Foundation
import OptOutKitCore

/// Sends the opt-out forms of one page the person is looking at (Email links): waits for them to clear what the page asks, sends each opt-out form in turn through
/// the same page code Solve and send uses, and reads the answer. With sending for the person off, or when the page's bot check refuses a scripted press, the person
/// presses the page's own button and the confirmation is noticed. Nil while still waiting or if stopped.
@MainActor
enum PageSender {
    static func sendWhenReady(page: AssistedPage, autoSubmit: () -> Bool, status: (String) -> Void, isCancelled: () -> Bool, stillCurrent: () -> Bool = { true },
                              pollSeconds: Double = 1.5, limitSeconds: Double = 600, question: SentQuestion? = nil) async -> SubmitOutcome? {
        status(autoSubmit() ? Loc.t("Your details are filled in. Clear any check below and we will send it.")
                            : Loc.t("Your details are filled in. Check them, solve any check, then press the page's own button to send."))
        var waited: Double = 0, forced = false, baseline: String?, scrolls = 0
        var sentForms = 0, sentEmail = false
        while !isCancelled(), waited < limitSeconds {
            try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000)); waited += pollSeconds
            guard stillCurrent() else { return nil }
            if forced || !autoSubmit() {
                // The person presses the page's own button; a confirmation that appears is noticed.
                guard var base = baseline else { baseline = await page.pageText(); continue }
                let seen = await PageFlow.watch(page, baseline: &base, autoScrolls: &scrolls, question: question)
                baseline = base
                if case .confirmed(let email) = seen { status(Loc.t("Sent.")); return .submitted(awaitingEmail: email) }
                continue
            }
            if !(await page.blockers()).isEmpty { continue }
            status(Loc.t("Sending…"))
            await page.refill()
            switch await PageFlow.sendOnce(page) {
            case .sent(let email, let more):
                sentForms += 1; sentEmail = sentEmail || email
                if more { continue }                                         // another opt-out form on the same page
                status(Loc.t("Sent.")); return .submitted(awaitingEmail: sentEmail)
            case .handToPerson:
                forced = true; baseline = await page.pageText(); status(Loc.t("The site's bot check did not accept an automatic send. Press its Submit button yourself."))
            case .nextStep, .checkAppeared:
                continue                                                     // a check appeared, or the form moved on to its next step
            case .notConfirmed:
                if sentForms > 0 { return .submitted(awaitingEmail: sentEmail) }
                status(Loc.t("We pressed Send but saw no confirmation. If it needs one more step, do it in the page."))
                return .failed("no confirmation")
            case .dryRun: return .filledNotSubmitted
            }
        }
        return nil
    }
}
