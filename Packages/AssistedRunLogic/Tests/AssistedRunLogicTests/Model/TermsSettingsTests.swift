import XCTest
import OptOutKitCore
@testable import AssistedRunLogic

/// Confirms the web view's terms handling against a LOCAL test page that imitates a site's "I agree" dialog and a cookie
/// banner. No real website is contacted, and nothing is accepted anywhere else.
private final class RecordingPolicy: TermsPolicy, @unchecked Sendable {
    let decision: TermsDecision
    var acceptedCalls: [String] = []
    var seenPrompt = ""
    init(_ decision: TermsDecision) { self.decision = decision }
    func decide(domain: String, prompt: String, documentLinks: [URL]) async -> TermsDecision { seenPrompt = prompt; return decision }
    func accepted(domain: String, paragraphs: Int, libraryVersion: Int) async { acceptedCalls.append(domain) }
}

private final class LogBox: @unchecked Sendable { var entries: [ConsentLogEntry] = [] }

private let gatePage = """
<html><body>
<div id="cookie">We use cookies to personalize your experience. <button onclick="document.getElementById('r').innerText='COOKIE BUTTON CLICKED'">Agree &amp; Proceed</button></div>
<div id="gate" role="dialog">
<p>ACCEPTABLE USE POLICY AND TERMS. This website is a private site that is not affiliated with any government agency or official source.</p>
<p>You agree to use the information on this site for lawful purposes only and not to harass or stalk anyone at any time whatsoever.</p>
<button id="agree" onclick="document.getElementById('r').innerText='Search results: Pat Example, Springfield'">I Agree</button>
<button id="no">I Don't Agree</button>
</div>
<div id="r">Waiting for terms</div>
</body></html>
"""

@MainActor
final class TermsSettingsTests: XCTestCase {
    private func model(library: TermsLibrary? = nil) throws -> AppModel {
        // The catalog the app ships with its terms library replaced by the test's own (nothing is read from a folder).
        var contents: Catalog.Contents?
        if let library {
            var c = try Catalog.contents(of: try XCTUnwrap(AppCatalog.url))
            c.termsLibrary = library
            contents = c
        }
        return AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-terms-\(UUID()).sqlite"), keys: FixedKey()),
                        contents: contents, defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
    }

    func testTheShippedLibraryIsReviewedButNothingIsAcceptedUntilThePersonAllowsIt() throws {
        let m = AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                         defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        XCTAssertGreaterThan(m.termsLibrary?.paragraphs.count ?? 0, 100)
        XCTAssertGreaterThan(m.termsReviewedCount, 0, "the owner approved the list, so the switch can be turned on")
        XCTAssertNil(m.termsApproval, "it is off until the person allows it")
        XCTAssertFalse(m.termsActive)
        XCTAssertNil(m.makeTermsPolicy())
        m.approveTerms()                       // the person taps Allow
        XCTAssertTrue(m.termsActive)
        XCTAssertNotNil(m.makeTermsPolicy())
        m.revokeTerms()
        XCTAssertFalse(m.termsActive); XCTAssertNil(m.makeTermsPolicy())
    }

    func testApprovalTurnsItOnAndRevokingTurnsItOff() throws {
        let lib = TermsLibrary(version: 5, paragraphs: [TermsParagraph(hash: "aaaa", sites: 2, kinds: ["terms"], flags: [], prefix: "x", reviewed: true, verdict: "ok")])
        let m = try model(library: lib)
        XCTAssertEqual(m.termsReviewedCount, 1)
        XCTAssertFalse(m.termsActive)
        XCTAssertNil(m.makeTermsPolicy(), "reviewed paragraphs alone are not enough: the person must approve")
        m.approveTerms()
        XCTAssertTrue(m.termsActive)
        XCTAssertNotNil(m.makeTermsPolicy())
        m.revokeTerms()
        XCTAssertFalse(m.termsActive)
        XCTAssertNil(m.makeTermsPolicy())
    }
}

final class TermsSummaryTests: XCTestCase {
    func testSummaryCoversTheClausesAPersonMustKnowAbout() {
        let all = TermsSummary.sections.flatMap(\.bullets).joined(separator: " ").lowercased()
        for must in ["indemnity", "minors", "public officials", "cookies", "as-is", "without telling you"] {
            XCTAssertTrue(all.contains(must), "summary should mention \(must)")
        }
        XCTAssertTrue(all.contains("credit, insurance, employment or tenant"), "the CourtRecords.us use restriction")
        XCTAssertFalse(TermsSummary.basis.isEmpty, "the summary must say what it was based on")
        XCTAssertGreaterThanOrEqual(TermsSummary.sections.count, 4)
    }
}
