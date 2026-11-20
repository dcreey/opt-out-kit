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
        guard case .known = LinkCheck.check(URL(string: "https://app.privacyportal.net/confirm")!, entries: es, attempts: [:]) else { return XCTFail("the link was not read as expected") }
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
        guard case .known(_, _, let done, _) = r else { return XCTFail("the link was not read as expected") }
        XCTAssertEqual(done, day)
    }

    // MARK: Links that point at a provider many sites share

    private func tenant(_ d: String, host: String, name: String? = nil) -> DirectoryEntry {
        var e = entry(d, optOut: "https://\(host)/webform")
        e.name = name ?? d
        return e
    }

    func testALinkOnASharedProviderDomainIsNotGuessedBetweenSites() {
        let es = [tenant("acme.com", host: "acme-privacy.my.onetrust.com"), tenant("blackbaud.com", host: "blackbaud-privacy.my.onetrust.com"), tenant("cybba.com", host: "cybba-requests.my.onetrust.com")]
        // The generic portal host names no tenant: the person chooses, whichever site happens to come first.
        guard case .shared(let host, let ids) = LinkCheck.check(URL(string: "https://privacyportal.onetrust.com/webform/1/2")!, entries: es, attempts: [:]) else { return XCTFail("the link was not read as expected") }
        XCTAssertEqual(host, "privacyportal.onetrust.com")
        XCTAssertEqual(Set(ids), ["acme_com", "blackbaud_com", "cybba_com"])
    }

    func testATenantsOwnAddressPicksThatSiteAndNoOtherOnTheProvider() {
        let es = [tenant("acme.com", host: "acme-privacy.my.onetrust.com"), tenant("blackbaud.com", host: "blackbaud-privacy.my.onetrust.com")]
        guard case .known(let id, _, _, _) = LinkCheck.check(URL(string: "https://blackbaud-privacy.my.onetrust.com/webform/x")!, entries: es, attempts: [:]) else { return XCTFail("the link was not read as expected") }
        XCTAssertEqual(id, "blackbaud_com")
    }

    /// Found in the real directory: one site records its page under the provider's general address, which made every OneTrust link look like that site.
    func testAProvidersGeneralAddressIsNotThatOneSitesEvenWhenItIsRecordedThere() {
        let es = [tenant("acme.com", host: "privacyportal.onetrust.com"), tenant("blackbaud.com", host: "blackbaud-privacy.my.onetrust.com")]
        guard case .shared(_, let ids) = LinkCheck.check(URL(string: "https://privacyportal.onetrust.com/webform/1/2")!, entries: es, attempts: [:]) else { return XCTFail("a general address is not guessed") }
        XCTAssertEqual(ids, ["acme_com", "blackbaud_com"], "the site recorded at that address is listed first, the other stays available")
    }

    func testSitesWaitingOnAnEmailAreSuggestedFirst() {
        let es = [tenant("acme.com", host: "a.my.onetrust.com"), tenant("blackbaud.com", host: "b.my.onetrust.com"), tenant("cybba.com", host: "c.my.onetrust.com")]
        let waiting = ["cybba_com": [OptOutAttempt(date: day, outcome: "submitted_email")]]
        guard case .shared(_, let ids) = LinkCheck.check(URL(string: "https://privacyportal.onetrust.com/x")!, entries: es, attempts: waiting) else { return XCTFail("the link was not read as expected") }
        XCTAssertEqual(ids.first, "cybba_com", "the site that is waiting on an email is the likeliest")
        XCTAssertEqual(ids.count, 3, "the others stay available")
    }

    func testSisterSitesThatShareOneAddressAreAskedAboutWithTheMainSiteAheadOfThem() {
        let es = [tenant("neighbor.example", host: "www.beenverified.com", name: "Neighbor Report"), entry("beenverified.com")]
        guard case .shared(_, let ids) = LinkCheck.check(URL(string: "https://www.beenverified.com/app/optout")!, entries: es, attempts: [:]) else { return XCTFail("the link was not read as expected") }
        XCTAssertEqual(ids, ["beenverified_com", "neighbor_example"])
    }

    func testAChosenSiteIsOnlyTrustedWithALinkAddressItIsKnownBy() {
        let acme = tenant("acme.com", host: "acme-privacy.my.onetrust.com")
        XCTAssertTrue(LinkCheck.verifies(URL(string: "https://privacyportal.onetrust.com/x")!, for: acme), "the provider the site uses")
        XCTAssertTrue(LinkCheck.verifies(URL(string: "https://app.acme.com/confirm")!, for: acme))
        XCTAssertFalse(LinkCheck.verifies(URL(string: "https://evil.example/confirm")!, for: acme), "a site picked by hand for a stranger's address is never filled in or sent for them")
    }

    func testTheSearchFindsSitesByNameOrDomainWithPrefixMatchesFirst() {
        var a = entry("spokeo.com"); a.name = "Spokeo"
        var b = entry("truepeoplesearch.com"); b.name = "TruePeopleSearch"
        var c = entry("peoplefinders.com"); c.name = "PeopleFinders"
        var d = entry("fastpeoplesearch.com"); d.name = "Fast People Search"
        let found = LinkCheck.find("people", in: [a, b, c, d, entry("zzz.com")])
        XCTAssertEqual(found.map(\.id), ["peoplefinders_com", "fastpeoplesearch_com", "truepeoplesearch_com"], "starts-with, then a word that starts with it, then contains it")
        XCTAssertTrue(LinkCheck.find("  ", in: [a]).isEmpty)
        XCTAssertEqual(LinkCheck.find("SPOK", in: [a, b]).map(\.id), ["spokeo_com"])
    }
}
