import XCTest
import OptOutKitCore
@testable import OptOutKit

/// The app's preferences are rows of its database, and what an older build kept in UserDefaults is moved in the first time the model starts.
@MainActor
final class PreferencesAppTests: XCTestCase {
    private func databaseStore() -> HouseholdStore {
        HouseholdStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ook-prefs-\(UUID()).sqlite"), keys: FixedKey())
    }

    func testThePreferencesAreRowsOfTheHouseholdsDatabaseAndTheOldUserDefaultsValuesAreMovedIn() throws {
        let key = "zz.test.legacy.\(UUID().uuidString)"
        UserDefaults.standard.set(true, forKey: key)
        let store = databaseStore()
        let m = AppModel(store: store)          // no preferences handed in: the app's own
        XCTAssertNil(UserDefaults.standard.object(forKey: key), "gone from UserDefaults once stored")
        XCTAssertTrue(AppPreferences.current.bool(forKey: key), "and in the preferences")
        XCTAssertTrue(StoredPreferences(database: store.database).bool(forKey: key), "as a row of the database, found by a new connection")
        // What the model sets goes to the same place.
        AppPreferences.current.set("x", forKey: "zz.test.value"); XCTAssertEqual(StoredPreferences(database: store.database).string(forKey: "zz.test.value"), "x")
        _ = m
    }

    func testTheGuideFlagsAreKeptAsPreferences() {
        let p = MemoryPreferences(); AppPreferences.current = p
        p.set(true, forKey: "guide.collapsed")
        XCTAssertTrue(AppPreferences.current.bool(forKey: "guide.collapsed"))
    }
}
