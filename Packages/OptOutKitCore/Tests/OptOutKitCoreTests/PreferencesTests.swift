import XCTest
@testable import OptOutKitCore

/// The preferences kept as rows of the app's database (`StoredPreferences`), and the move from `UserDefaults`.
final class PreferencesTests: XCTestCase {
    private var url: URL!

    override func setUp() { url = FileManager.default.temporaryDirectory.appendingPathComponent("ook-prefs-\(UUID()).sqlite") }
    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    private func prefs() -> StoredPreferences { StoredPreferences(database: UserDatabase(url: url)) }

    func testEveryKindOfValueComesBackAsItWentInAndSurvivesARelaunch() {
        let p = prefs()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        p.set(true, forKey: "flag"); p.set(7, forKey: "count"); p.set(2.5, forKey: "ratio"); p.set("fr", forKey: "appLanguage")
        p.set(date, forKey: "when"); p.set(Data([1, 2]), forKey: "blob"); p.set(["a", "b"], forKey: "list"); p.set(["x": 1], forKey: "map")
        for q in [p, prefs()] {          // the same connection, then a new one as after a relaunch
            XCTAssertTrue(q.bool(forKey: "flag")); XCTAssertEqual(q.integer(forKey: "count"), 7); XCTAssertEqual(q.double(forKey: "ratio"), 2.5)
            XCTAssertEqual(q.string(forKey: "appLanguage"), "fr"); XCTAssertEqual(q.object(forKey: "when") as? Date, date)
            XCTAssertEqual(q.data(forKey: "blob"), Data([1, 2])); XCTAssertEqual(q.array(forKey: "list") as? [String], ["a", "b"])
            XCTAssertEqual((q.object(forKey: "map") as? [String: Int]), ["x": 1])
        }
        XCTAssertFalse(prefs().bool(forKey: "missing")); XCTAssertNil(prefs().string(forKey: "missing")); XCTAssertEqual(prefs().integer(forKey: "missing"), 0)
    }

    func testAValueIsReplacedAndRemoved() {
        let p = prefs()
        p.set("a", forKey: "k"); p.set("b", forKey: "k"); XCTAssertEqual(prefs().string(forKey: "k"), "b")
        p.removeObject(forKey: "k"); XCTAssertNil(prefs().object(forKey: "k"))
        p.set("c", forKey: "k"); p.set(nil, forKey: "k"); XCTAssertNil(prefs().object(forKey: "k"), "setting nil removes it, as UserDefaults does")
    }

    /// While the phone is locked the database cannot be opened: the preferences work in memory and are written at the unlock; what was stored comes in too.
    func testWhileTheDatabaseCannotBeOpenedPreferencesWorkInMemoryAndAreWrittenAtTheUnlock() throws {
        let first = prefs(); first.set("stored", forKey: "kept")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let locked = StoredPreferences(database: UserDatabase(url: url))
        XCTAssertNil(locked.string(forKey: "kept"), "not readable yet")
        locked.set("later", forKey: "new")
        XCTAssertEqual(locked.string(forKey: "new"), "later", "usable meanwhile")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        locked.reload()
        XCTAssertEqual(locked.string(forKey: "kept"), "stored", "what was stored comes in at the unlock")
        XCTAssertEqual(prefs().string(forKey: "new"), "later", "and what was set meanwhile is written")
    }

    func testPreferencesAreNotSealedButHoldNothingPersonal() throws {
        let p = prefs(); p.set("fr", forKey: "appLanguage")
        XCTAssertNotNil(try Data(contentsOf: url).range(of: Data("appLanguage".utf8)), "plain rows: the app reads them while the phone is locked, before the Keychain key is available")
    }

    // MARK: The move from UserDefaults

    func testTheOldUserDefaultsValuesAreMovedInAndRemovedOnlyOnceStored() throws {
        let suite = "ook.legacy.\(UUID())"
        let old = try XCTUnwrap(UserDefaults(suiteName: suite))
        old.set("fr", forKey: "appLanguage"); old.set(true, forKey: "setup.profile.done"); old.set(Date(timeIntervalSince1970: 5), forKey: "reminders.firstLaunch")
        old.set(3, forKey: "daily.batches"); old.set(["a"], forKey: "daily.themes")
        let p = prefs()
        p.set("already", forKey: "daily.batches")          // set here first: it is newer, kept
        let moved = p.importLegacy(from: old, domain: suite)
        XCTAssertEqual(moved, 5)
        for key in ["appLanguage", "setup.profile.done", "reminders.firstLaunch", "daily.themes"] { XCTAssertNil(old.persistentDomain(forName: suite)?[key], "\(key) is gone from UserDefaults") }
        let again = prefs()
        XCTAssertEqual(again.string(forKey: "appLanguage"), "fr"); XCTAssertTrue(again.bool(forKey: "setup.profile.done"))
        XCTAssertEqual(again.object(forKey: "reminders.firstLaunch") as? Date, Date(timeIntervalSince1970: 5))
        XCTAssertEqual(again.array(forKey: "daily.themes") as? [String], ["a"])
        XCTAssertEqual(again.string(forKey: "daily.batches"), "already", "a value already here wins")
        old.removePersistentDomain(forName: suite)
    }

    /// Nothing is removed from UserDefaults unless it is safely in the database: when the database is not open yet, the old values stay where they are.
    func testNothingIsRemovedFromUserDefaultsWhileTheDatabaseCannotBeWritten() throws {
        _ = prefs()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let suite = "ook.legacy.\(UUID())"
        let old = try XCTUnwrap(UserDefaults(suiteName: suite)); old.set("fr", forKey: "appLanguage")
        let p = StoredPreferences(database: UserDatabase(url: url))
        XCTAssertEqual(p.importLegacy(from: old, domain: suite), 0)
        XCTAssertEqual(old.string(forKey: "appLanguage"), "fr", "still in UserDefaults")
        old.removePersistentDomain(forName: suite)
    }
}
