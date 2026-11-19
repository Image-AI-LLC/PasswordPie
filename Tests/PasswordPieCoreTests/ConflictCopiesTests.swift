import Foundation
@testable import PasswordPieCore
import XCTest

/// The names sync tools give the copy they keep when two Macs changed a file (`ConflictCopies.swift`, where each name's
/// source is given).
final class ConflictCopiesTests: XCTestCase {
    private func kind(_ name: String, database: String = "Passwords.kdbx") -> String? {
        ConflictCopies.kind(ofFileNamed: name, besideDatabaseNamed: database).map { "\($0.tool.rawValue) \($0.certain ? "certain" : "offered")" }
    }

    func testSyncthing() {
        XCTAssertEqual(kind("Passwords.sync-conflict-20261120-031800-ABCDEFG.kdbx"), "Syncthing certain")
        // A conflict of a conflict copy.
        XCTAssertEqual(kind("Passwords.sync-conflict-20261120-031800-ABCDEFG.sync-conflict-20261121-101500-HIJKLMN.kdbx"), "Syncthing certain")
        XCTAssertNil(kind("Passwords.sync-conflict-20261120-031800-ABCDEFG.txt"))
        XCTAssertNil(kind("Other.sync-conflict-20261120-031800-ABCDEFG.kdbx"))
    }

    func testDropbox() {
        XCTAssertEqual(kind("Passwords (Ada's conflicted copy 2026-11-20).kdbx"), "Dropbox certain")
        XCTAssertEqual(kind("Passwords (MacBook Air conflicted copy 2026-11-20 (1)).kdbx"), "Dropbox certain")
        XCTAssertNil(kind("Other (Ada's conflicted copy 2026-11-20).kdbx"))
    }

    func testUnisonWithCopyOnConflict() {
        XCTAssertEqual(kind("Passwords.kdbx (conflict_on_2026-11-20)"), "Unison certain")
        XCTAssertEqual(kind("Passwords.kdbx (conflict #2_on_2026-11-20)"), "Unison certain")
        XCTAssertNil(kind("Passwords.kdbx (conflict_on_2026-11-20_was_deleted)"), "a marker that the file was deleted holds no database")
        XCTAssertNil(kind(".bak.1.Passwords.kdbx"), "a Unison backup is an earlier version, not the other Mac's")
    }

    func testANameAPersonCouldHaveGivenIsOfferedNeverCertain() {
        XCTAssertEqual(kind("Passwords 2.kdbx"), " offered")
        XCTAssertEqual(kind("Passwords 13.kdbx"), " offered")
        XCTAssertEqual(kind("Passwords (old).kdbx"), " offered")
        XCTAssertEqual(kind("Passwords (Adas in Konflikt stehende Kopie 2026-11-20).kdbx"), " offered")
    }

    func testOtherFilesBesideTheDatabaseAreNotCopies() {
        for name in [
            "Passwords.kdbx", "Passwords.kdbx.snapshot", "Passwords.kdbx.before-merge-20261120-031800",
            "Passwords.kdbx.damaged-20261120-031800", ".Passwords.kdbx.1234.passwordpie-write",
            ".syncthing.Passwords.kdbx.tmp", "Passwords copy.kdbx", "Passwords2.kdbx", "Passwords-work.kdbx",
            "Passwords.key", "PasswordsOld.kdbx", "Passwords .kdbx", "Notes.txt"
        ] {
            XCTAssertNil(kind(name), name)
        }
    }

    func testADatabaseWithoutAnExtensionAndOneWithDotsInItsName() {
        XCTAssertEqual(kind("vault.sync-conflict-20261120-031800-ABCDEFG", database: "vault"), "Syncthing certain")
        XCTAssertEqual(kind("my.work.sync-conflict-20261120-031800-ABCDEFG.kdbx", database: "my.work.kdbx"), "Syncthing certain")
        XCTAssertEqual(kind("Passwords.sync-conflict-20261120-031800-ABCDEFG.KDBX", database: "Passwords.kdbx"), "Syncthing certain")
    }

    func testFindingCopiesBesideADatabaseListsFilesOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conflict-copies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("Passwords.kdbx")
        for name in ["Passwords.kdbx", "Passwords.sync-conflict-20261120-031800-ABCDEFG.kdbx", "Passwords 2.kdbx", "Passwords.kdbx.snapshot", "Other.kdbx"] {
            try Data("x".utf8).write(to: directory.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Passwords (Ada's conflicted copy 2026-11-20).kdbx"), withIntermediateDirectories: false)

        let found = ConflictCopies.find(beside: database)
        XCTAssertEqual(found.map(\.name), ["Passwords 2.kdbx", "Passwords.sync-conflict-20261120-031800-ABCDEFG.kdbx"])
        XCTAssertEqual(found.map(\.certain), [false, true])
        XCTAssertEqual(found.map(\.tool), [.unknown, .syncthing])
        XCTAssertEqual(found.map(\.isFileVersion), [false, false])
        XCTAssertEqual(ConflictCopies.find(beside: directory.appendingPathComponent("Missing.kdbx")), [])
    }
}
