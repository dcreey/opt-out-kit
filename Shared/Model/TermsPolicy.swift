import Foundation
import OptOutKitCore

/// The app's side of the terms decision. It is given the prompt text and the addresses of the terms pages the prompt links
/// to, reads those pages itself, and answers with a `TermsDecision`. Only `.accept` lets the web view press "I agree".
protocol TermsPolicy: Sendable {
    func decide(domain: String, prompt: String, documentLinks: [URL]) async -> TermsDecision
    /// Called after the button was pressed, so the acceptance can be logged on the device.
    func accepted(domain: String, paragraphs: Int, libraryVersion: Int) async
}
