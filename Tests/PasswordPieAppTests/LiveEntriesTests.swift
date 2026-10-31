import AppKit
import PasswordPieCore
import XCTest
@testable import PasswordPie

/// Live Chrome logins are read-only and must stay out of the saved KeePass file.
@MainActor
final class LiveEntriesTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("test.kdbx")
        setenv("PASSWORDPIE_DB", databaseURL.path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        try? FileManager.default.removeItem(at: directory)
    }

    private func unlockedSession() -> VaultSession {
        let session = VaultSession()
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        return session
    }

    private func liveLogin() -> VaultEntry {
        var live = VaultEntry()
        live.title = "github.com"
        live.url = "https://github.com/login"
        live.username = "ann"
        live.password = "chrome-secret"
        live.groupPath = ["Chrome (live)", "Work"]
        return live
    }

    private func savedEntries() throws -> [VaultEntry] {
        try KDBX.load(data: Data(contentsOf: databaseURL), password: "pw").entries
    }

    func testLiveLoginsAreSearchableButNeverSaved() throws {
        let session = unlockedSession()
        XCTAssertFalse(session.locked)
        let live = liveLogin()
        session.liveEntries = [live]

        var own = VaultEntry()
        own.title = "Own"
        session.saveEditing(own)
        session.toggleFavorite(own.id)
        session.toggleFavorite(live.id)

        XCTAssertTrue(session.isLive(live.id))
        XCTAssertFalse(session.entries.contains { $0.id == live.id })
        #if PP_DIRECT
        XCTAssertTrue(session.allEntries.contains { $0.id == live.id })
        XCTAssertNotNil(session.entry(live.id))
        #endif
        let saved = try savedEntries()
        XCTAssertEqual(saved.map(\.title), ["Own"])
        XCTAssertFalse(saved.contains { $0.password == "chrome-secret" })
        XCTAssertEqual(session.entry(own.id)?.favorite, true, "the user's own entry can still be a favorite")
    }

    func testLockingForgetsLiveLogins() {
        let session = unlockedSession()
        session.liveEntries = [liveLogin()]
        session.lock()
        XCTAssertTrue(session.liveEntries.isEmpty)
    }

    func testSaveToDatabaseWritesOneTaggedCopyAndHidesTheLiveOne() throws {
        let session = unlockedSession()
        let live = liveLogin()
        session.liveEntries = [live]
        session.saveToDatabase(live.id)

        let saved = try savedEntries()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].password, "chrome-secret")
        XCTAssertEqual(saved[0].groupPath, ["Chrome"])
        XCTAssertEqual(saved[0].tagList, ["Chrome"])
        XCTAssertNotEqual(saved[0].id, live.id)
        #if PP_DIRECT
        XCTAssertEqual(session.allEntries.filter { $0.password == "chrome-secret" }.count, 1, "the copy hides the live login")
        #endif
    }

    func testChromeLastUsedTimesFeedTheRankingMapAndLaterOnesWin() {
        let session = unlockedSession()
        let live = liveLogin()
        let early = Date(timeIntervalSince1970: 1_000)
        session.chromeLastUsed = [live.id: early]
        XCTAssertEqual(session.lastUsedMap[live.id], early)
        session.lock()
        XCTAssertTrue(session.lastUsedMap.isEmpty, "locking forgets Chrome's times")
    }

    func testSavingALiveLoginCarriesItsLastUsedTimeToTheCopy() throws {
        let session = unlockedSession()
        let live = liveLogin()
        let used = Date(timeIntervalSince1970: 1_700_000_000)
        session.liveEntries = [live]
        session.chromeLastUsed = [live.id: used]
        session.saveToDatabase(live.id)
        let copyID = try XCTUnwrap(session.entries.first { $0.password == "chrome-secret" }?.id)
        XCTAssertEqual(try XCTUnwrap(session.lastUsedMap[copyID]).timeIntervalSince1970, used.timeIntervalSince1970, accuracy: 1)
    }

    func testImportedPasswordsAreSavedIntoTheUnlockedFileAndShowInTheList() throws {
        let session = unlockedSession()
        var own = VaultEntry()
        own.title = "Own"
        session.saveEditing(own)

        var imported = VaultEntry(groupPath: ["Chrome"], tags: "Chrome")
        imported.title = "github.com"
        imported.url = "https://github.com"
        imported.username = "ann"
        imported.password = "imported-secret"
        let summary = session.mergeImported([imported], source: .chrome)

        XCTAssertEqual(summary, BrowserImportSummary(added: 1, updated: 0, unchanged: 0, removed: 0))
        XCTAssertEqual(Set(session.entries.map(\.title)), ["Own", "github.com"])
        let saved = try savedEntries()
        XCTAssertEqual(Set(saved.map(\.title)), ["Own", "github.com"])
        XCTAssertEqual(saved.first { $0.title == "github.com" }?.groupPath, ["Chrome"])

        // A second export without that site moves it to the recycle bin, and leaves the user's own entry alone.
        var other = VaultEntry(groupPath: ["Chrome"], tags: "Chrome")
        other.title = "news.example"
        other.url = "https://news.example"
        other.username = "bob"
        other.password = "pw2"
        let second = session.mergeImported([other], source: .chrome)
        XCTAssertEqual(second, BrowserImportSummary(added: 1, updated: 0, unchanged: 0, removed: 1))
        XCTAssertFalse(session.entries.contains { $0.title == "github.com" && !$0.trashed })
        XCTAssertTrue(session.entries.contains { $0.title == "Own" && !$0.trashed })
    }
}
