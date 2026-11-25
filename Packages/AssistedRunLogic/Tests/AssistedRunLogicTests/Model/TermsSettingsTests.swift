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

    /// Every "I agree" the app presses is written to the acceptance log Settings shows, with the site, and kept after the app is opened again.
    func testEveryAcceptanceIsWrittenToTheLogSettingsShows() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed")
        let keys = FixedKey()
        let m = AppModel(store: HouseholdStore(url: url, keys: keys), defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        m.approveTerms()
        let policy = try XCTUnwrap(m.makeTermsPolicy())
        XCTAssertTrue(m.consentLog.isEmpty)
        await policy.accepted(domain: "example.com", paragraphs: 3, libraryVersion: m.termsLibrary?.version ?? 0)
        var waited = 0
        while m.consentLog.isEmpty && waited < 100 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        XCTAssertEqual(m.consentLog.map(\.domain), ["example.com"])
        XCTAssertEqual(m.consentLog.first?.paragraphs, 3)
        m.flushSaves()
        let again = AppModel(store: HouseholdStore(url: url, keys: keys), defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        XCTAssertEqual(again.consentLog.map(\.domain), ["example.com"], "kept on the phone")
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

    /// An update that brings a new terms list asks a person who answered an earlier one, the first time the app is opened: Accept turns it on for the new
    /// list; Deny turns it off and is not asked again until another list ships. Someone who never answered is not asked.
    func testANewTermsListAfterAnUpdateIsAskedOnceWithAcceptOrDeny() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys = FixedKey()
        func opened(version: Int) throws -> AppModel {
            var c = try Catalog.contents(of: try XCTUnwrap(AppCatalog.url))
            c.termsLibrary = TermsLibrary(version: version, paragraphs: [TermsParagraph(hash: "aaaa", sites: 2, kinds: ["terms"], flags: [], prefix: "x", reviewed: true, verdict: "ok")])
            return AppModel(store: HouseholdStore(url: url, keys: keys), contents: c, defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
        }
        let first = try opened(version: 1)
        XCTAssertFalse(first.termsNeedAnswer, "never answered: not asked")
        first.approveTerms(); first.flushSaves()
        XCTAssertFalse(first.termsNeedAnswer, "answered for this list")

        let updated = try opened(version: 2)
        XCTAssertFalse(updated.termsActive, "an approval covers its own list only")
        XCTAssertTrue(updated.termsNeedAnswer, "the update's list is asked about")
        updated.approveTerms()
        XCTAssertTrue(updated.termsActive); XCTAssertFalse(updated.termsNeedAnswer, "Accept: on for the new list")
        updated.flushSaves()

        let again = try opened(version: 3)
        XCTAssertTrue(again.termsNeedAnswer)
        again.declineTerms(); again.flushSaves()
        XCTAssertFalse(again.termsActive); XCTAssertNil(again.makeTermsPolicy(), "Deny: nothing is accepted")
        XCTAssertFalse(again.termsNeedAnswer, "and not asked again for this list")
        XCTAssertFalse(try opened(version: 3).termsNeedAnswer, "nor when the app is opened again")
        XCTAssertTrue(try opened(version: 4).termsNeedAnswer, "a later list is asked about")
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
