import Foundation
@testable import PasswordPieCore
import XCTest

/// Saving and reading a database that a sync tool replaces (`VaultFile+Merge.swift`). A second copy of the fixture
/// written over the file stands in for the other Mac's version arriving.
final class VaultFileMergeTests: XCTestCase {
    private var directory: URL!
    private var url: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vault-file-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("Passwords.kdbx")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// This Mac opens `copy` from the file.
    private func open(_ copy: MergeCopy) throws -> Vault {
        try copy.data().write(to: url)
        return try VaultFile.openRecovering(url: url, password: "secret")
    }

    /// The sync tool replaces the file with the other Mac's version.
    @discardableResult
    private func arrive(_ copy: MergeCopy, password: String = "secret") throws -> Data {
        let data = try copy.data(password: password)
        try data.write(to: url, options: .atomic)
        return data
    }

    private func onDisk() throws -> Vault {
        try KDBX.load(data: Data(contentsOf: url), password: "secret")
    }

    private var backups: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.contains(".before-merge-") }.sorted()
    }

    private let bank = MergeItem(0xA1, "Bank", password: "old")
    private let mail = MergeItem(0xA2, "Mail", password: "mail")

    // MARK: Saving

    func testASaveOverAFileThatWasReplacedMergesInsteadOfWritingOverIt() throws {
        var mine = try open(MergeCopy(items: [bank, mail]))
        let ours = try XCTUnwrap(mine.fileBaseline)
        // The other Mac changed Mail and added a key. This Mac now changes Bank.
        let theirs = try arrive(MergeCopy(items: [bank, MergeItem(0xA2, "Mail", password: "new-mail", modified: 20, history: [mail]), MergeItem(0xA3, "Key", modified: 5)]))
        mine.entries[0].password = "new-bank"

        let saved = try VaultFile.save(mine, to: url, password: "secret", keyFile: nil)

        XCTAssertTrue(saved.wrote)
        let file = try onDisk()
        XCTAssertEqual(file.item(0xA1)?.password, "new-bank")
        XCTAssertEqual(file.item(0xA2)?.password, "new-mail")
        XCTAssertNotNil(file.item(0xA3))
        XCTAssertEqual(saved.vault.fileBaseline, try Data(contentsOf: url))
        XCTAssertEqual(mergeContents(saved.vault), mergeContents(file))
        XCTAssertEqual(saved.merge?.changedOnBoth, [])
        // Both versions from before the merge are kept: the other Mac's as the snapshot, this Mac's as a dated copy.
        XCTAssertEqual(try Data(contentsOf: VaultFile.snapshotURL(for: url)), theirs)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(saved.backup)), ours)
        XCTAssertEqual(saved.backup?.lastPathComponent, backups.first)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: XCTUnwrap(saved.backup).path)[.posixPermissions] as? Int, 0o600)
    }

    func testASaveOfTheSameItemTheOtherMacChangedKeepsTheirVersionInTheHistoryAndListsIt() throws {
        var mine = try open(MergeCopy(items: [bank]))
        try arrive(MergeCopy(items: [MergeItem(0xA1, "Bank", password: "theirs", modified: 20, history: [bank])]))
        mine.entries[0].password = "mine-now"

        let saved = try VaultFile.save(mine, to: url, password: "secret", keyFile: nil)

        let file = try onDisk()
        XCTAssertEqual(file.item(0xA1)?.password, "mine-now")
        XCTAssertEqual(file.historyPasswords(0xA1), ["old", "theirs"])
        XCTAssertEqual(saved.merge?.changedOnBoth.map(\.id), [mergeID(0xA1)])
    }

    func testASaveOfAFileNobodyReplacedWritesItAsBefore() throws {
        var mine = try open(MergeCopy(items: [bank]))
        let before = try Data(contentsOf: url)
        mine.entries[0].password = "new"

        let saved = try VaultFile.save(mine, to: url, password: "secret", keyFile: nil)

        XCTAssertTrue(saved.wrote)
        XCTAssertNil(saved.merge)
        XCTAssertNil(saved.backup)
        XCTAssertEqual(backups, [])
        XCTAssertEqual(try onDisk().item(0xA1)?.password, "new")
        XCTAssertEqual(try Data(contentsOf: VaultFile.snapshotURL(for: url)), before)
    }

    // MARK: Reading a replaced file

    func testAReplacedFileThatHoldsEverythingIsReadAndNothingIsWritten() throws {
        let mine = try open(MergeCopy(items: [bank]))
        let theirs = try arrive(MergeCopy(items: [MergeItem(0xA1, "Bank", password: "theirs", modified: 20, history: [bank]), mail]))

        let followed = try VaultFile.save(mine, to: url, password: "secret", keyFile: nil, onlyIfNeeded: true)

        XCTAssertFalse(followed.wrote)
        XCTAssertEqual(try Data(contentsOf: url), theirs, "the other Mac's file is left exactly as it arrived")
        XCTAssertEqual(followed.vault.item(0xA1)?.password, "theirs")
        XCTAssertNotNil(followed.vault.item(0xA2))
        XCTAssertEqual(followed.vault.fileBaseline, theirs)
        XCTAssertEqual(backups, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: VaultFile.snapshotURL(for: url).path))
    }

    func testAReplacedFileThatLacksWhatThisMacHasIsMergedAndWritten() throws {
        // This Mac saved a change the other Mac never saw; then the other Mac's version won at the sync tool.
        let mine = try open(MergeCopy(items: [MergeItem(0xA1, "Bank", password: "mine", modified: 10, history: [bank])]))
        let ours = try XCTUnwrap(mine.fileBaseline)
        try arrive(MergeCopy(items: [bank, mail]))

        let followed = try VaultFile.save(mine, to: url, password: "secret", keyFile: nil, onlyIfNeeded: true)

        XCTAssertTrue(followed.wrote)
        let file = try onDisk()
        XCTAssertEqual(file.item(0xA1)?.password, "mine")
        XCTAssertNotNil(file.item(0xA2))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(followed.backup)), ours)
        // Read again, there is nothing left to do.
        let again = try VaultFile.save(followed.vault, to: url, password: "secret", keyFile: nil, onlyIfNeeded: true)
        XCTAssertFalse(again.wrote)
        XCTAssertNil(again.merge)
    }

    func testAFileNobodyReplacedIsNotReadAgain() throws {
        let mine = try open(MergeCopy(items: [bank]))
        let before = try Data(contentsOf: url)
        let followed = try VaultFile.save(mine, to: url, password: "secret", keyFile: nil, onlyIfNeeded: true)
        XCTAssertFalse(followed.wrote)
        XCTAssertNil(followed.merge)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(followed.vault, mine)
    }

    func testAReplacedFileThatDoesNotOpenWithOurKeysIsLeftAloneAndNothingIsWritten() throws {
        var mine = try open(MergeCopy(items: [bank]))
        let theirs = try arrive(MergeCopy(items: [bank, mail]), password: "changed on the other Mac")
        mine.entries[0].password = "new"

        for onlyIfNeeded in [true, false] {
            XCTAssertThrowsError(try VaultFile.save(mine, to: url, password: "secret", keyFile: nil, onlyIfNeeded: onlyIfNeeded)) { error in
                XCTAssertTrue((error as? VaultWriteError)?.description.contains("does not open with this master password") == true, "\(error)")
            }
            XCTAssertEqual(try Data(contentsOf: url), theirs)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: VaultFile.snapshotURL(for: url).path))
        XCTAssertEqual(backups, [])
    }

    /// Two databases with one master password: the other one landing at this one's path is not a newer version of it.
    func testAReplacedFileThatIsAnotherDatabaseIsLeftAloneAndNotMergedIn() throws {
        var mine = try open(MergeCopy(items: [bank]))
        var another = MergeCopy(items: [MergeItem(0xB1, "From another database")])
        another.root.id = 0x99
        let theirs = try arrive(another)
        mine.entries[0].password = "new"

        for onlyIfNeeded in [true, false] {
            XCTAssertThrowsError(try VaultFile.save(mine, to: url, password: "secret", keyFile: nil, onlyIfNeeded: onlyIfNeeded)) { error in
                XCTAssertTrue((error as? VaultWriteError)?.description.contains("replaced on disk by another database") == true, "\(error)")
            }
            XCTAssertEqual(try Data(contentsOf: url), theirs)
        }
        XCTAssertEqual(backups, [])
        // A copy the caller chose to merge in may be any database.
        try arrive(MergeCopy(items: [bank]))
        let chosen = try VaultFile.save(try VaultFile.openRecovering(url: url, password: "secret"), to: url, password: "secret", keyFile: nil, merging: try another.vault(), onlyIfNeeded: true)
        XCTAssertNotNil(chosen.vault.item(0xB1))
    }

    /// A vault that cannot be merged never writes over a file it was not read from.
    func testAVaultThatCannotBeMergedDoesNotWriteOverAReplacedFile() throws {
        try MergeCopy(items: [bank]).data().write(to: url)
        var unmergeable = Vault(entries: [VaultEntry(fields: [VaultField(key: "Title", value: "New")])], kdf: .fastTest)
        unmergeable.noteFileContents(Data("what it was read from".utf8))
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try VaultFile.save(unmergeable, to: url, password: "secret", keyFile: nil)) { error in
            XCTAssertTrue((error as? VaultWriteError)?.description.contains("cannot be merged") == true, "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    /// A vault that was never read from the file is not written over a file that is there, merged or not.
    func testAVaultWithNoBaselineDoesNotWriteOverAFileThatIsThere() throws {
        let theirs = try arrive(MergeCopy(items: [bank]))
        let fresh = Vault(entries: [VaultEntry(fields: [VaultField(key: "Title", value: "New")])], kdf: .fastTest)
        for onlyIfNeeded in [true, false] {
            XCTAssertThrowsError(try VaultFile.save(fresh, to: url, password: "secret", keyFile: nil, onlyIfNeeded: onlyIfNeeded)) { error in
                XCTAssertTrue((error as? VaultWriteError)?.description.contains("this database was not read from it") == true, "\(error)")
            }
            XCTAssertEqual(try Data(contentsOf: url), theirs)
        }
    }

    func testAFileThatArrivesWhileASaveOfANewDatabaseIsPreparedIsNotWrittenOver() throws {
        let fresh = Vault(entries: [VaultEntry(fields: [VaultField(key: "Title", value: "New")])], kdf: .fastTest)
        var theirs: Data?
        XCTAssertThrowsError(try VaultFile.save(fresh, to: url, password: "secret", keyFile: nil, now: Date(), afterRead: {
            guard theirs == nil else { return }
            theirs = try self.arrive(MergeCopy(items: [self.bank]))
        }, beforeReplace: {}))
        XCTAssertNotNil(theirs)
        XCTAssertEqual(try Data(contentsOf: url), theirs)
    }

    /// Nobody asked for this read, and a header is untrusted until a key opens the file: a key derivation that is not
    /// this database's own is never run for it.
    func testAReplacedFileThatAsksForOtherKeySettingsIsNotOpened() throws {
        var mine = try open(MergeCopy(items: [bank]))
        let other = try KDBX.testingDatabase(xml: MergeCopy(items: [bank, mail]).xml, password: "secret", kdf: KDFParameters(kind: .aes(rounds: 200)))
        try other.write(to: url, options: .atomic)
        mine.entries[0].password = "new"

        for onlyIfNeeded in [true, false] {
            XCTAssertThrowsError(try VaultFile.save(mine, to: url, password: "secret", keyFile: nil, onlyIfNeeded: onlyIfNeeded)) { error in
                XCTAssertTrue((error as? VaultWriteError)?.description.contains("asks for other key settings") == true, "\(error)")
            }
            XCTAssertEqual(try Data(contentsOf: url), other)
        }
    }

    func testTheKeySettingsAFileAsksForAreReadFromItsStartWithoutDerivingAnything() throws {
        let data = try MergeCopy(items: [bank]).data()
        XCTAssertEqual(KDBX.kdf(ofHeader: data), .aes(rounds: 100))
        XCTAssertEqual(KDBX.kdf(ofHeader: data.prefix(400)), .aes(rounds: 100), "the header is enough")
        XCTAssertNil(KDBX.kdf(ofHeader: Data("not a database".utf8)))
        XCTAssertNil(KDBX.kdf(ofHeader: Data(repeating: 0, count: 2 * KDBX.headerLimit)))

        // A header asking for more memory than a number in this app can hold is refused, not acted on.
        let argon = try KDBX.testingDatabase(
            xml: MergeCopy(items: [bank]).xml, password: "secret",
            kdf: KDFParameters(kind: .argon2id(memoryKiB: 1024, iterations: 1, parallelism: 1, version: 0x13))
        )
        XCTAssertEqual(KDBX.kdf(ofHeader: argon), .argon2id(memoryKiB: 1024, iterations: 1, parallelism: 1, version: 0x13))
        // The variant entry "M": type 5, a 1-byte name, an 8-byte value.
        let entry = Data([0x05, 0x01, 0x00, 0x00, 0x00, UInt8(ascii: "M"), 0x08, 0x00, 0x00, 0x00])
        let place = try XCTUnwrap(argon.range(of: entry))
        var hostile = argon
        hostile.replaceSubrange(place.upperBound..<(place.upperBound + 8), with: Data(repeating: 0xFF, count: 8))
        XCTAssertNil(KDBX.kdf(ofHeader: hostile))
        XCTAssertThrowsError(try KDBX.load(data: hostile, password: "secret"))
    }

    func testAReplacedFileThatIsNotADatabaseIsLeftAlone() throws {
        let mine = try open(MergeCopy(items: [bank]))
        try Data("half a file".utf8).write(to: url)
        XCTAssertThrowsError(try VaultFile.save(mine, to: url, password: "secret", keyFile: nil, onlyIfNeeded: true)) { error in
            XCTAssertTrue((error as? VaultWriteError)?.description.contains("could not be read") == true, "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("half a file".utf8))
    }

    func testAFileReplacedAgainWhileItIsBeingWrittenIsMergedToo() throws {
        var mine = try open(MergeCopy(items: [bank, mail]))
        mine.entries[0].password = "new-bank"
        var arrivals = 0

        let saved = try VaultFile.save(mine, to: url, password: "secret", keyFile: nil, now: Date()) {
            // Between this save reading the file and replacing it, the other Mac's version lands. Once.
            guard arrivals == 0 else { return }
            arrivals += 1
            try self.arrive(MergeCopy(items: [self.bank, self.mail, MergeItem(0xA3, "Arrived meanwhile", modified: 5)]))
        }

        XCTAssertTrue(saved.wrote)
        let file = try onDisk()
        XCTAssertEqual(file.item(0xA1)?.password, "new-bank")
        XCTAssertNotNil(file.item(0xA3), "the version that landed during the save was not written over")
    }

    /// The narrowest window: the other Mac's version lands after this save read the file and before it starts to
    /// replace it. The file is replaced only while it is still what was read.
    func testAFileReplacedRightAfterItWasReadIsNotWrittenOver() throws {
        var mine = try open(MergeCopy(items: [bank, mail]))
        mine.entries[0].password = "new-bank"
        var arrivals = 0

        let saved = try VaultFile.save(mine, to: url, password: "secret", keyFile: nil, now: Date(), afterRead: {
            guard arrivals == 0 else { return }
            arrivals += 1
            try self.arrive(MergeCopy(items: [self.bank, self.mail, MergeItem(0xA3, "Arrived meanwhile", modified: 5)]))
        }, beforeReplace: {})

        XCTAssertTrue(saved.wrote)
        let file = try onDisk()
        XCTAssertEqual(file.item(0xA1)?.password, "new-bank")
        XCTAssertNotNil(file.item(0xA3))
        XCTAssertNotNil(saved.vault.item(0xA3))
    }

    // MARK: Merging a copy in

    func testMergingACopyInWritesTheFileAndKeepsTheFileFromBefore() throws {
        let mine = try open(MergeCopy(items: [bank]))
        let before = try Data(contentsOf: url)
        let copy = try MergeCopy(items: [bank, mail]).vault()

        let saved = try VaultFile.save(mine, to: url, password: "secret", keyFile: nil, merging: copy, onlyIfNeeded: true)

        XCTAssertTrue(saved.wrote)
        XCTAssertEqual(saved.merge?.added, 1)
        XCTAssertNotNil(try onDisk().item(0xA2))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(saved.backup)), before)
        XCTAssertEqual(try Data(contentsOf: VaultFile.snapshotURL(for: url)), before)

        // The same copy again has nothing to add: the file is not written and no copy is kept.
        let written = try Data(contentsOf: url)
        let again = try VaultFile.save(saved.vault, to: url, password: "secret", keyFile: nil, merging: copy, onlyIfNeeded: true)
        XCTAssertFalse(again.wrote)
        XCTAssertEqual(again.merge?.changed, false)
        XCTAssertEqual(try Data(contentsOf: url), written)
        XCTAssertEqual(backups.count, 1)
    }

    func testMergingACopyInAlsoTakesInAFileThatWasReplacedMeanwhile() throws {
        let mine = try open(MergeCopy(items: [bank]))
        try arrive(MergeCopy(items: [bank, mail]))
        let copy = try MergeCopy(items: [bank, MergeItem(0xA3, "From the copy", modified: 5)]).vault()

        let saved = try VaultFile.save(mine, to: url, password: "secret", keyFile: nil, merging: copy, onlyIfNeeded: true)

        XCTAssertEqual(Set(try onDisk().entries.map(\.title)), ["Bank", "Mail", "From the copy"])
        XCTAssertEqual(saved.merge?.added, 1)
    }

    func testOnlyTheNewestCopiesFromBeforeAMergeAreKept() throws {
        let start = Date(timeIntervalSince1970: 1_780_272_000)
        var made: [String] = []
        for number in 0..<(VaultFile.mergeBackupsKept + 2) {
            let backup = try VaultFile.keepMergeBackup(Data("version \(number)".utf8), of: url, now: start.addingTimeInterval(TimeInterval(number * 60)))
            made.append(backup.lastPathComponent)
        }
        XCTAssertEqual(backups, Array(made.suffix(VaultFile.mergeBackupsKept)))
        XCTAssertEqual(made.first, "Passwords.kdbx.before-merge-20260601-000000")
        // The same bytes again are the copy that is already there.
        let same = try VaultFile.keepMergeBackup(Data("version \(VaultFile.mergeBackupsKept + 1)".utf8), of: url, now: start.addingTimeInterval(9999))
        XCTAssertEqual(same.lastPathComponent, made.last)
        XCTAssertEqual(backups.count, VaultFile.mergeBackupsKept)
        // Two merges in one second do not write over each other.
        let one = try VaultFile.keepMergeBackup(Data("a".utf8), of: url, now: start.addingTimeInterval(20_000))
        let two = try VaultFile.keepMergeBackup(Data("b".utf8), of: url, now: start.addingTimeInterval(20_000))
        XCTAssertNotEqual(one, two)
        XCTAssertEqual(try Data(contentsOf: one), Data("a".utf8))
    }

    /// A copy from before a merge opens with the keys the database had then. After a key change that would be a way
    /// round the new keys, lying beside the database in a folder that may be shared.
    func testAKeyChangeRemovesTheCopiesFromBeforeAMerge() throws {
        var mine = try open(MergeCopy(items: [bank]))
        let baseline = try XCTUnwrap(mine.fileBaseline)
        _ = try VaultFile.keepMergeBackup(Data("an earlier version".utf8), of: url, now: Date(timeIntervalSince1970: 1_780_272_000))
        _ = try VaultFile.keepMergeBackup(baseline, of: url, now: Date(timeIntervalSince1970: 1_780_272_060))
        try Data("not ours".utf8).write(to: directory.appendingPathComponent("Passwords.kdbx.before-something-else"))
        XCTAssertEqual(backups.count, 2)

        let result = try VaultFile.rekey(url, vault: &mine, password: "a new password", keyFile: nil, baseline: baseline)

        XCTAssertEqual(backups, [])
        XCTAssertEqual(result.staleCopies, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Passwords.kdbx.before-something-else").path))
        XCTAssertNoThrow(try KDBX.load(data: Data(contentsOf: url), password: "a new password"))
    }

    /// A folder that cannot be listed is not a folder with nothing to remove.
    func testAKeyChangeReportsTheCopiesWhenTheFolderCannotBeListed() throws {
        var mine = try open(MergeCopy(items: [bank]))
        let baseline = try XCTUnwrap(mine.fileBaseline)
        _ = try VaultFile.keepMergeBackup(Data("an earlier version".utf8), of: url, now: Date(timeIntervalSince1970: 1_780_272_000))
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        let result = try VaultFile.rekey(url, vault: &mine, password: "a new password", keyFile: nil, baseline: baseline)
        XCTAssertEqual(result.staleCopies, ["Passwords.kdbx.before-merge-*"])
    }

    /// Copies that came from a Mac whose clock is ahead sort after the one made now, which must stay all the same.
    func testTheCopyJustMadeIsKeptWhenOtherCopiesCarryLaterTimes() throws {
        let now = Date(timeIntervalSince1970: 1_780_272_000)
        for number in 1...VaultFile.mergeBackupsKept {
            _ = try VaultFile.keepMergeBackup(Data("ahead \(number)".utf8), of: url, now: now.addingTimeInterval(TimeInterval(number * 3600)))
        }
        let made = try VaultFile.keepMergeBackup(Data("made now".utf8), of: url, now: now)
        XCTAssertEqual(try Data(contentsOf: made), Data("made now".utf8))
    }

    /// A vault that could be merged but was never read from this file: another database there is still left alone.
    func testAVaultWithNoBaselineIsNotMergedIntoAnotherDatabaseThatIsThere() throws {
        var another = MergeCopy(items: [MergeItem(0xB1, "From another database")])
        another.root.id = 0x99
        let theirs = try arrive(another)
        let mine = try KDBX.load(data: try MergeCopy(items: [bank]).data(), password: "secret")
        XCTAssertThrowsError(try VaultFile.save(mine, to: url, password: "secret", keyFile: nil)) { error in
            XCTAssertEqual((error as? VaultWriteError)?.description, "Passwords.kdbx is already there and is another database, so nothing was changed.")
        }
        XCTAssertEqual(try Data(contentsOf: url), theirs)
    }

    func testAMergeThatCannotKeepACopyFromBeforeChangesNothing() throws {
        var mine = try open(MergeCopy(items: [bank]))
        let theirs = try arrive(MergeCopy(items: [bank, mail]))
        mine.entries[0].password = "new"
        // A folder where the copy would go.
        let stamp = Date(timeIntervalSince1970: 1_780_272_000)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Passwords.kdbx.before-merge-20260601-000000"), withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        XCTAssertThrowsError(try VaultFile.save(mine, to: url, password: "secret", keyFile: nil, now: stamp, beforeReplace: {})) { error in
            XCTAssertTrue((error as? VaultWriteError)?.description.contains("could not be kept") == true, "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: url), theirs)
    }

    // MARK: Two Macs

    /// The acceptance run in small: two Macs, each with its own copy of the file and its own open database. `carry`
    /// stands in for the sync tool taking one Mac's file to the other.
    func testTwoMacsEndWithTheSameDatabaseAndStopWriting() throws {
        let other = directory.appendingPathComponent("other-mac.kdbx")
        let start = MergeCopy(items: [bank, mail, MergeItem(0xA4, "To delete")], groups: [mergeBin()])
        try start.data().write(to: url)
        try FileManager.default.copyItem(at: url, to: other)
        var pro = try VaultFile.openRecovering(url: url, password: "secret")
        var air = try VaultFile.openRecovering(url: other, password: "secret")

        // Offline from each other: the Air adds a key, the Pro changes Bank and moves an item to the bin. Both change Mail.
        air.entries.append(VaultEntry(fields: [VaultField(key: "Title", value: "New key"), VaultField(key: "Password", value: "k", protected: true)]))
        air.entries[1].password = "mail-air"
        air = try VaultFile.save(air, to: other, password: "secret", keyFile: nil).vault
        Thread.sleep(forTimeInterval: 1.1)
        pro.entries[0].password = "bank-pro"
        pro.entries[1].password = "mail-pro"
        pro.entries[2].trashed = true
        pro = try VaultFile.save(pro, to: url, password: "secret", keyFile: nil).vault

        // The Air's file reaches the Pro, which reads it and writes the merge. That file reaches the Air.
        try Data(contentsOf: other).write(to: url, options: .atomic)
        let atPro = try VaultFile.save(pro, to: url, password: "secret", keyFile: nil, onlyIfNeeded: true)
        XCTAssertTrue(atPro.wrote)
        try Data(contentsOf: url).write(to: other, options: .atomic)
        let atAir = try VaultFile.save(air, to: other, password: "secret", keyFile: nil, onlyIfNeeded: true)
        XCTAssertFalse(atAir.wrote, "the Air has nothing the merged file lacks, so it writes nothing and the file stops travelling")

        for vault in [atPro.vault, atAir.vault] {
            XCTAssertEqual(vault.entries.first { $0.title == "Bank" }?.password, "bank-pro")
            XCTAssertEqual(vault.entries.first { $0.title == "New key" }?.password, "k")
            XCTAssertEqual(vault.entries.first { $0.title == "Mail" }?.password, "mail-pro")
            XCTAssertEqual(vault.historyPasswords(0xA2), ["mail", "mail-air"])
            XCTAssertEqual(vault.entries.first { $0.title == "To delete" }?.trashed, true)
            // Each Mac can say which item was changed on both, whichever of them did the merge.
            XCTAssertEqual(MergeConflictLog.records(in: vault.customData).map(\.item), [mergeID(0xA2)])
        }
        XCTAssertEqual(mergeContents(atPro.vault), mergeContents(atAir.vault))
        XCTAssertEqual(atPro.merge?.changedOnBoth.map(\.title), ["Mail"])
    }
}
