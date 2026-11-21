import XCTest
import CatalogSource
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

    /// An optional value must never reach a sentence ("in effect since Optional(\"2020-01-01\")").
    func testNoPlaceTellsItsLawWithAnOptionalInTheText() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let js = try JurisdictionLoader.load(directory: root.appendingPathComponent("jurisdictions"))
        let ps = try PlatformLoader.load(directory: root.appendingPathComponent("platforms"))
        let summary = JurisdictionLoader.loadSummary(root.appendingPathComponent("registries/summary.json"))
        L10n.language = "en"
        for j in js { for line in j.statements(summary: summary, platforms: ps, others: js).map(\.text) {
            XCTAssertFalse(line.contains("Optional("), "\(j.id): \(line)")
        } }
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

final class RemindersTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func day(_ d: Int, hour: Int = 9) -> Date { cal.date(from: DateComponents(year: 2026, month: 1, day: d, hour: hour))! }

    func testEachMissStageFiresOnceOnItsOwnDay() {
        let plan = Reminders.plan(lastActive: day(1), streak: 4, target: .people_search, now: day(1), calendar: cal)
        XCTAssertEqual(plan.prefix(4).map(\.stage), [.streak, .threeDays, .week, .month])
        XCTAssertEqual(plan.prefix(4).map { cal.dateComponents([.month, .day], from: $0.fireDate) }.map { "\($0.month!)-\($0.day!)" },
                       ["1-2", "1-4", "1-8", "1-31"])
        for p in plan {
            let t = cal.dateComponents([.hour, .minute], from: p.fireDate)
            XCTAssertEqual(t.hour, 8, "reminders arrive in the morning")
            XCTAssertTrue((1...15).contains(t.minute!), "between 8:01 and 8:15, got \(t.minute!)")
        }
        let again = Reminders.plan(lastActive: day(1), streak: 4, target: .people_search, now: day(1, hour: 10), calendar: cal)
        XCTAssertEqual(plan.map(\.fireDate), again.map(\.fireDate), "replanning does not move a reminder")
        XCTAssertGreaterThan(Set(plan.map { cal.component(.minute, from: $0.fireDate) }).count, 1, "the minutes are spread, not all the same")
        XCTAssertEqual(Set(plan.map(\.id)).count, plan.count, "every reminder has its own id, so none repeats")
        XCTAssertEqual(plan.filter { $0.stage == .threeDays }.count, 1, "the 3-day miss is not repeated every 3 days")
    }

    /// Opted out at 21:00; the next morning's reminder is about eleven hours later, never skipped to a later day.
    func testAnOptOutAtNineInTheEveningStillGetsTheNextMorningsReminder() throws {
        let night = day(1, hour: 21)
        let plan = Reminders.plan(lastActive: night, streak: 1, target: nil, now: night, calendar: cal)
        let first = try XCTUnwrap(plan.first)
        XCTAssertEqual(first.stage, .streak)
        let hours = first.fireDate.timeIntervalSince(night) / 3600
        XCTAssertTrue(hours > 10.9 && hours < 11.3, "\(hours) hours")
    }

    func testAfterTheFirstMonthItRepeatsMonthlyAndNeverMoreOftenThanThat() {
        let plan = Reminders.plan(lastActive: day(1), streak: 1, target: nil, now: day(1), calendar: cal, monthlyRepeats: 3)
        let months = plan.filter { $0.stage == .month }.map(\.fireDate)
        XCTAssertEqual(months.count, 4)
        for (a, b) in zip(months, months.dropFirst()) { XCTAssertEqual(cal.dateComponents([.day], from: cal.startOfDay(for: a), to: cal.startOfDay(for: b)).day, 30) }
    }

    func testAnotherOptOutRestartsTheCycleAndPastDatesAreNeverFiredLate() {
        let first = Reminders.plan(lastActive: day(1), streak: 1, target: nil, now: day(1), calendar: cal)
        let later = Reminders.plan(lastActive: day(5), streak: 1, target: nil, now: day(5), calendar: cal)
        XCTAssertTrue(later.first!.fireDate > first.first!.fireDate)
        let missed = Reminders.plan(lastActive: day(1), streak: 0, target: nil, now: day(9), calendar: cal)
        XCTAssertEqual(missed.first?.stage, .month, "the day, 3-day and week nudges are past; none is sent late")
    }

    func testTheStreakNudgeNeedsAStreakAndMessagesAreShortAndNameTheTarget() {
        XCTAssertNil(Reminders.plan(lastActive: day(1), streak: 0, target: nil, now: day(1), calendar: cal).first { $0.stage == .streak })
        for p in Reminders.plan(lastActive: day(1), streak: 3, target: .people_search, now: day(1), calendar: cal) {
            XCTAssertTrue(p.body.contains("People search"), p.body)
            XCTAssertTrue(p.body.contains("strangers can look up your home address"), p.body)
            XCTAssertLessThan(p.body.count, 130, p.body)
        }
    }
}

/// What "My data" in the … menu offers, in every flow.
final class DetailChoicesTests: XCTestCase {
    func testEveryDetailOfThePersonIsOfferedOnceInTheOrderAPersonLooksForIt() {
        var p = Person(displayName: "Sam", names: [NameEntry(kind: .legal, name: "Sam Q Rivera"), NameEntry(kind: .nickname, name: "Sammy"), NameEntry(kind: .maiden, name: "sammy")],
                       addresses: [Address(street: "1 Main St", city: "Austin", state: "TX", zip: "78701"), Address(city: "Dallas", state: "TX")],
                       emails: ["sam@example.com", "SAM@example.com", "work@example.com"], phones: ["555-0100"], birthdate: "1990-04-09")
        p.confirmsOwnIdentity = true
        let groups = DetailChoices.groups(for: p, email: "forms@example.com")
        XCTAssertEqual(groups.map(\.kind), [.name, .email, .phone, .address, .birthdate, .law])
        XCTAssertEqual(groups[0].values, ["Sam Q Rivera"])
        XCTAssertEqual(groups[1].values, ["forms@example.com", "sam@example.com", "work@example.com"])
        XCTAssertEqual(groups[2].values, ["555-0100"])
        XCTAssertEqual(groups[3].values, ["1 Main St, Austin, TX 78701", "Dallas, TX"])
        XCTAssertEqual(groups[4].values, ["04/09/1990"])
        XCTAssertEqual(groups[5].values, [FormFiller.legalBasis(for: p)], "the applicable law is exactly the sentence the app types into a box that asks for it")
        XCTAssertTrue(groups[5].values[0].contains("California Consumer Privacy Act"))
    }

    func testAProfileWithLittleOnlyOffersWhatItHas() {
        let groups = DetailChoices.groups(for: Person(displayName: "Alex", names: []))
        XCTAssertEqual(groups.map(\.kind), [.name, .law])
        XCTAssertEqual(groups[0].values, ["Alex"])
    }
}
