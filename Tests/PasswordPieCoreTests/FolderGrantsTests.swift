import XCTest
@testable import PasswordPieCore

final class FolderGrantsTests: XCTestCase {
    func testADatabaseNeedsTheFolderThatHoldsIt() {
        XCTAssertEqual(FolderGrants.folder(for: "/Users/a/Dropbox/Passwords.kdbx"), "/Users/a/Dropbox")
    }

    func testAnOPVaultPackageNeedsTheFolderAroundThePackage() {
        XCTAssertEqual(FolderGrants.folder(for: "/Users/a/Vaults/Work.opvault/"), "/Users/a/Vaults")
    }

    func testAnAllowedFolderCoversTheDatabasesInItAndBelowIt() {
        let allowed = ["/Users/a/Dropbox"]
        XCTAssertTrue(FolderGrants.isCovered("/Users/a/Dropbox/Passwords.kdbx", by: allowed))
        XCTAssertTrue(FolderGrants.isCovered("/Users/a/Dropbox/Work/Team.kdbx", by: allowed))
    }

    func testAFolderWithTheSamePrefixIsNotCovered() {
        XCTAssertFalse(FolderGrants.isCovered("/Users/a/Dropbox2/Passwords.kdbx", by: ["/Users/a/Dropbox"]))
    }

    func testTheAppsOwnFolderAlwaysCovers() {
        let container = "/Users/a/Library/Containers/com.passwordpie/Data"
        XCTAssertTrue(FolderGrants.isCovered(container + "/Library/Application Support/PasswordPie/PasswordPie.kdbx", by: [container]))
    }

    func testNothingAllowedCoversNothing() {
        XCTAssertFalse(FolderGrants.isCovered("/Users/a/Documents/Passwords.kdbx", by: []))
    }

    func testTheRootFolderCoversEverything() {
        XCTAssertTrue(FolderGrants.isCovered("/Volumes/USB/Passwords.kdbx", by: ["/"]))
    }

    func testTheChosenFolderMustHoldTheDatabase() {
        XCTAssertTrue(FolderGrants.accepts(chosen: "/Users/a/Dropbox", for: "/Users/a/Dropbox/Passwords.kdbx"))
        XCTAssertTrue(FolderGrants.accepts(chosen: "/Users/a", for: "/Users/a/Dropbox/Passwords.kdbx"))
        XCTAssertFalse(FolderGrants.accepts(chosen: "/Users/a/Dropbox/Work", for: "/Users/a/Dropbox/Passwords.kdbx"))
        XCTAssertFalse(FolderGrants.accepts(chosen: "/Users/a/Desktop", for: "/Users/a/Dropbox/Passwords.kdbx"))
    }

    func testTrailingSlashesDoNotMatter() {
        XCTAssertTrue(FolderGrants.isCovered("/Users/a/Dropbox/Passwords.kdbx", by: ["/Users/a/Dropbox/"]))
        XCTAssertTrue(FolderGrants.accepts(chosen: "/Users/a/Dropbox/", for: "/Users/a/Dropbox/Passwords.kdbx"))
    }

    func testAFolderIsKeptOnlyWhileADatabaseInTheListNeedsIt() {
        let kept = FolderGrants.stillNeeded(
            ["/Users/a/Dropbox", "/Users/a/Desktop", "/Users/a"],
            by: ["/Users/a/Dropbox/Passwords.kdbx"]
        )
        XCTAssertEqual(kept, ["/Users/a/Dropbox", "/Users/a"])
    }
}
