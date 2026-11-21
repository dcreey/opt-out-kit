import Foundation
import OptOutKitCore

/// Applies `TermsGate` for the web view. It reads the terms pages the prompt links to (`fetchDocument`: in the app, their own web views, which never
/// accept anything themselves), then asks the gate. Acceptance is possible only if the person approved this library version.
struct LibraryTermsPolicy: TermsPolicy {
    let library: TermsLibrary
    let approval: TermsApproval?
    /// The text of a terms page, or nil when it could not be read.
    let fetchDocument: @Sendable (URL) async -> String?
    /// Called after the button was pressed.
    let onAccepted: @Sendable (ConsentLogEntry) -> Void

    func decide(domain: String, prompt: String, documentLinks: [URL]) async -> TermsDecision {
        var documents: [String] = []
        for link in documentLinks.prefix(4) {
            if let text = await fetchDocument(link) { documents.append(text) }
        }
        return TermsGate.decide(prompt: prompt, documents: documents, domain: domain, library: library, approval: approval)
    }

    func accepted(domain: String, paragraphs: Int, libraryVersion: Int) async {
        onAccepted(ConsentLogEntry(domain: domain, paragraphs: paragraphs, libraryVersion: libraryVersion))
    }
}
