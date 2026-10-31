import XCTest
@testable import PasswordPieCore

final class DatabaseRosterTests: XCTestCase {
    func testOpeningAnotherFileKeepsThePreviousOne() {
        let roster = DatabaseRoster(current: "/vaults/a.kdbx")
            .selecting("/vaults/b.opvault")
        XCTAssertEqual(roster.current, "/vaults/b.opvault")
        XCTAssertEqual(roster.paths, ["/vaults/b.opvault", "/vaults/a.kdbx"])
    }

    func testSelectingAnExistingFileMovesItFirstWithoutDuplicating() {
        let roster = DatabaseRoster(current: "/vaults/a.kdbx", remembered: ["/vaults/b.kdbx", "/vaults/a.kdbx"])
            .selecting("/vaults/b.kdbx")
        XCTAssertEqual(roster.paths, ["/vaults/b.kdbx", "/vaults/a.kdbx"])
    }

    func testRemovingTheCurrentFileSelectsTheNext() {
        let roster = DatabaseRoster(current: "/vaults/a.kdbx", remembered: ["/vaults/b.kdbx", "/vaults/c.kdbx"])
            .removing("/vaults/a.kdbx")
        XCTAssertEqual(roster.current, "/vaults/b.kdbx")
        XCTAssertEqual(roster.paths, ["/vaults/b.kdbx", "/vaults/c.kdbx"])
    }

    func testReplacingAnImportKeepsTheCurrentFileAndDropsTheSource() {
        let roster = DatabaseRoster(current: "/vaults/main.kdbx", remembered: ["/imports/work.opvault"])
            .replacing("/imports/work.opvault", with: "/imports/work.kdbx")
        XCTAssertEqual(roster.current, "/vaults/main.kdbx")
        XCTAssertEqual(roster.paths, ["/vaults/main.kdbx", "/imports/work.kdbx"])
    }

    func testReplacingTheCurrentImportMakesTheKDBXCurrent() {
        let roster = DatabaseRoster(current: "/imports/work.opvault", remembered: ["/vaults/main.kdbx"])
            .replacing("/imports/work.opvault", with: "/imports/work.kdbx")
        XCTAssertEqual(roster.current, "/imports/work.kdbx")
        XCTAssertEqual(roster.paths, ["/imports/work.kdbx", "/vaults/main.kdbx"])
    }

    func testRemovingTheOnlyFileLeavesIt() {
        let roster = DatabaseRoster(current: "/vaults/a.kdbx")
        XCTAssertEqual(roster.removing("/vaults/a.kdbx"), roster)
    }

    func testTheListStopsAtTheLimitAndKeepsTheCurrentFile() {
        var remembered: [String] = []
        for index in 0..<40 { remembered.append("/vaults/\(index).kdbx") }
        let roster = DatabaseRoster(current: "/vaults/current.kdbx", remembered: remembered)
        XCTAssertEqual(roster.paths.count, DatabaseRoster.limit)
        XCTAssertEqual(roster.paths.first, "/vaults/current.kdbx")
    }

    func testASecretThatCannotBeDeletedStaysPastTheLimit() {
        var remembered: [String] = []
        for index in 0..<DatabaseRoster.limit { remembered.append("/vaults/\(index).kdbx") }
        let full = DatabaseRoster(current: "/vaults/0.kdbx", remembered: remembered)
        let kept = full.keeping(["/vaults/evicted.kdbx"])
        XCTAssertEqual(kept.paths.count, DatabaseRoster.limit + 1)
        XCTAssertTrue(kept.paths.contains("/vaults/evicted.kdbx"))
    }

    func testDuplicateNamesIncludeTheParentFolder() {
        let titles = DatabaseRoster.menuTitles(for: [
            "/work/vault.kdbx",
            "/home/vault.kdbx",
            "/home/other.opvault"
        ])
        XCTAssertEqual(titles, ["vault.kdbx — work", "vault.kdbx — home", "other.opvault"])
    }

    func testDuplicateNamesWalkUpUntilTheTitlesDiffer() {
        let titles = DatabaseRoster.menuTitles(for: [
            "/a/work/vault.kdbx",
            "/b/work/vault.kdbx"
        ])
        XCTAssertEqual(titles, ["vault.kdbx — a/work", "vault.kdbx — b/work"])
    }

    func testASavedRosterAboveTheCapLoadsWhole() {
        var remembered: [String] = []
        for index in 0..<40 { remembered.append("/vaults/\(index).kdbx") }
        let loaded = DatabaseRoster(current: "/vaults/0.kdbx", remembered: remembered, limit: remembered.count + 1)
        XCTAssertEqual(loaded.paths.count, 40)
        let opened = loaded.selecting("/vaults/new.kdbx")
        XCTAssertEqual(opened.paths.count, DatabaseRoster.limit)
        XCTAssertEqual(opened.paths.first, "/vaults/new.kdbx")
    }

    func testUnlockMemoryNeedsTouchIDAndConsent() {
        XCTAssertTrue(UnlockMemory.shouldStore(hardware: true, declined: false))
        XCTAssertFalse(UnlockMemory.shouldStore(hardware: false, declined: false))
        XCTAssertFalse(UnlockMemory.shouldStore(hardware: true, declined: true))
        XCTAssertFalse(UnlockMemory.shouldStore(hardware: false, declined: false, alreadyEnabled: true))
        XCTAssertTrue(UnlockMemory.shouldStore(hardware: true, declined: true, alreadyEnabled: true))
    }
}

final class StoredUnlockTests: XCTestCase {
    func testPasswordOnlyStaysCompatibleWithTheOldKeychainItem() {
        let stored = StoredUnlock(password: "secret")
        XCTAssertEqual(stored.encoded, Data("secret".utf8))
        XCTAssertEqual(StoredUnlock(stored: Data("secret".utf8)), stored)
    }

    func testKeyFileRoundTrip() {
        let stored = StoredUnlock(password: "secret", keyFile: Data("key-bytes".utf8))
        let decoded = StoredUnlock(stored: stored.encoded)
        XCTAssertEqual(decoded, stored)
    }

    func testEmptyPasswordWithKeyFileRoundTrip() {
        let stored = StoredUnlock(password: "", keyFile: Data([1, 2, 3, 4]))
        XCTAssertEqual(StoredUnlock(stored: stored.encoded), stored)
    }

    func testAPasswordThatStartsWithTheMarkerStaysAPassword() {
        let password = "PPKFnot-an-envelope"
        let decoded = StoredUnlock(stored: Data(password.utf8))
        XCTAssertEqual(decoded, StoredUnlock(password: password))
    }

    func testEmptyDataIsNotASecret() {
        XCTAssertNil(StoredUnlock(stored: Data()))
    }
}

final class EntryCatalogTests: XCTestCase {
    func testMergeKeepsBothFilesAndTheFirstId() {
        let shared = UUID()
        var home = VaultEntry(id: shared)
        home.title = "Home"
        var work = VaultEntry(id: UUID())
        work.title = "Work"
        let merged = EntryCatalog.merge([
            ("/home/vault.kdbx", [home]),
            ("/work/vault.kdbx", [work]),
        ])
        XCTAssertEqual(merged.map(\.entry.title), ["Home", "Work"])
        XCTAssertEqual(merged.map(\.listID), [shared, work.id])
        XCTAssertEqual(merged.map(\.path), ["/home/vault.kdbx", "/work/vault.kdbx"])
    }

    func testARepeatedIdStaysInBothFilesWithAStableStandIn() {
        let shared = UUID()
        var first = VaultEntry(id: shared)
        first.title = "Bank"
        var second = VaultEntry(id: shared)
        second.title = "Bank copy"
        let groups = [
            ("/a/one.kdbx", [first]),
            ("/b/two.kdbx", [second]),
        ]
        let once = EntryCatalog.merge(groups)
        let twice = EntryCatalog.merge(groups)
        XCTAssertEqual(once.map(\.listID), twice.map(\.listID))
        XCTAssertEqual(once[0].listID, shared)
        XCTAssertNotEqual(once[1].listID, shared)
        XCTAssertEqual(once[1].entry.id, shared)
        XCTAssertEqual(EntryCatalog.storedEntries(path: "/b/two.kdbx", merged: once).map(\.id), [shared])
        XCTAssertEqual(EntryCatalog.storedEntries(path: "/a/one.kdbx", merged: once).map(\.title), ["Bank"])
    }

    func testSearchSeesEntriesFromEveryFile() {
        var home = VaultEntry()
        home.title = "Home Mail"
        var work = VaultEntry()
        work.title = "Work Mail"
        let merged = EntryCatalog.merge([
            ("/home/vault.kdbx", [home]),
            ("/work/vault.kdbx", [work]),
        ]).map(\.entry)
        XCTAssertEqual(searchEntries(merged, query: "mail", scope: .major).map(\.title), ["Home Mail", "Work Mail"])
    }
}
