import Foundation

/// "Is it completely done?": asked when a site looks sent but the page does not say, with confidence, that nothing more is coming (a page that mentions an email
/// to follow, or one that only says thanks). One question for every flow that has a person on screen; the flow that asked waits for the answer.
/// Never asked by the background run, which has no one to ask: it keeps the older rule (an email step only when the page says so).
@MainActor
final class FinishQuestion: ObservableObject {
    enum Answer: Equatable {
        /// Finished entirely: nothing more to do for this site.
        case done
        /// An email (another one, if some were done already) is still to come.
        case emailFollows
        /// The person cannot tell. Treated as an email still to come, so the site stays on the waiting list instead of being counted done.
        case unsure
        /// Not finished: stay on this site.
        case notYet

        /// True when the site should wait on an email.
        var needsEmail: Bool { self == .emailFollows || self == .unsure }
    }

    /// `allowsNotYet`: whether "Not yet" is offered (every flow offers it: it keeps the person on the site and records nothing).
    struct Ask: Equatable { let site: String; let pageSaidEmail: Bool; let allowsNotYet: Bool }
    /// Set while the question is on screen.
    @Published private(set) var pending: Ask?
    private var continuation: CheckedContinuation<Answer, Never>?

    func ask(site: String, pageSaidEmail: Bool, allowsNotYet: Bool) async -> Answer {
        resolve(.notYet)
        pending = Ask(site: site, pageSaidEmail: pageSaidEmail, allowsNotYet: allowsNotYet)
        return await withCheckedContinuation { continuation = $0 }
    }

    func answer(_ answer: Answer) { resolve(answer) }
    /// The person moved on (skip, stop): nothing is waiting any more.
    func dismiss() { resolve(.notYet) }

    private func resolve(_ answer: Answer) {
        pending = nil
        let c = continuation; continuation = nil
        c?.resume(returning: answer)
    }
}
