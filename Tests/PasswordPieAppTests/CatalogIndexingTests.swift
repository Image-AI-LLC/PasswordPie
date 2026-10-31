import AppKit
import PasswordPieCore
import XCTest
@testable import PasswordPie

/// The menu and the search index are built off the main thread, so a large vault never freezes the panel.
@MainActor
final class CatalogIndexingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
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

    private func sample(_ count: Int) -> [VaultEntry] {
        (0..<count).map { i in
            var entry = VaultEntry(groupPath: ["Sites"])
            entry.title = "Account \(i)"
            entry.url = "https://site\(i).example.com"
            return entry
        }
    }

    private func waitUntilBuilt(_ session: VaultSession, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(20)
        while session.indexing || session.topLevelRows == nil {
            guard Date() < deadline else {
                XCTFail("background catalog work did not finish", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testSmallVaultIsReadyAtOnce() {
        let session = unlockedSession()
        var own = VaultEntry()
        own.title = "GitHub"
        own.url = "https://github.com"
        session.saveEditing(own)
        XCTAssertFalse(session.indexing)
        XCTAssertEqual(session.searchIndex.count, 1)
        XCTAssertTrue(session.topLevelRows?.contains { $0.title == "Logins" } ?? false)
    }

    func testLargeVaultIndexesInTheBackground() async {
        let session = unlockedSession()
        session.entries = sample(2000)
        XCTAssertEqual(session.allEntries.count, 2000)
        XCTAssertTrue(session.indexing, "a large catalog is indexed off the main thread")
        XCTAssertNil(session.topLevelRows, "a new catalog shows Loading… until its menu is built")

        await waitUntilBuilt(session)
        XCTAssertEqual(session.searchIndex.count, 2000)
        XCTAssertTrue(session.topLevelRows?.contains { $0.title == "Logins" } ?? false)

        // One edit refolds one entry; the menu keeps its rows until the new ones arrive.
        var changed = session.entries
        changed[5].title = "Zebra Bank"
        session.entries = changed
        XCTAssertFalse(session.indexing)
        XCTAssertEqual(session.searchIndex.count, 2000)
        XCTAssertNotNil(session.topLevelRows)
        XCTAssertEqual(searchEntries(in: session.searchIndex, query: "zebra", scope: .major).map(\.id), [changed[5].id])
    }

    func testLockDropsWorkStillRunning() async {
        let session = unlockedSession()
        session.entries = sample(3000)
        session.lock()
        XCTAssertEqual(session.searchIndex.count, 0, "the index holds secrets and is cleared on lock")
        XCTAssertFalse(session.indexing)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(session.searchIndex.count, 0, "a chunk from before the lock must not publish")
        XCTAssertEqual(session.topLevelRows?.map(\.title), ["Password Generator"])
    }

    func testMenuShowsWhatIsReady() async {
        let session = unlockedSession()
        let menu = MenuController(session: session)
        session.entries = sample(2000)
        menu.reset()
        XCTAssertEqual(menu.root.rows.map(\.title), ["Loading…"])

        await waitUntilBuilt(session)
        menu.catalogUpdated(topLevel: true)
        XCTAssertTrue(menu.root.rows.contains { $0.title == "Logins" })

        menu.setQuery("account 1999")
        XCTAssertEqual(menu.root.rows.first { $0.entryID != nil }?.title, "Account 1999")
    }
}
