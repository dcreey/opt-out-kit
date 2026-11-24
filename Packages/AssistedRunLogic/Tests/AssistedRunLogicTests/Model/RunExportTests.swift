import XCTest
import OptOutKitCore
@testable import AssistedRunLogic

/// The run export (Activity page, "Export this run"): one zip with run.json, a README and the screenshot of each site that kept one, in the page's order.
@MainActor
final class RunExportTests: XCTestCase {
    private func model() -> AppModel {
        AppModel(store: HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-\(UUID()).sealed"), keys: FixedKey()),
                 defaults: UserDefaults(suiteName: "ook.test.\(UUID())")!)
    }

    /// Every site of the page is in run.json with its group, its line and its attempts; a site with a screenshot names it and the picture is in the archive
    /// byte for byte; the sites that need the person come first.
    func testTheExportListsEverySiteWithItsAttemptsAndCarriesItsScreenshot() async throws {
        let m = model()
        var me = try XCTUnwrap(m.selectedPerson)
        me.names = [NameEntry(kind: .legal, name: "Pat Example")]; me.birthdate = "1985-03-14"; me.emails = ["pat@example.com"]
        me.addresses = [Address(street: "1 Main St", city: "Springfield", state: "IL", zip: "62701")]
        m.update(me); m.setContactEmail("pat@example.com")
        let ids = m.automaticSites(for: me).prefix(2).map(\.id)
        XCTAssertEqual(ids.count, 2)
        let (sent, stopped) = (ids[0], ids[1])
        m.setRunStartedForTesting(Date().addingTimeInterval(-600))
        m.recordAttemptForTesting(OptOutAttempt(date: Date().addingTimeInterval(-300), outcome: "submitted", pageSaid: "Thank you, your request was received"), site: sent)
        m.recordAttemptForTesting(OptOutAttempt(date: Date().addingTimeInterval(-200), outcome: "challenged", detail: "a Cloudflare check"), site: stopped)
        let picture = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 0xFF, 0xD9])
        try m.evidence.save(picture, person: me.id, site: stopped)

        let rows = m.activityRows(for: me)
        let files = m.runExportFiles(for: me, rows: rows)
        XCTAssertEqual(Array(files.map(\.name).prefix(2)), ["run.json", "README.txt"])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(RunExport.self, from: try XCTUnwrap(files.first?.data))
        XCTAssertEqual(export.sites.count, rows.count)
        XCTAssertEqual(export.sites.map(\.n), Array(1...rows.count))

        let s = try XCTUnwrap(export.sites.first { $0.id == stopped })
        XCTAssertEqual(s.n, 1, "a site that needs the person comes first")
        XCTAssertEqual(s.group, "needsYou")
        XCTAssertEqual(s.attempts.map(\.outcome), ["challenged"])
        XCTAssertEqual(s.attempts.first?.detail, "a Cloudflare check")
        let shot = try XCTUnwrap(s.screenshot)
        XCTAssertTrue(shot.hasPrefix("001-") && shot.hasSuffix(".jpg"), shot)
        XCTAssertEqual(files.first { $0.name == shot }?.data, picture)

        let t = try XCTUnwrap(export.sites.first { $0.id == sent })
        XCTAssertEqual(t.group, "sent")
        XCTAssertEqual(t.attempts.first?.pageSaid, "Thank you, your request was received")
        XCTAssertNil(t.screenshot)
        XCTAssertEqual(files.count, 3, "run.json, the README and the one screenshot")
        XCTAssertEqual(export.counts["sent"], 1)
        XCTAssertEqual(export.counts["needsYou"], 1)

        // The whole archive is a zip whose central directory lists the same files.
        let zip = await m.runExport(for: me)
        XCTAssertEqual(zip.prefix(4), Data([0x50, 0x4B, 0x03, 0x04]))
        XCTAssertNotNil(zip.range(of: Data(shot.utf8)))
    }
}
