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
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
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
}
