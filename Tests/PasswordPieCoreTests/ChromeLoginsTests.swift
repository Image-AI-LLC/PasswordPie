#if PP_DIRECT
import CommonCrypto
import SQLite3
import XCTest
@testable import PasswordPieCore

final class ChromeLoginsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Key derivation and decryption

    func testPBKDF2SHA1MatchesRFC6070() throws {
        let one = try ChromeSafeStorage.pbkdf2SHA1(password: Data("password".utf8), salt: Data("salt".utf8), iterations: 1, length: 20)
        XCTAssertEqual(hex(one), "0c60c80f961f0e71f3a9b524af6012062fe037a6")
        let two = try ChromeSafeStorage.pbkdf2SHA1(password: Data("password".utf8), salt: Data("salt".utf8), iterations: 2, length: 20)
        XCTAssertEqual(hex(two), "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957")
        let many = try ChromeSafeStorage.pbkdf2SHA1(password: Data("password".utf8), salt: Data("salt".utf8), iterations: 4096, length: 20)
        XCTAssertEqual(hex(many), "4b007901b765489abead49d926f721d065a429c1")
    }

    func testDerivedKeyIsSixteenBytes() throws {
        XCTAssertEqual(try ChromeSafeStorage.deriveKey(password: Data("abc".utf8)).count, 16)
    }

    func testV10BlobsRoundTrip() throws {
        let key = try ChromeSafeStorage.deriveKey(password: Data("safe-storage-secret".utf8))
        for text in ["hunter2", "", "pässwörd-密码-🔑", String(repeating: "x", count: 100)] {
            let blob = try encrypt(text, key: key)
            XCTAssertEqual(try ChromeSafeStorage.decrypt(blob, key: key), text)
        }
    }

    func testDecryptRejectsWrongKeysAndUnknownFormats() throws {
        let key = try ChromeSafeStorage.deriveKey(password: Data("right".utf8))
        let wrong = try ChromeSafeStorage.deriveKey(password: Data("wrong".utf8))
        let blob = try encrypt("hunter2", key: key)
        XCTAssertThrowsError(try ChromeSafeStorage.decrypt(blob, key: wrong))
        XCTAssertThrowsError(try ChromeSafeStorage.decrypt(Data("v11".utf8) + blob.dropFirst(3), key: key))
        XCTAssertThrowsError(try ChromeSafeStorage.decrypt(Data("v10".utf8) + Data(repeating: 1, count: 7), key: key))
        XCTAssertThrowsError(try ChromeSafeStorage.decrypt(Data(), key: key))
    }

    // MARK: Reading a profile

    func testReadsLoginsAndSkipsNeverSavedAndEmptyRows() throws {
        let key = try ChromeSafeStorage.deriveKey(password: Data("k".utf8))
        let profile = try makeProfile("Profile 1", rows: [
            Row(origin: "https://github.com/login", realm: "https://github.com/", user: "ann", password: "pw1", key: key),
            Row(origin: "https://www.news.example/", realm: "https://www.news.example/", user: "bob", password: "pw2", key: key),
            Row(origin: "https://never.example/", realm: "https://never.example/", user: "", password: nil, blacklisted: true, key: key),
            Row(origin: "https://federated.example/", realm: "federation://federated.example/accounts", user: "carl", password: nil, key: key)
        ])
        let entries = try ChromeLogins.entries(in: profile, key: key).entries
        XCTAssertEqual(entries.map(\.password).sorted(), ["pw1", "pw2"])
        let github = try XCTUnwrap(entries.first { $0.username == "ann" })
        XCTAssertEqual(github.url, "https://github.com/login")
        XCTAssertEqual(github.title, "github.com")
        XCTAssertEqual(github.groupPath, ["Chrome (live)", "Work"])
    }

    func testBothLoginDataAndTheAccountStoreAreRead() throws {
        let key = try ChromeSafeStorage.deriveKey(password: Data("k".utf8))
        let profile = try makeProfile("Profile 2", name: "Home", rows: [
            Row(origin: "https://local.example/", realm: "https://local.example/", user: "a", password: "p1", key: key)
        ], accountRows: [
            Row(origin: "https://synced.example/", realm: "https://synced.example/", user: "b", password: "p2", key: key),
            Row(origin: "https://local.example/", realm: "https://local.example/", user: "a", password: "p1", key: key)
        ])
        let entries = try ChromeLogins.entries(in: profile, key: key).entries
        XCTAssertEqual(entries.map(\.password).sorted(), ["p1", "p2"], "the same login in both stores shows once")
    }

    func testRowsStillInTheWriteAheadLogAreRead() throws {
        let key = try ChromeSafeStorage.deriveKey(password: Data("k".utf8))
        let dir = root.appendingPathComponent("Profile 9", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("Login Data").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        try exec(db, "PRAGMA journal_mode=WAL")
        try exec(db, loginsSchema)
        try insert(db, Row(origin: "https://wal.example/", realm: "https://wal.example/", user: "w", password: "walpw", key: key))
        // Chrome has the database open, so the new row is in the -wal file, not yet in the main file.
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "-wal"))
        let profile = ChromeProfile(directoryName: "Profile 9", name: "Wal", directory: dir)
        let entries = try ChromeLogins.entries(in: profile, key: key).entries
        XCTAssertEqual(entries.map(\.password), ["walpw"])
    }

    func testTheOriginalDatabaseIsNeverModifiedAndNoCopyIsLeftBehind() throws {
        let key = try ChromeSafeStorage.deriveKey(password: Data("k".utf8))
        let profile = try makeProfile("Profile 1", rows: [
            Row(origin: "https://a.example/", realm: "https://a.example/", user: "u", password: "p", key: key)
        ])
        let original = profile.directory.appendingPathComponent("Login Data")
        let before = try Data(contentsOf: original)
        let temp = FileManager.default.temporaryDirectory
        let tempBefore = try FileManager.default.contentsOfDirectory(atPath: temp.path).filter { $0.hasPrefix("passwordpie-chrome-") }
        _ = try ChromeLogins.entries(in: profile, key: key)
        XCTAssertEqual(try Data(contentsOf: original), before)
        let tempAfter = try FileManager.default.contentsOfDirectory(atPath: temp.path).filter { $0.hasPrefix("passwordpie-chrome-") }
        XCTAssertEqual(tempAfter.count, tempBefore.count)
    }

    func testIDsAreStableAcrossReads() throws {
        let key = try ChromeSafeStorage.deriveKey(password: Data("k".utf8))
        let profile = try makeProfile("Profile 1", rows: [
            Row(origin: "https://a.example/", realm: "https://a.example/", user: "u", password: "p", key: key)
        ])
        let first = try ChromeLogins.entries(in: profile, key: key).entries
        let second = try ChromeLogins.entries(in: profile, key: key).entries
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    func testOneUndecryptableRowDoesNotLoseTheOthers() throws {
        let key = try ChromeSafeStorage.deriveKey(password: Data("k".utf8))
        let other = try ChromeSafeStorage.deriveKey(password: Data("other".utf8))
        let profile = try makeProfile("Profile 1", rows: [
            Row(origin: "https://good.example/", realm: "https://good.example/", user: "u", password: "p", key: key),
            Row(origin: "https://bad.example/", realm: "https://bad.example/", user: "u", password: "q", key: other)
        ])
        let result = try ChromeLogins.entries(in: profile, key: key)
        XCTAssertEqual(result.entries.map(\.password), ["p"])
        XCTAssertEqual(result.skipped, 1)
    }

    func testAWrongKeyForEveryRowIsReportedAsAWrongKey() throws {
        let key = try ChromeSafeStorage.deriveKey(password: Data("k".utf8))
        let wrong = try ChromeSafeStorage.deriveKey(password: Data("wrong".utf8))
        let profile = try makeProfile("Profile 1", rows: [
            Row(origin: "https://a.example/", realm: "https://a.example/", user: "u", password: "p", key: key),
            Row(origin: "https://b.example/", realm: "https://b.example/", user: "u", password: "q", key: key)
        ])
        XCTAssertThrowsError(try ChromeLogins.entries(in: profile, key: wrong)) { error in
            XCTAssertEqual(error as? ChromeLoginsError, .wrongKey)
        }
    }

    func testChromeLastUsedTimesAreReadFromBothStoresAndTheLaterOneWins() throws {
        let key = try ChromeSafeStorage.deriveKey(password: Data("k".utf8))
        let dir = root.appendingPathComponent("Profile 5", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Chrome stores microseconds since 1601-01-01. 13_300_000_000_000_000 us is 2021-... in Unix time below.
        let early: Int64 = 13_300_000_000_000_000
        let late: Int64 = 13_400_000_000_000_000
        try writeWithLastUsed([("https://a.example/", "u", "p", early), ("https://never.example/", "u", "q", 0)], to: dir.appendingPathComponent("Login Data"), key: key)
        try writeWithLastUsed([("https://a.example/", "u", "p", late)], to: dir.appendingPathComponent("Login Data For Account"), key: key)
        let profile = ChromeProfile(directoryName: "Profile 5", name: "Used", directory: dir)
        let result = try ChromeLogins.entries(in: profile, key: key)
        let used = try XCTUnwrap(result.entries.first { $0.url == "https://a.example/" })
        let never = try XCTUnwrap(result.entries.first { $0.url == "https://never.example/" })
        let expected = Date(timeIntervalSince1970: Double(late) / 1_000_000 - 11_644_473_600)
        let seen = try XCTUnwrap(result.lastUsed[used.id])
        XCTAssertEqual(seen.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
        XCTAssertNil(result.lastUsed[never.id], "0 means Chrome never used it")
    }

    func testAnOlderChromeWithoutTheColumnStillReads() throws {
        let key = try ChromeSafeStorage.deriveKey(password: Data("k".utf8))
        let profile = try makeProfile("Profile 6", rows: [Row(origin: "https://a.example/", realm: "r", user: "u", password: "p", key: key)])
        let result = try ChromeLogins.entries(in: profile, key: key)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertTrue(result.lastUsed.isEmpty)
    }

    // MARK: Finding profiles

    func testProfilesUseTheNamesFromLocalState() throws {
        let key = try ChromeSafeStorage.deriveKey(password: Data("k".utf8))
        _ = try makeProfile("Profile 1", name: "Work", rows: [Row(origin: "https://a.example/", realm: "r", user: "u", password: "p", key: key)])
        _ = try makeProfile("Profile 3", name: "Home", rows: [])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Crashpad"), withIntermediateDirectories: true)
        let profiles = ChromeLogins.profiles(root: root)
        XCTAssertEqual(profiles.map(\.directoryName), ["Profile 1", "Profile 3"])
        XCTAssertEqual(profiles.map(\.name), ["Work", "Home"])
    }

    func testAMissingChromeInstallHasNoProfiles() {
        XCTAssertTrue(ChromeLogins.profiles(root: root.appendingPathComponent("absent")).isEmpty)
    }

    /// macOS 27 denies the folder with EPERM and does not ask. That must not look like Chrome is missing.
    func testAnUnreadableChromeFolderIsAccessDeniedRatherThanMissing() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        XCTAssertThrowsError(try ChromeLogins.load(root: root, key: Data(repeating: 1, count: 16))) { error in
            XCTAssertEqual(error as? ChromeLoginsError, .accessDenied)
        }
    }

    func testAMissingChromeFolderIsNotAnAccessDenial() {
        XCTAssertThrowsError(try ChromeLogins.load(root: root.appendingPathComponent("no-such-chrome"), key: Data(repeating: 1, count: 16))) { error in
            XCTAssertEqual(error as? ChromeLoginsError, .noChrome)
        }
    }

    func testAllProfilesAreCombinedAndReportTheirCounts() throws {
        let key = try ChromeSafeStorage.deriveKey(password: Data("k".utf8))
        _ = try makeProfile("Profile 1", name: "Work", rows: [Row(origin: "https://a.example/", realm: "r1", user: "u", password: "p1", key: key)])
        _ = try makeProfile("Profile 2", name: "Home", rows: [Row(origin: "https://b.example/", realm: "r2", user: "u", password: "p2", key: key)])
        let result = try ChromeLogins.load(root: root, key: key)
        XCTAssertEqual(result.entries.map(\.password).sorted(), ["p1", "p2"])
        XCTAssertEqual(result.profileCount, 2)
    }

    func testAProfileThatCannotBeReadIsReportedBesideOneThatCan() throws {
        let key = try ChromeSafeStorage.deriveKey(password: Data("k".utf8))
        _ = try makeProfile("Profile 1", name: "Work", rows: [Row(origin: "https://a.example/", realm: "r1", user: "u", password: "p1", key: key)])
        let broken = try makeProfile("Profile 2", name: "Home", rows: [])
        try Data("not a database".utf8).write(to: broken.directory.appendingPathComponent("Login Data"))
        let result = try ChromeLogins.load(root: root, key: key)
        XCTAssertEqual(result.entries.map(\.password), ["p1"])
        XCTAssertEqual(result.profileCount, 1)
        XCTAssertEqual(result.failedProfiles, ["Home"])
    }

    // MARK: Showing live entries next to the database

    private func login(_ url: String, _ user: String, _ password: String, id: UUID = UUID(), tags: String = "", trashed: Bool = false) -> VaultEntry {
        var entry = VaultEntry(id: id, trashed: trashed, tags: tags)
        entry.url = url
        entry.username = user
        entry.password = password
        return entry
    }

    func testAChromeLoginNobodySavedIsShownAsIs() {
        let live = login("https://github.com", "ann", "pw")
        XCTAssertEqual(ChromeLogins.combined(saved: [], live: [live]), [live])
    }

    func testTheSameSiteAndAccountWithTheSamePasswordShowOneEntryAndNoExtraField() {
        let saved = login("https://github.com", "ann", "pw")
        let live = login("https://github.com/login", "ANN", "pw")
        XCTAssertEqual(ChromeLogins.combined(saved: [saved], live: [live]), [saved])
    }

    func testADifferentChromePasswordBecomesAProtectedFieldOnTheOneEntry() {
        let saved = login("https://github.com", "ann", "mine")
        let live = login("https://github.com", "ann", "chrome")
        let shown = ChromeLogins.combined(saved: [saved], live: [live])
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown[0].id, saved.id)
        XCTAssertEqual(shown[0].password, "mine")
        XCTAssertEqual(shown[0].fields.first { $0.key == ChromeLogins.passwordFieldName }?.value, "chrome")
        XCTAssertEqual(shown[0].fields.first { $0.key == ChromeLogins.passwordFieldName }?.protected, true)
    }

    func testAnEntrySavedFromChromeStaysOneAfterItsUsernameAndPasswordChange() {
        let id = UUID()
        let saved = login("https://github.com", "renamed", "mine", id: id)
        let live = login("https://github.com", "ann", "chrome", id: id)
        let shown = ChromeLogins.combined(saved: [saved], live: [live])
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown[0].username, "renamed")
        XCTAssertEqual(shown[0].value(for: ChromeLogins.usernameFieldName), "ann")
        XCTAssertEqual(shown[0].value(for: ChromeLogins.passwordFieldName), "chrome")
    }

    func testAUsernameRenamedInChromeStaysOnTheCopySavedFromChrome() {
        let saved = login("https://github.com", "ann", "pw", tags: "Chrome")
        let renamed = login("https://github.com", "ann2", "pw")
        let shown = ChromeLogins.combined(saved: [saved], live: [renamed])
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown[0].value(for: ChromeLogins.usernameFieldName), "ann2")
    }

    func testAnotherAccountWithTheSamePasswordStaysSeparateFromTheUsersOwnEntry() {
        let saved = login("https://github.com", "ann", "pw")
        let other = login("https://github.com", "bob", "pw")
        XCTAssertEqual(ChromeLogins.combined(saved: [saved], live: [other]).count, 2)
    }

    func testALoginWithNoUsernameNeedsTheSamePasswordToJoinAnEntry() {
        let saved = login("https://github.com", "", "mine")
        XCTAssertEqual(ChromeLogins.combined(saved: [saved], live: [login("https://github.com", "", "chrome")]).count, 2)
        XCTAssertEqual(ChromeLogins.combined(saved: [saved], live: [login("https://github.com", "", "mine")]).count, 1)
    }

    func testTwoChromeProfilesWithDifferentPasswordsAreBothKeptOnTheEntry() {
        let saved = login("https://github.com", "ann", "mine")
        let work = login("https://github.com", "ann", "work")
        let home = login("https://github.com", "ann", "home")
        let shown = ChromeLogins.combined(saved: [saved], live: [work, home])
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown[0].value(for: ChromeLogins.passwordFieldName), "work")
        XCTAssertEqual(shown[0].value(for: ChromeLogins.passwordFieldName + " (2)"), "home")
    }

    func testAFieldTheUserNamedTheSameIsNotOverwritten() {
        var saved = login("https://github.com", "ann", "mine")
        saved.setValue("user value", for: ChromeLogins.passwordFieldName)
        let shown = ChromeLogins.combined(saved: [saved], live: [login("https://github.com", "ann", "chrome")])[0]
        XCTAssertEqual(shown.value(for: ChromeLogins.passwordFieldName), "user value")
        XCTAssertEqual(shown.value(for: ChromeLogins.passwordFieldName + " (2)"), "chrome")
    }

    func testATrashedEntryDoesNotAbsorbTheChromeLogin() {
        let id = UUID()
        let saved = login("https://github.com", "ann", "pw", id: id, trashed: true)
        let live = login("https://github.com", "ann", "pw", id: id)
        let shown = ChromeLogins.combined(saved: [saved], live: [live])
        XCTAssertEqual(shown.filter { !$0.trashed }, [live])
    }

    // MARK: Store signature

    func testStoreSignatureTracksLoginFilesOnly() throws {
        let dir2 = root.appendingPathComponent("Profile 2", isDirectory: true)
        let dir10 = root.appendingPathComponent("Profile 10", isDirectory: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir10, withIntermediateDirectories: true)
        try Data("db2".utf8).write(to: dir2.appendingPathComponent("Login Data"))
        try Data().write(to: dir2.appendingPathComponent("Login Data-journal"))
        try Data("cookies".utf8).write(to: dir2.appendingPathComponent("Cookies"))
        try Data("db10".utf8).write(to: dir10.appendingPathComponent("Login Data"))
        try Data("wal".utf8).write(to: dir10.appendingPathComponent("Login Data For Account-wal"))

        let first = ChromeLogins.storeSignature(root: root)
        XCTAssertEqual(first, ChromeLogins.storeSignature(root: root))
        XCTAssertEqual(first.files.map(\.relativePath), [
            "Profile 2/Login Data",
            "Profile 2/Login Data-journal",
            "Profile 10/Login Data",
            "Profile 10/Login Data For Account-wal"
        ])

        try Data("db2-changed".utf8).write(to: dir2.appendingPathComponent("Login Data"))
        XCTAssertNotEqual(first, ChromeLogins.storeSignature(root: root))
    }

    func testAProfileRenameChangesTheSignature() throws {
        let dir = root.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: dir.appendingPathComponent("Login Data"))
        try updateLocalState("Default", "Work")
        let named = ChromeLogins.storeSignature(root: root)
        XCTAssertEqual(named.profileNames, ["Default": "Work"])

        try updateLocalState("Default", "Home")
        let renamed = ChromeLogins.storeSignature(root: root)
        XCTAssertEqual(renamed.files, named.files, "a rename does not pretend the login store itself changed")
        XCTAssertNotEqual(renamed, named)
        XCTAssertEqual(renamed.profileNames, ["Default": "Home"])
    }

    func testMissingChromeFolderHasAnEmptySignature() {
        let missing = ChromeLogins.storeSignature(root: root.appendingPathComponent("absent"))
        XCTAssertEqual(missing.files, [])
        XCTAssertEqual(missing, ChromeLogins.storeSignature(root: root.appendingPathComponent("other-absent")))
    }

    // MARK: Helpers

    private struct Row {
        var origin: String
        var realm: String
        var user: String
        var password: String?
        var blacklisted = false
        var key: Data
    }

    private let loginsSchema = """
    CREATE TABLE logins (origin_url VARCHAR NOT NULL, action_url VARCHAR, username_element VARCHAR, username_value VARCHAR,
    password_element VARCHAR, password_value BLOB, submit_element VARCHAR, signon_realm VARCHAR NOT NULL, date_created INTEGER NOT NULL,
    blacklisted_by_user INTEGER NOT NULL, scheme INTEGER NOT NULL, times_used INTEGER)
    """

    private func makeProfile(_ directoryName: String, name: String? = nil, rows: [Row], accountRows: [Row] = []) throws -> ChromeProfile {
        let dir = root.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(rows, to: dir.appendingPathComponent("Login Data"))
        if !accountRows.isEmpty { try write(accountRows, to: dir.appendingPathComponent("Login Data For Account")) }
        let shownName = name ?? "Work"
        try updateLocalState(directoryName, shownName)
        return ChromeProfile(directoryName: directoryName, name: shownName, directory: dir)
    }

    private func updateLocalState(_ directoryName: String, _ name: String) throws {
        let url = root.appendingPathComponent("Local State")
        var info: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            info = cache
        }
        info[directoryName] = ["name": name]
        let data = try JSONSerialization.data(withJSONObject: ["profile": ["info_cache": info]])
        try data.write(to: url)
    }

    private func write(_ rows: [Row], to url: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        try exec(db, loginsSchema)
        for row in rows { try insert(db, row) }
    }

    private func insert(_ db: OpaquePointer?, _ row: Row) throws {
        let blob = try row.password.map { try encrypt($0, key: row.key) } ?? Data()
        var statement: OpaquePointer?
        let sql = "INSERT INTO logins (origin_url, action_url, username_value, password_value, signon_realm, date_created, blacklisted_by_user, scheme, times_used) VALUES (?, ?, ?, ?, ?, 0, ?, 0, 1)"
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, row.origin, -1, transient)
        sqlite3_bind_text(statement, 2, row.origin, -1, transient)
        sqlite3_bind_text(statement, 3, row.user, -1, transient)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(blob.count), transient) }
        sqlite3_bind_text(statement, 5, row.realm, -1, transient)
        sqlite3_bind_int(statement, 6, row.blacklisted ? 1 : 0)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    private func writeWithLastUsed(_ rows: [(String, String, String, Int64)], to url: URL, key: Data) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        try exec(db, loginsSchema.replacingOccurrences(of: "times_used INTEGER)", with: "times_used INTEGER, date_last_used INTEGER NOT NULL DEFAULT 0)"))
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (origin, user, password, lastUsed) in rows {
            let blob = try encrypt(password, key: key)
            var statement: OpaquePointer?
            let sql = "INSERT INTO logins (origin_url, action_url, username_value, password_value, signon_realm, date_created, blacklisted_by_user, scheme, times_used, date_last_used) VALUES (?, ?, ?, ?, ?, 0, 0, 0, 1, ?)"
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, origin, -1, transient)
            sqlite3_bind_text(statement, 2, origin, -1, transient)
            sqlite3_bind_text(statement, 3, user, -1, transient)
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(blob.count), transient) }
            sqlite3_bind_text(statement, 5, origin, -1, transient)
            sqlite3_bind_int64(statement, 6, lastUsed)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
    }

    /// Chrome's macOS scheme: "v10" + AES-128-CBC(PKCS7) with an IV of 16 spaces.
    private func encrypt(_ text: String, key: Data) throws -> Data {
        let plain = Data(text.utf8)
        var out = Data(count: plain.count + kCCBlockSizeAES128)
        var written = 0
        let iv = Data(repeating: 0x20, count: 16)
        let status = out.withUnsafeMutableBytes { outRaw in
            plain.withUnsafeBytes { plainRaw in
                key.withUnsafeBytes { keyRaw in
                    iv.withUnsafeBytes { ivRaw in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyRaw.baseAddress, key.count, ivRaw.baseAddress,
                                plainRaw.baseAddress, plain.count, outRaw.baseAddress, outRaw.count, &written)
                    }
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        return Data("v10".utf8) + out.prefix(written)
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
#endif
