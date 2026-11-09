import XCTest
@testable import PasswordPieCore

final class VaultFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vault-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testAFailedReadLeavesTheOriginalAndKeepsASnapshot() throws {
        let url = directory.appendingPathComponent("Passwords.kdbx")
        let original = try database(title: "Kept", password: "secret")
        try original.write(to: url)
        XCTAssertThrowsError(try VaultFile.replace(url, with: Data("not a database".utf8), password: "secret", expecting: Vault(entries: [])))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try Data(contentsOf: VaultFile.snapshotURL(for: url)), original)
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try mode(VaultFile.snapshotURL(for: url)), 0o600)
        XCTAssertTrue(leftoverWrites(in: directory).isEmpty)
    }

    func testAVerifiedWriteReplacesTheFileAndKeepsThePreviousSnapshot() throws {
        let url = directory.appendingPathComponent("Passwords.kdbx")
        let original = try database(title: "Before", password: "secret")
        try original.write(to: url)
        var vault = Vault(name: "After", entries: [account("After")], kdf: .fastTest)
        let saved = try KDBX.save(vault: &vault, password: "secret")
        try VaultFile.replace(url, with: saved, password: "secret", expecting: vault)
        let loaded = try KDBX.load(data: Data(contentsOf: url), password: "secret")
        XCTAssertEqual(loaded.entries.map(\.title), ["After"])
        let previous = try KDBX.load(data: Data(contentsOf: VaultFile.snapshotURL(for: url)), password: "secret")
        XCTAssertEqual(previous.entries.map(\.title), ["Before"])
        XCTAssertTrue(leftoverWrites(in: directory).isEmpty)
    }

    func testANewFileIsCreatedOnlyAfterItReadsBack() throws {
        let url = directory.appendingPathComponent("New.kdbx")
        XCTAssertThrowsError(try VaultFile.replace(url, with: Data("not a database".utf8), password: "secret", expecting: Vault(entries: [])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: VaultFile.snapshotURL(for: url).path))

        var vault = Vault(name: "New", entries: [account("Created")], kdf: .fastTest)
        let saved = try KDBX.save(vault: &vault, password: "secret")
        try VaultFile.replace(url, with: saved, password: "secret", expecting: vault)
        let loaded = try KDBX.load(data: Data(contentsOf: url), password: "secret")
        XCTAssertEqual(loaded.entries.map(\.title), ["Created"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: VaultFile.snapshotURL(for: url).path))
        XCTAssertEqual(try mode(url), 0o600)
    }

    func testAMismatchedAccountListDoesNotReplaceTheFile() throws {
        let url = directory.appendingPathComponent("Passwords.kdbx")
        let original = try database(title: "Kept", password: "secret")
        try original.write(to: url)
        var vault = Vault(name: "After", entries: [account("After")], kdf: .fastTest)
        let saved = try KDBX.save(vault: &vault, password: "secret")
        var other = vault
        other.entries = [VaultEntry()]
        XCTAssertThrowsError(try VaultFile.replace(url, with: saved, password: "secret", expecting: other))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try Data(contentsOf: VaultFile.snapshotURL(for: url)), original)
    }

    func testADiskChangeAfterTheSnapshotIsNotReplaced() throws {
        let url = directory.appendingPathComponent("Passwords.kdbx")
        let original = try database(title: "Kept", password: "secret")
        try original.write(to: url)
        var vault = Vault(name: "After", entries: [account("After")], kdf: .fastTest)
        let saved = try KDBX.save(vault: &vault, password: "secret")
        let intruder = Data("other-writer".utf8)
        XCTAssertThrowsError(try VaultFile.replace(url, with: saved, password: "secret", expecting: vault) {
            try intruder.write(to: url)
        })
        XCTAssertEqual(try Data(contentsOf: url), intruder)
        XCTAssertEqual(try Data(contentsOf: VaultFile.snapshotURL(for: url)), original)
        XCTAssertTrue(leftoverWrites(in: directory).isEmpty)
    }

    func testAFailedSnapshotLeavesTheOriginalAndNoStagingFile() throws {
        let url = directory.appendingPathComponent("Passwords.kdbx")
        let original = try database(title: "Kept", password: "secret")
        try original.write(to: url)
        var vault = Vault(name: "After", entries: [account("After")], kdf: .fastTest)
        let saved = try KDBX.save(vault: &vault, password: "secret")
        XCTAssertThrowsError(try VaultFile.replace(
            url, with: saved, password: "secret", expecting: vault,
            beforeSnapshotCommit: { throw VaultWriteError("stop") }, beforeReplace: {}
        ))
        XCTAssertEqual(try Data(contentsOf: url), original)
        let staging = VaultFile.snapshotURL(for: url).appendingPathExtension("incoming")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testAnAmpersandInANoteRoundTrips() throws {
        var entry = account("Amp")
        entry.notes = "Tom & Jerry &#0 leftover"
        var vault = Vault(name: "Amp", entries: [entry], kdf: .fastTest)
        let loaded = try KDBX.load(data: try KDBX.save(vault: &vault, password: "secret"), password: "secret")
        XCTAssertEqual(loaded.entries.first?.notes, "Tom & Jerry &#0 leftover")
    }

    private func account(_ title: String) -> VaultEntry {
        var entry = VaultEntry()
        entry.title = title
        entry.password = "secret"
        return entry
    }

    private func database(title: String, password: String) throws -> Data {
        var vault = Vault(name: title, entries: [account(title)], kdf: .fastTest)
        return try KDBX.save(vault: &vault, password: password)
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func leftoverWrites(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.contains(".passwordpie-write") }
    }
}

extension VaultFileTests {
    private func prepared(_ name: String = "Passwords.kdbx") throws -> (url: URL, baseline: Data, vault: Vault, saved: Data) {
        let url = directory.appendingPathComponent(name)
        let original = try database(title: "Before", password: "secret")
        try original.write(to: url)
        var vault = Vault(name: "After", entries: [account("After")], kdf: .fastTest)
        let saved = try KDBX.save(vault: &vault, password: "secret")
        return (url, original, vault, saved)
    }

    func testABaselineWriteKeepsThePreviousFileAsTheSnapshot() throws {
        let job = try prepared()
        try VaultFile.replace(job.url, with: job.saved, password: "secret", expecting: job.vault, baseline: job.baseline)
        XCTAssertEqual(try Data(contentsOf: job.url), job.saved)
        XCTAssertEqual(try Data(contentsOf: VaultFile.snapshotURL(for: job.url)), job.baseline)
        XCTAssertEqual(try mode(job.url), 0o600)
        XCTAssertTrue(leftoverWrites(in: directory).isEmpty)
    }

    func testABaselineConflictChangesNeitherTheFileNorTheSnapshot() throws {
        let job = try prepared()
        let earlierSnapshot = Data("earlier".utf8)
        try earlierSnapshot.write(to: VaultFile.snapshotURL(for: job.url))
        let theirs = Data("written by a sync client".utf8)
        try theirs.write(to: job.url)
        XCTAssertThrowsError(try VaultFile.replace(job.url, with: job.saved, password: "secret", expecting: job.vault, baseline: job.baseline))
        XCTAssertEqual(try Data(contentsOf: job.url), theirs)
        XCTAssertEqual(try Data(contentsOf: VaultFile.snapshotURL(for: job.url)), earlierSnapshot, "the last good snapshot is not spent on a write that never happened")
        XCTAssertTrue(leftoverWrites(in: directory).isEmpty)
    }

    func testAWriterLandingAfterTheCheckIsPutBack() throws {
        let job = try prepared()
        let theirs = Data("landed during the save".utf8)
        XCTAssertThrowsError(try VaultFile.replace(
            job.url, with: job.saved, password: "secret", expecting: job.vault,
            baseline: job.baseline, keepingSnapshot: true,
            beforeReplace: { try theirs.write(to: job.url) }
        ))
        XCTAssertEqual(try Data(contentsOf: job.url), theirs)
        XCTAssertTrue(leftoverWrites(in: directory).isEmpty)
    }

    func testAFailureAfterTheCommitIsNotAFailedWrite() throws {
        let job = try prepared()
        XCTAssertNoThrow(try VaultFile.replace(
            job.url, with: job.saved, password: "secret", expecting: job.vault,
            baseline: job.baseline, keepingSnapshot: true,
            beforeReplace: {},
            afterCommit: { throw VaultWriteError("permissions could not be set") }
        ))
        XCTAssertEqual(try Data(contentsOf: job.url), job.saved)
    }

    func testAMissingFileFailsABaselineWrite() throws {
        let job = try prepared()
        try FileManager.default.removeItem(at: job.url)
        XCTAssertThrowsError(try VaultFile.replace(job.url, with: job.saved, password: "secret", expecting: job.vault, baseline: job.baseline))
    }
}
