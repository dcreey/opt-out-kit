import Foundation
import Combine

/// "Was this sent?": asked when a page shows a confirmation and nothing says the person pressed anything, so it may be the site's own message (a code sent by itself,
/// a page that reacts to a filled box). One screen shows it (`sentQuestionAlert`); the flow that asked waits for the answer.
@MainActor
final class SentQuestion: ObservableObject {
    /// Set while the question is on screen: whether the page also says an email will follow.
    @Published private(set) var pending: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// True when the person says it was sent. Asking again, or leaving the site, answers the earlier question "no".
    func ask(awaitingEmail: Bool) async -> Bool {
        resolve(false)
        pending = awaitingEmail
        return await withCheckedContinuation { continuation = $0 }
    }

    func answer(sent: Bool) { resolve(sent) }
    /// The person moved on (skip, next, stop): nothing is waiting any more.
    func dismiss() { resolve(false) }

    private func resolve(_ sent: Bool) {
        pending = nil
        let c = continuation; continuation = nil
        c?.resume(returning: sent)
    }
}
