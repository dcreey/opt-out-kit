import XCTest
@testable import OptOutKitCore

final class LinkCheckTests: XCTestCase {
    private func entry(_ d: String, optOut: String? = nil) -> DirectoryEntry {
        DirectoryEntry(id: d.replacingOccurrences(of: ".", with: "_"), domain: d, name: d, bucket: "direct", tier: nil, automation: .unknown, confidence: nil,
                       optOutURL: optOut.flatMap { URL(string: $0) }, optOutForm: nil, family: nil, familyParent: nil, template: nil, searchCheck: nil, signals: nil, profiled: nil)
    }
    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    func testASubdomainOfAKnownSiteMatchesItsPrimaryDomain() {
        let r = LinkCheck.check(URL(string: "https://privacy.liveintent.com/validate?x=1")!, entries: [entry("liveintent.com")], attempts: [:])
        guard case .known(let id, _, let done, let waiting) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(id, "liveintent_com"); XCTAssertNil(done); XCTAssertFalse(waiting)
    }

    func testALinkFromAnotherSiteIsUnknownAndALookalikeDoesNotMatch() {
        let es = [entry("liveintent.com")]
        XCTAssertEqual(LinkCheck.check(URL(string: "https://evil.example/validate")!, entries: es, attempts: [:]), .unknown(host: "evil.example"))
        XCTAssertEqual(LinkCheck.check(URL(string: "https://liveintent.com.evil.example/x")!, entries: es, attempts: [:]), .unknown(host: "liveintent.com.evil.example"))
    }

    func testAnOptOutPageOnAnotherHostCountsAsTheSite() {
        let es = [entry("acme.com", optOut: "https://privacyportal.net/acme")]
        guard case .known = LinkCheck.check(URL(string: "https://app.privacyportal.net/confirm")!, entries: es, attempts: [:]) else { return XCTFail() }
    }

    func testRegistrableDomainHandlesTwoPartSuffixes() {
        XCTAssertEqual(LinkCheck.registrable("a.b.example.co.uk"), "example.co.uk")
        XCTAssertEqual(LinkCheck.registrable("www.example.com"), "example.com")
    }

    func testASiteWaitingOnAnEmailIsPendingUntilTheEmailStepIsDone() {
        let sent = OptOutAttempt(date: day, outcome: "submitted_email")
        XCTAssertTrue(FollowUps.isPending([sent])); XCTAssertNil(FollowUps.completedOn([sent]))
        let done = [sent, OptOutAttempt(date: day.addingTimeInterval(60), outcome: "email_done")]
        XCTAssertFalse(FollowUps.isPending(done)); XCTAssertEqual(FollowUps.completedOn(done), day.addingTimeInterval(60))
        XCTAssertEqual(FollowUps.pending(["a": [sent], "b": done]).map(\.id), ["a"])
    }

    func testTheLinkCheckSaysWhenTheRequestWasAlreadyFinished() {
        let r = LinkCheck.check(URL(string: "https://liveintent.com/x")!, entries: [entry("liveintent.com")], attempts: ["liveintent_com": [OptOutAttempt(date: day, outcome: "submitted")]])
        guard case .known(_, _, let done, _) = r else { return XCTFail() }
        XCTAssertEqual(done, day)
    }
}
