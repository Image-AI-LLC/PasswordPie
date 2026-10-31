import XCTest
@testable import PasswordPieCore

final class SessionCatalogTests: XCTestCase {
    func testARemovedFileLeavesTheOpenListOnlyAfterItsSecretIsDeleted() {
        let opened = ["/vaults/main.kdbx", "/vaults/old.kdbx"]
        XCTAssertEqual(
            OpenedCatalog.afterRemoval(openedPaths: opened, removedPath: "/vaults/old.kdbx", secretDeleted: true),
            ["/vaults/main.kdbx"]
        )
        XCTAssertEqual(
            OpenedCatalog.afterRemoval(openedPaths: opened, removedPath: "/vaults/old.kdbx", secretDeleted: false),
            opened
        )
    }

    func testAFailedImportKeepsTheSourcePathAndRemembersTheWrittenFile() {
        let failed = ImportRetarget.decide(
            source: "/imports/work.opvault",
            destination: "/imports/work.kdbx",
            secretMoved: false
        )
        XCTAssertEqual(failed.openedPath, "/imports/work.opvault")
        XCTAssertEqual(failed.pendingPath, "/imports/work.kdbx")
        XCTAssertFalse(failed.retargetRoster)

        let moved = ImportRetarget.decide(
            source: "/imports/work.opvault",
            destination: "/imports/work.kdbx",
            secretMoved: true
        )
        XCTAssertEqual(moved.openedPath, "/imports/work.kdbx")
        XCTAssertNil(moved.pendingPath)
        XCTAssertTrue(moved.retargetRoster)

        let plain = ImportRetarget.decide(
            source: "/vaults/main.kdbx",
            destination: "/vaults/main.kdbx",
            secretMoved: true
        )
        XCTAssertEqual(plain.openedPath, "/vaults/main.kdbx")
        XCTAssertNil(plain.pendingPath)
        XCTAssertFalse(plain.retargetRoster)
    }

    func testARememberedSiblingIsReusedAfterLock() {
        let source = URL(fileURLWithPath: "/imports/work.opvault")
        let pending = "/imports/work.kdbx"
        let again = ImportDestination.url(source: source, pending: pending, exists: { _ in true })
        XCTAssertEqual(again.path, pending)
        let fresh = ImportDestination.url(source: source, pending: nil, exists: { $0 == "/imports/work.kdbx" })
        XCTAssertEqual(fresh.lastPathComponent, "work PasswordPie.kdbx")
    }

    func testALateSiblingLoadStopsAfterLockAndSkipsARemovedFile() {
        XCTAssertEqual(
            CatalogLoad.step(generation: 2, current: 2, pathStillListed: true),
            .publish
        )
        // lock() and a newer unlock both bump the generation.
        XCTAssertEqual(
            CatalogLoad.step(generation: 2, current: 3, pathStillListed: true),
            .stop
        )
        XCTAssertEqual(
            CatalogLoad.step(generation: 2, current: 2, pathStillListed: false),
            .skipFile
        )
    }
}
