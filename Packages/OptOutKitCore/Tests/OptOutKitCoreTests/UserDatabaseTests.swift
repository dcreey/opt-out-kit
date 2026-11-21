import XCTest
import SQLite3
@testable import OptOutKitCore

/// The one SQLite file that holds everything the app keeps for the person (`UserDatabase`), and the move into it from the separate files of build 51 and
/// earlier. These are the rules that protect the person's history, so each is pinned: nothing in plaintext, a delete really erases, the move copies the sealed
/// bytes exactly and only deletes a file once the copy reads back the same, a household that could not be read is never saved over, the newer copy wins.
final class UserDatabaseTests: XCTestCase {
    private var folder: URL!
    private let key = FixedKey()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ook-userdb-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        for f in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.appendingPathComponent(f).path)
        }
        try? FileManager.default.removeItem(at: folder)
    }

    private var dbURL: URL { folder.appendingPathComponent("exnay.sqlite") }

    // MARK: The rows

    func testRowsAreStoredReplacedAndDeletedByKindAndKey() throws {
        let db = UserDatabase(url: dbURL)
        XCTAssertNil(try db.get(.household))
        try db.put(.household, Data([1, 2, 3])); try db.put(.household, Data([4, 5]))
        XCTAssertEqual(try db.get(.household), Data([4, 5]), "a second put replaces the first")
        try db.put(.evidence, key: "p1/a.com", Data([9])); try db.put(.evidence, key: "p1/b.com", Data([8])); try db.put(.evidence, key: "p2/a.com", Data([7]))
        XCTAssertEqual(try db.get(.evidence, key: "p1/b.com"), Data([8]))
        XCTAssertNil(try db.get(.draft), "kinds are separate")
        try db.deleteAll(.evidence, keyPrefix: "p1/")
        XCTAssertFalse(db.exists(.evidence, key: "p1/a.com")); XCTAssertTrue(db.exists(.evidence, key: "p2/a.com"), "another person's are kept")
        try db.delete(.household); XCTAssertNil(try db.get(.household))
        try db.put(.evidence, key: "old", Data([1]), saved: Date().addingTimeInterval(-100 * 86_400))
        try db.delete(.evidence, savedBefore: Date().addingTimeInterval(-90 * 86_400))
        XCTAssertFalse(db.exists(.evidence, key: "old")); XCTAssertTrue(db.exists(.evidence, key: "p2/a.com"))
        try db.deleteAll(.evidence); XCTAssertFalse(db.exists(.evidence, key: "p2/a.com"))
    }

    /// Opening, reading, and asking to delete what is not there change nothing on disk: a household that could not be read (the wrong key, a locked
    /// phone) is never touched, not even by the app starting up and pruning old screenshots.
    func testOpeningAndReadingLeaveTheFileExactlyAsItWas() throws {
        try HouseholdStore(url: dbURL, keys: key).save(sampleHousehold())
        let before = try Data(contentsOf: dbURL)
        let again = UserDatabase(url: dbURL)
        _ = try again.get(.household); _ = try again.get(.draft); XCTAssertFalse(again.exists(.evidence, key: "nobody/nothing"))
        try again.delete(.draft); try again.deleteAll(.evidence); try again.delete(.evidence, savedBefore: Date())
        _ = try? HouseholdStore(url: dbURL, keys: FixedKey()).load()          // a wrong key
        XCTAssertEqual(try Data(contentsOf: dbURL), before)
    }

    func testWhatIsSavedIsThereWhenTheAppIsOpenedAgain() throws {
        try HouseholdStore(url: dbURL, keys: key).save(sampleHousehold())
        XCTAssertEqual(try HouseholdStore(url: dbURL, keys: key).load(), sampleHousehold(), "a new connection to the same file, as after a relaunch")
    }

    /// A removed screenshot is not left in the file (`secure_delete`), and the file gives the space back (`auto_vacuum`).
    func testADeletedScreenshotIsOverwrittenAndTheFileShrinks() throws {
        let db = UserDatabase(url: dbURL)
        let marker = Data("SCREENSHOT-BYTES-THAT-MUST-NOT-SURVIVE".utf8)
        let big = Data(repeating: 0x5A, count: 200_000) + marker + Data(repeating: 0x5B, count: 200_000)
        try db.put(.evidence, key: "p/a.com", big)
        let before = try Data(contentsOf: dbURL)
        XCTAssertNotNil(before.range(of: marker), "the test's own bytes are in the file while stored")
        try db.deleteAll(.evidence)
        let after = try Data(contentsOf: dbURL)
        XCTAssertNil(after.range(of: marker), "gone from the file once deleted")
        XCTAssertLessThan(after.count, before.count / 2, "the pages are given back")
    }

    /// iOS keeps a protected file closed until the first unlock: a refusal to open it is the phone being locked, never damage and never a reason to erase.
    func testAFileTheSystemWillNotOpenIsReportedAsLockedNotDamaged() throws {
        let store = HouseholdStore(url: dbURL, keys: key)
        try store.save(sampleHousehold())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dbURL.path)
        XCTAssertThrowsError(try HouseholdStore(url: dbURL, keys: key).load()) { XCTAssertTrue(StorageError.isLocked($0), "\($0)") }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dbURL.path)
        XCTAssertEqual(try HouseholdStore(url: dbURL, keys: key).load(), sampleHousehold(), "nothing was lost")
    }

    // MARK: The move from the separate files

    /// One household for the whole test (a person gets a new id each time one is made, so two made separately are never equal).
    private let household: Household = {
        var h = Household()
        h.add(Person(displayName: "Me", names: [NameEntry(kind: .legal, name: "Pat Example")], emails: ["pat@example.com"]))
        return h
    }()
    private func sampleHousehold() -> Household { household }

    /// The files exactly as build 51 wrote them: the sealed household, a profile draft, and one sealed screenshot per site in a folder per person.
    private struct OldFiles {
        let legacy: UserDatabase.LegacyFiles
        let household: Data, draft: Data, shot: Data
        let person: UUID
    }

    private func writeOldFiles(household: Household? = nil, modified: Date? = nil) throws -> OldFiles {
        let legacy = UserDatabase.LegacyFiles(household: folder.appendingPathComponent("household.sealed"), evidence: folder.appendingPathComponent("household.evidence"),
                                              draft: folder.appendingPathComponent("profile-draft.sealed"))
        let person = UUID()
        let h = try SealedStore.seal(JSONEncoder().encode(household ?? sampleHousehold()), key: key.key())
        var p = Person(displayName: "Me", relationship: .me); p.names = [NameEntry(kind: .legal, name: "Pat Example")]
        let d = try SealedStore.seal(JSONEncoder().encode(ProfileDraft(personID: p.id, person: p, email: "pat@example.com")), key: key.key())
        let shot = try SealedStore.seal(Data((0..<3000).map { UInt8($0 % 251) }), key: key.key())
        try h.write(to: legacy.household); try d.write(to: legacy.draft)
        let dir = legacy.evidence.appendingPathComponent(person.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try shot.write(to: dir.appendingPathComponent("example.com.jpg.sealed"))
        if let modified { for f in [legacy.household, legacy.draft, dir.appendingPathComponent("example.com.jpg.sealed")] { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: f.path) } }
        return OldFiles(legacy: legacy, household: h, draft: d, shot: shot, person: person)
    }

    func testTheOldFilesAreMovedInByteForByteAndThenDeleted() throws {
        let old = try writeOldFiles()
        let store = HouseholdStore(url: dbURL, keys: key, legacy: old.legacy)
        XCTAssertEqual(try store.load(), sampleHousehold(), "the household reads as it did from its file")
        XCTAssertEqual(try store.database.get(.household), old.household, "the very same sealed bytes, nothing decrypted or re-encoded")
        XCTAssertEqual(try store.database.get(.draft), old.draft)
        let evidence = EvidenceStore(database: store.database, keys: key)
        XCTAssertEqual(try store.database.get(.evidence, key: EvidenceStore.rowKey(person: old.person.uuidString, site: "example.com", key: key.key())), old.shot,
                       "the screenshot's sealed bytes, under its opaque key")
        XCTAssertNotNil(evidence.load(person: old.person, site: "example.com"), "and it opens with the same key")
        XCTAssertNotNil(ProfileDraftStore(database: store.database, keys: key).load())
        for f in [old.legacy.household, old.legacy.draft, old.legacy.evidence] { XCTAssertFalse(FileManager.default.fileExists(atPath: f.path), "\(f.lastPathComponent) is gone once moved") }
        XCTAssertEqual(try HouseholdStore(url: dbURL, keys: key, legacy: old.legacy).load(), sampleHousehold(), "a later launch has nothing left to move and finds it all")
    }

    /// A household that could not be read (here: no permission) is neither moved nor saved over: the file stays where it is, and saving throws.
    func testAnOldHouseholdThatCannotBeReadIsNeverSavedOver() throws {
        let old = try writeOldFiles()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: old.legacy.household.path)
        let store = HouseholdStore(url: dbURL, keys: key, legacy: old.legacy)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(Household()), "nothing new is saved while the old household is unread")
        XCTAssertNil(try store.database.get(.household), "no row was written")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.legacy.household.path), "the file is untouched")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: old.legacy.household.path)
        XCTAssertEqual(try store.load(), sampleHousehold(), "readable again (after the unlock): moved then")
    }

    /// If a move stopped half way, or an older build was run in between, the newer of the file and the row is kept.
    func testTheNewerOfAFileAndARowIsKept() throws {
        // The row is newer: the file is only what an earlier move left behind.
        var newer = Household(); newer.add(Person(displayName: "Newer"))
        var old = try writeOldFiles(modified: Date().addingTimeInterval(-86_400))
        try UserDatabase(url: dbURL).put(.household, try SealedStore.seal(JSONEncoder().encode(newer), key: key.key()), saved: Date())
        XCTAssertEqual(try HouseholdStore(url: dbURL, keys: key, legacy: old.legacy).load()?.people.first?.displayName, "Newer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.legacy.household.path))
        // The file is newer (saved by an older build after the row was written): it wins.
        try FileManager.default.removeItem(at: dbURL)
        var fromOldBuild = Household(); fromOldBuild.add(Person(displayName: "OldBuild"))
        old = try writeOldFiles(household: fromOldBuild, modified: Date())
        try UserDatabase(url: dbURL).put(.household, try SealedStore.seal(JSONEncoder().encode(newer), key: key.key()), saved: Date().addingTimeInterval(-86_400))
        XCTAssertEqual(try HouseholdStore(url: dbURL, keys: key, legacy: old.legacy).load()?.people.first?.displayName, "OldBuild")
    }

    func testStartingWithNothingToMoveIsJustAnEmptyDatabase() throws {
        let legacy = UserDatabase.LegacyFiles(household: folder.appendingPathComponent("household.sealed"), evidence: folder.appendingPathComponent("household.evidence"),
                                              draft: folder.appendingPathComponent("profile-draft.sealed"))
        let store = HouseholdStore(url: dbURL, keys: key, legacy: legacy)
        XCTAssertNil(try store.load())
        try store.save(sampleHousehold())
        XCTAssertEqual(try store.load(), sampleHousehold())
    }

    // MARK: What the file reveals

    /// The values are sealed, and so are the row keys: the database does not say which people or which sites have a screenshot (the old files' names did).
    func testTheRowKeysDoNotNameThePersonOrTheSite() throws {
        let db = UserDatabase(url: dbURL)
        let evidence = EvidenceStore(database: db, keys: key)
        let who = UUID()
        try evidence.save(Data([1, 2, 3]), person: who, site: "spokeo.com")
        try evidence.save(Data([4]), person: who, site: "whitepages.com")
        let keys = try db.all(.evidence).map(\.key)
        XCTAssertEqual(keys.count, 2)
        for k in keys {
            XCTAssertFalse(k.uppercased().contains(who.uuidString), "the person's id is not in the key")
            XCTAssertFalse(k.contains("spokeo") || k.contains("whitepages"), "no site name in the key")
        }
        let raw = String(decoding: try Data(contentsOf: dbURL), as: UTF8.self)
        XCTAssertFalse(raw.contains("spokeo") || raw.contains("whitepages") || raw.uppercased().contains(who.uuidString), "nor anywhere in the file")
        XCTAssertEqual(evidence.load(person: who, site: "spokeo.com"), Data([1, 2, 3]), "found again by the same person and site")
        XCTAssertNil(evidence.load(person: UUID(), site: "spokeo.com"))
        evidence.removeAll(person: UUID()); XCTAssertEqual(try db.all(.evidence).count, 2, "another person's removal leaves them")
        evidence.removeAll(person: who); XCTAssertEqual(try db.all(.evidence).count, 0)
        XCTAssertNotEqual(try EvidenceStore.rowKey(person: who.uuidString, site: "a.com", key: key.key()), EvidenceStore.rowKey(person: who.uuidString, site: "a.com", key: SealedStore.newKey()),
                          "another key gives other row keys: they cannot be worked out from the ids alone")
    }

    /// A file of a newer layout than this build reads is refused, not guessed at.
    func testAFileOfANewerLayoutIsRefused() throws {
        try HouseholdStore(url: dbURL, keys: key).save(sampleHousehold())
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA user_version = 99", nil, nil, nil); sqlite3_close(db)
        XCTAssertThrowsError(try HouseholdStore(url: dbURL, keys: key).load())
        var h: OpaquePointer?; sqlite3_open(dbURL.path, &h); defer { sqlite3_close(h) }
        var st: OpaquePointer?; sqlite3_prepare_v2(h, "SELECT count(*) FROM sealed", -1, &st, nil); defer { sqlite3_finalize(st) }
        sqlite3_step(st)
        XCTAssertEqual(Int(sqlite3_column_int(st, 0)), 1, "and nothing was changed")
    }
}
