import XCTest
@testable import OptOutKitCore

final class L10nTests: XCTestCase {
    override func tearDown() { L10n.language = "en" }

    func testEnglishIsTheDefaultAndTheKey() {
        XCTAssertEqual(L10n.language, "en")
        XCTAssertEqual(OptOutMethod.automatic.title, "Automatic opt-out")
    }

    func testTheCorePackageSpeaksFrenchSpanishAndGerman() {
        L10n.language = "fr"; XCTAssertEqual(OptOutMethod.automatic.title, "Retrait automatique")
        L10n.language = "es"; XCTAssertEqual(OptOutMethod.automatic.title, "Baja automática")
        L10n.language = "de"; XCTAssertEqual(OptOutMethod.automatic.title, "Automatischer Opt-out")
    }

    func testAnUnknownLanguageFallsBackToEnglish() {
        L10n.language = "xx"
        XCTAssertEqual(OptOutMethod.automatic.title, "Automatic opt-out")
    }

    func testPlaceholdersAreFilledInOrderAndTranslationsMayReorderThem() {
        XCTAssertEqual(L10n.f("Step %@ of %@", 2, 5), "Step 2 of 5")
        L10n.language = "fr"
        XCTAssertEqual(L10n.f("Step %@ of %@", 2, 5), "Étape 2 sur 5")
        L10n.language = "de"
        XCTAssertEqual(L10n.f("Covered by %@ until %@", "California DROP", "Jan 20"), "Abgedeckt von California DROP bis Jan 20")
    }

    func testAStatesLawIsToldInTheChosenLanguage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let js = try JurisdictionLoader.load(directory: root.appendingPathComponent("jurisdictions"))
        let ps = try PlatformLoader.load(directory: root.appendingPathComponent("platforms"))
        let summary = JurisdictionLoader.loadSummary(root.appendingPathComponent("registries/summary.json"))
        L10n.language = "fr"
        let ca = try XCTUnwrap(js.first { $0.id == "us-ca" }).statements(summary: summary, platforms: ps, others: js).map(\.text)
        XCTAssertTrue(ca[0].hasPrefix("Californie exige que les courtiers en données s'enregistrent"), ca[0])
        L10n.language = "de"
        let tx = try XCTUnwrap(js.first { $0.id == "us-tx" }).statements(summary: summary, platforms: ps, others: js).map(\.text)
        XCTAssertTrue(tx[0].hasPrefix("Texas verlangt, dass sich Datenbroker registrieren"), tx[0])
    }

    func testEveryKeyInTheCoreCatalogHasAllThreeTranslations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Packages/OptOutKitCore/Sources/OptOutKitCore/Resources/Localizable.xcstrings"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: [String: Any]])
        XCTAssertGreaterThan(strings.count, 150)
        for (key, entry) in strings {
            let loc = (entry["localizations"] as? [String: Any]) ?? [:]
            XCTAssertEqual(Set(loc.keys), ["fr", "es", "de"], "missing translation for: \(key)")
        }
    }
}

final class L10nSafetyTests: XCTestCase {
    func testAPlaceholderWithoutAnArgumentNeverCrashes() {
        XCTAssertEqual(L10n.f("Step %@ of %@", 2), "Step 2 of ")
        XCTAssertEqual(L10n.f("Step %@ of %@"), "Step  of ")
        XCTAssertEqual(L10n.f("Step %lld of %lld", "x"), "Step 0 of 0", "a number placeholder given text is zero, not a crash")
        XCTAssertEqual(L10n.f("Step %@ of %@", 1, 2, 3), "Step 1 of 2", "extra arguments are ignored")
    }
}
