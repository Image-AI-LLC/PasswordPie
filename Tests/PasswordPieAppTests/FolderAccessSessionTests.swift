import XCTest
@testable import PasswordPie

/// The lock screen in the App Store app, for a database whose folder was never allowed (docs/UX.md).
@MainActor
final class FolderAccessSessionTests: XCTestCase {
    private var directory: URL!
    private var database: URL!
    private var suite = ""

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("folders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = directory.appendingPathComponent("test.kdbx")
        setenv("PASSWORDPIE_DB", database.path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
        UserDefaults.standard.set(true, forKey: "touchIDDeclined.\(database.path)")
        suite = "FolderAccessSessionTests.\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: "touchIDDeclined.\(database.path)")
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        try FileManager.default.removeItem(at: directory)
    }

    private func sandboxedAccess(allowing folders: [String]) -> FolderAccess {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(Dictionary(uniqueKeysWithValues: folders.map { ($0, Data($0.utf8)) }), forKey: FolderAccess.defaultsKey)
        let system = FolderAccess.System(
            makeBookmark: { Data($0.path.utf8) },
            resolveBookmark: { FolderAccess.Resolved(url: URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), stale: false) },
            startAccessing: { _ in true },
            stopAccessing: { _ in },
            askForFolder: { _ in nil }
        )
        return FolderAccess(sandboxed: true, defaults: defaults, ownFolder: "/Container/Data", system: system)
    }

    func testAFolderNeverAllowedIsNotOfferedAsANewDatabaseAndDoesNotUnlock() {
        let session = VaultSession(keyFileMemory: MemoryKeyFileKeychain(), folderAccess: sandboxedAccess(allowing: []), writes: .inline)
        session.restore()
        XCTAssertFalse(session.creating, "an unreadable folder must not look like a new database")
        session.passwordDraft = "pw"
        session.unlock()
        XCTAssertTrue(session.locked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
    }

    func testAnAllowedFolderCreatesAndSavesAsBefore() {
        let session = VaultSession(keyFileMemory: MemoryKeyFileKeychain(), folderAccess: sandboxedAccess(allowing: [directory.path]), writes: .inline)
        session.restore()
        XCTAssertTrue(session.creating)
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        XCTAssertFalse(session.locked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
    }
}
