import XCTest
@testable import OptOutKitCore

/// `SiteIndex`: how the app finds one site among all of them, without scanning the list.
final class SiteIndexTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// On the real sites, every lookup gives what scanning the list gave: by id, by domain, the size of a family.
    func testEveryLookupGivesWhatScanningTheListGave() throws {
        let all = try Registry.loadDirectory(Self.repository.appendingPathComponent("directory"))
        let index = SiteIndex(all)
        for e in all {
            XCTAssertEqual(index[id: e.id], all.first { $0.id == e.id })
            XCTAssertEqual(index[domain: e.domain], all.first { $0.domain == e.domain })
            XCTAssertEqual(index.familySize(of: e), Directory.familySize(of: e, in: all), e.domain)
        }
        XCTAssertNil(index[id: "no_such_site"]); XCTAssertNil(index[domain: "no-such-site.example"])
        let some = all.prefix(5).map(\.domain).reversed()
        XCTAssertEqual(index.entries(domains: Array(some) + ["no-such-site.example"]).map(\.domain), Array(some), "in the order asked, unknown ones left out")
    }

    func testAFamilyIsCountedAndARepeatedIDKeepsTheFirst() {
        var a = DirectoryEntry(id: "a", domain: "a.example", name: "A", bucket: "direct", tier: .B, automation: .guided, optOutURL: nil, optOutForm: nil, signals: [])
        a.family = "f"
        var b = a; b.id = "b"; b.domain = "b.example"
        var again = a; again.name = "Second A"
        let index = SiteIndex([a, b, again])
        XCTAssertEqual(index.familySize(of: a), 3)
        XCTAssertEqual(index[id: "a"]?.name, "A", "the first entry wins, as first(where:) did")
        var alone = a; alone.family = nil
        XCTAssertEqual(index.familySize(of: alone), 1)
    }
}
