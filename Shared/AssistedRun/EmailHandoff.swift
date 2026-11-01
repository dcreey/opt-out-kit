import Foundation
import OptOutKitCore

/// The email step of the assisted run, as plain state the screen only displays: it opens the message (in-app composer or another mail app), and
/// always ends by asking "Did you send it?" for another mail app, which cannot tell us. Kept apart from the view so the rules are unit tested.
@MainActor
final class EmailHandoff: ObservableObject {
    /// The message in the in-app composer.
    @Published var composing: EmailBatch?
    /// Asked right when another mail app is opened, so the question is waiting when the person comes back. Never tied to the app coming to the front.
    @Published var confirming: EmailBatch?

    private let runner: AssistedRunner
    /// Saves the batch as emailed; set by the screen once it has the app model.
    var markEmailed: (EmailBatch) -> Void = { _ in }
    init(runner: AssistedRunner) { self.runner = runner }

    /// True while any part of the email step is on screen: the offer dialog stays away so it cannot cover the question.
    var active: Bool { composing != nil || confirming != nil }

    func open(_ batch: EmailBatch, composesInApp: Bool, url: URL?, launch: (URL) -> Void) {
        if composesInApp { composing = batch }
        else if let url { confirming = batch; launch(url) }
        else if runner.emailOffer != nil { runner.answerEmailOffer(sent: false) }
    }

    /// The batch comes from the composer itself: the sheet may already have cleared `composing` by the time it reports.
    func composeFinished(_ batch: EmailBatch, sent: Bool) {
        composing = nil
        sent ? done(batch) : declined()
    }

    func answer(sent: Bool) {
        guard let batch = confirming else { return }
        confirming = nil
        sent ? done(batch) : declined()
    }

    private func done(_ batch: EmailBatch) {
        markEmailed(batch)
        if runner.emailOffer != nil { runner.answerEmailOffer(sent: true) } else { runner.finishByEmail() }
    }
    private func declined() { if runner.emailOffer != nil { runner.answerEmailOffer(sent: false) } }
}
