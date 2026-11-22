import XCTest
import OptOutKitCore
@testable import AssistedRunLogic

/// The sample of sites the integration tests run the automatic run over for a release (the weekly job runs every site): small, the same every time, and some of
/// every kind of site rather than the first few.
final class SiteSampleTests: XCTestCase {
    private func sites() throws -> [DirectoryEntry] { try Catalog.contents(of: try XCTUnwrap(AppCatalog.url)).sites }

    func testTheSampleIsTheRequestedSizeAndTheSameEveryTime() throws {
        _ = AppCatalog.ensureOpen()
        let all = try sites()
        let a = SiteSample.pick(all, count: 40), b = SiteSample.pick(all.reversed(), count: 40)
        XCTAssertEqual(a.count, 40)
        XCTAssertEqual(a.map(\.id), b.map(\.id), "the order of the directory does not change it")
        XCTAssertEqual(Set(a.map(\.id)).count, 40, "no site twice")
        XCTAssertTrue(a.allSatisfy { $0.optOutForm != nil || $0.liveForm?.found == true }, "only sites with a form")
    }

    func testEveryKindOfSiteIsInTheSampleBeforeAnyIsInItTwice() throws {
        _ = AppCatalog.ensureOpen()
        let all = try sites().filter { $0.optOutForm != nil || $0.liveForm?.found == true }
        let kinds = Set(all.map(SiteSample.kind))
        XCTAssertGreaterThan(kinds.count, 3, "the real directory has several kinds of site")
        let sample = SiteSample.pick(all, count: kinds.count)
        XCTAssertEqual(Set(sample.map(SiteSample.kind)), kinds, "one of each kind")
        let first = SiteSample.pick(all, count: 25)
        XCTAssertGreaterThan(Set(first.map(SiteSample.kind)).count, 5, "the first 25 are spread over the kinds, not the first sites of the list")
    }

    func testASampleLargerThanTheDirectoryIsTheWholeDirectory() throws {
        _ = AppCatalog.ensureOpen()
        let few = Array(try sites().filter { $0.optOutForm != nil }.prefix(5))
        XCTAssertEqual(Set(SiteSample.pick(few, count: 40).map(\.id)), Set(few.map(\.id)))
        XCTAssertTrue(SiteSample.pick(few, count: 0).isEmpty)
    }
}
