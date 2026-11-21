import XCTest
import OptOutKitCore
@testable import OptOutKit

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
final class TermsAcceptanceTests: XCTestCase {
    func testPressesIAgreeOnlyWhenThePolicySaysAccept() async throws {
        let policy = RecordingPolicy(.accept(paragraphs: 2, libraryVersion: 7))
        let page = try await WebViewFetcher(maxWait: 8, termsPolicy: policy).render(html: gatePage, domain: "alabamaarrests.org")
        XCTAssertTrue(page.text.contains("Search results: Pat Example"), "got: \(page.text)")
        XCTAssertFalse(page.text.contains(Rechecker.termsGateMarker))
        XCTAssertFalse(page.text.contains("COOKIE BUTTON CLICKED"), "the cookie banner must never be pressed")
        XCTAssertEqual(policy.acceptedCalls, ["alabamaarrests.org"])
        XCTAssertTrue(policy.seenPrompt.contains("lawful purposes only"))
    }

    func testEveryOtherDecisionLeavesThePromptAloneAndReportsIt() async throws {
        for decision: TermsDecision in [.notApproved(paragraphs: 2), .unreviewed(count: 1), .excluded(flags: ["automation"]), .nothingToJudge] {
            let policy = RecordingPolicy(decision)
            let page = try await WebViewFetcher(maxWait: 6, termsPolicy: policy).render(html: gatePage, domain: "alabamaarrests.org")
            XCTAssertTrue(page.text.contains("Waiting for terms"), "button must not be pressed for \(decision)")
            XCTAssertTrue(page.text.contains(Rechecker.termsGateMarker), "gate must be reported for \(decision)")
            XCTAssertTrue(policy.acceptedCalls.isEmpty)
        }
    }

    func testWithNoPolicyAPromptIsNeverAccepted() async throws {
        let page = try await WebViewFetcher(maxWait: 6).render(html: gatePage, domain: "alabamaarrests.org")
        XCTAssertTrue(page.text.contains("Waiting for terms"))
        XCTAssertTrue(page.text.contains(Rechecker.termsGateMarker))
    }

    func testAPageWithNoTermsPromptIsUntouched() async throws {
        let policy = RecordingPolicy(.accept(paragraphs: 1, libraryVersion: 1))
        let page = try await WebViewFetcher(maxWait: 5, termsPolicy: policy).render(html: "<body>Plain results page, nothing to agree to.</body>")
        XCTAssertFalse(page.text.contains(Rechecker.termsGateMarker))
        XCTAssertTrue(policy.acceptedCalls.isEmpty)
    }

    /// End to end with the real rules: the page's own paragraphs, reviewed and approved, are accepted; change one and they are not.
    func testRealRulesAcceptReviewedParagraphsAndRejectAnyNewOne() async throws {
        let domain = "alabamaarrests.org"
        let paragraphs = [
            "ACCEPTABLE USE POLICY AND TERMS. This website is a private site that is not affiliated with any government agency or official source.",
            "You agree to use the information on this site for lawful purposes only and not to harass or stalk anyone at any time whatsoever.",
        ]
        func library(reviewed: Bool, flags: [String] = []) -> TermsLibrary {
            TermsLibrary(version: 3, paragraphs: paragraphs.map {
                TermsParagraph(hash: TermsText.hash(ofCanonical: TermsText.canonical($0, domain: domain)), sites: 2, kinds: ["prompt"],
                               flags: flags, prefix: "", reviewed: reviewed, verdict: reviewed ? "ok" : nil)
            })
        }
        let box = LogBox()
        func policy(_ lib: TermsLibrary, approved: Bool) -> LibraryTermsPolicy {
            LibraryTermsPolicy(library: lib, approval: approved ? TermsApproval(libraryVersion: 3) : nil) { box.entries.append($0) }
        }
        // reviewed and approved: accepted, and logged
        var page = try await WebViewFetcher(maxWait: 8, termsPolicy: policy(library(reviewed: true), approved: true)).render(html: gatePage, domain: domain)
        XCTAssertTrue(page.text.contains("Search results: Pat Example"), "got: \(page.text)")
        XCTAssertEqual(box.entries.map(\.domain), [domain])
        // not approved by the person: left alone
        page = try await WebViewFetcher(maxWait: 6, termsPolicy: policy(library(reviewed: true), approved: false)).render(html: gatePage, domain: domain)
        XCTAssertTrue(page.text.contains(Rechecker.termsGateMarker))
        // not yet reviewed by a person: left alone
        page = try await WebViewFetcher(maxWait: 6, termsPolicy: policy(library(reviewed: false), approved: true)).render(html: gatePage, domain: domain)
        XCTAssertTrue(page.text.contains(Rechecker.termsGateMarker))
        // a clause that implies automation: never accepted, even though a reviewer said ok
        page = try await WebViewFetcher(maxWait: 6, termsPolicy: policy(library(reviewed: true, flags: ["automation"]), approved: true)).render(html: gatePage, domain: domain)
        XCTAssertTrue(page.text.contains(Rechecker.termsGateMarker))
        // the site adds a clause nobody reviewed: left alone
        let changed = gatePage.replacingOccurrences(of: "at any time whatsoever.", with: "at any time whatsoever and you agree to pay a monthly subscription fee for every search.")
        page = try await WebViewFetcher(maxWait: 6, termsPolicy: policy(library(reviewed: true), approved: true)).render(html: changed, domain: domain)
        XCTAssertTrue(page.text.contains(Rechecker.termsGateMarker), "a changed paragraph must stop acceptance")
        XCTAssertEqual(box.entries.count, 1, "only the first case was accepted")
    }

    // MARK: the page the person is working on (Solve and send)

    /// A page whose prompt goes away when "I Agree" is pressed, as on a real site.
    private let vanishingGate = gatePage.replacingOccurrences(of: "<button id=\"agree\" onclick=\"", with: "<button id=\"agree\" onclick=\"document.getElementById('gate').remove();")

    private func liveBlockers(_ policy: TermsPolicy?, html: String? = nil) async throws -> [AssistedBlocker] {
        let session = WebViewSession.make(); defer { session.close() }
        try await session.loadHTML(html ?? gatePage)
        let page = WebAssistedPage(session: session, plan: FillPlan(values: [], verdict: .ready))
        page.termsPolicy = policy
        return await page.blockers()
    }

    func testTheSolveAndSendPageAcceptsAPromptOnlyWhenThePolicySaysAccept() async throws {
        let accepting = RecordingPolicy(.accept(paragraphs: 2, libraryVersion: 7))
        let blockers = try await liveBlockers(accepting, html: vanishingGate)
        XCTAssertFalse(blockers.contains(.terms), "the prompt was accepted, so nothing is left for the person")
        XCTAssertEqual(accepting.acceptedCalls.count, 1, "and it was logged once")
    }

    func testTheSolveAndSendPageLeavesThePromptToThePersonInEveryOtherCase() async throws {
        for decision: TermsDecision in [.notApproved(paragraphs: 2), .unreviewed(count: 1), .excluded(flags: ["automation"]), .nothingToJudge] {
            let policy = RecordingPolicy(decision)
            let blockers = try await liveBlockers(policy)
            XCTAssertTrue(blockers.contains(.terms), "\(decision) leaves the prompt for the person")
            XCTAssertTrue(policy.acceptedCalls.isEmpty)
        }
        let none = try await liveBlockers(nil)
        XCTAssertTrue(none.contains(.terms), "with the setting off the person always accepts")
    }
}

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
