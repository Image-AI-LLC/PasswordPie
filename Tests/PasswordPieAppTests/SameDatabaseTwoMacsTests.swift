import AppKit
@testable import PasswordPieCore
import SwiftUI
import XCTest
@testable import PasswordPie

/// The same database on two Macs (docs/UX.md): the session reads a file that was replaced, merges instead of writing
/// over it, takes in the copies a sync tool leaves, and says which items were changed on both. The other Mac is a second
/// copy of the file, changed with the core library and put where a sync tool would put it.
@MainActor
final class SameDatabaseTwoMacsTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!
    private var prompts: ScriptedMergePrompts!
    private var trashed: [URL] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("two-macs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("Passwords.kdbx")
        setenv("PASSWORDPIE_DB", databaseURL.path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
        prompts = ScriptedMergePrompts()
        trashed = []
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("mergeSeenChanges.") || key.hasPrefix("mergeHandledCopies.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    /// A new database with these items, unlocked. Saves run in place, so each call has finished when it returns.
    private func unlockedSession(_ titles: [String] = ["Bank", "Mail"]) -> VaultSession {
        let session = VaultSession(writes: .inline)
        session.mergePrompts = prompts
        session.moveToTrash = { [weak self] url in
            self?.trashed.append(url)
            try FileManager.default.removeItem(at: url)
        }
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        for title in titles { session.saveEditing(item(title)) }
        return session
    }

    /// Unlocking an existing database derives its key beside the app, so the test waits for it.
    private func unlockAgain(_ session: VaultSession) async {
        if !session.locked { session.lock() }
        session.passwordDraft = "pw"
        session.unlock()
        let unlocked = await waitUntil { !session.locked && !session.unlocking }
        XCTAssertTrue(unlocked)
    }

    private func item(_ title: String, password: String = "secret") -> VaultEntry {
        var entry = VaultEntry()
        entry.title = title
        entry.username = "ada"
        entry.password = password
        return entry
    }

    private func onDisk(_ url: URL? = nil, password: String = "pw") throws -> Vault {
        try KDBX.load(data: Data(contentsOf: url ?? databaseURL), password: password)
    }

    /// What the other Mac does to its copy of the file as it is now. Returns that copy's bytes, not yet anywhere.
    private func otherMac(password: String = "pw", _ change: (inout Vault) -> Void) throws -> Data {
        var vault = try onDisk()
        change(&vault)
        return try KDBX.save(vault: &vault, password: password)
    }

    /// The sync tool puts the other Mac's file in place of ours.
    private func arrive(_ data: Data) throws {
        try data.write(to: databaseURL, options: .atomic)
    }

    private func titles(_ session: VaultSession) -> [String] {
        session.entries.filter { !$0.trashed }.map(\.title).sorted()
    }

    private func password(_ title: String, in session: VaultSession) -> String? {
        session.entries.first { $0.title == title && !$0.trashed }?.password
    }

    // MARK: Reading the file again

    func testAFileReplacedOnDiskWhileUnlockedIsReadAndNothingIsWritten() throws {
        let session = unlockedSession()
        let theirs = try otherMac { $0.entries.append(self.item("API key")) }
        try arrive(theirs)

        session.filesChangedOnDisk()

        XCTAssertEqual(titles(session), ["API key", "Bank", "Mail"])
        XCTAssertEqual(try Data(contentsOf: databaseURL), theirs, "the other Mac's file holds everything: it is left as it arrived")
        XCTAssertNil(session.mergeNotice)
        XCTAssertEqual(session.message, "")
    }

    func testAFileReplacedOnDiskThatLacksThisMacsChangeIsMergedAndWritten() throws {
        let session = unlockedSession()
        // The other Mac's copy is from before this Mac added Server.
        let theirs = try otherMac { $0.entries.append(self.item("API key")) }
        session.saveEditing(item("Server"))
        try arrive(theirs)

        session.filesChangedOnDisk()

        XCTAssertEqual(titles(session), ["API key", "Bank", "Mail", "Server"])
        XCTAssertEqual(Set(try onDisk().entries.map(\.title)), ["API key", "Bank", "Mail", "Server"])
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains(".before-merge-") }
        XCTAssertEqual(backups.count, 1, "this Mac's file from before the merge is kept")
        XCTAssertNil(session.mergeNotice, "different items: nothing to say")
    }

    func testASaveAfterTheFileWasReplacedMergesInsteadOfWritingOverIt() throws {
        let session = unlockedSession()
        try arrive(try otherMac { $0.entries.append(self.item("API key")) })

        // Nobody told the session: the save itself finds the file replaced.
        session.saveEditing(item("Server"))

        XCTAssertEqual(session.message, "")
        XCTAssertEqual(titles(session), ["API key", "Bank", "Mail", "Server"])
        XCTAssertEqual(Set(try onDisk().entries.map(\.title)), ["API key", "Bank", "Mail", "Server"])
    }

    /// A file arriving from the other Mac is not the person using this one: it must not put off the auto-lock.
    func testReadingAReplacedFileDoesNotCountAsActivity() throws {
        let session = unlockedSession()
        var activity = 0
        session.onActivity = { activity += 1 }
        try arrive(try otherMac { $0.entries.append(self.item("API key")) })
        session.filesChangedOnDisk()
        XCTAssertEqual(titles(session), ["API key", "Bank", "Mail"])
        XCTAssertEqual(activity, 0)
        session.saveEditing(item("Server"))
        XCTAssertGreaterThan(activity, 0, "a save is")
    }

    func testADeletionOnTheOtherMacReachesThisOne() throws {
        let session = unlockedSession()
        // A second after the item was made: the file keeps the time of a move to the second.
        Thread.sleep(forTimeInterval: 1.1)
        try arrive(try otherMac { vault in
            vault.entries[vault.entries.firstIndex { $0.title == "Mail" }!].trashed = true
        })
        session.filesChangedOnDisk()
        XCTAssertEqual(titles(session), ["Bank"])
    }

    func testNothingIsReadWhileLocked() throws {
        let session = unlockedSession()
        session.lock()
        let theirs = try otherMac { $0.entries.append(self.item("API key")) }
        try arrive(theirs)
        session.filesChangedOnDisk()
        session.lookForCopies()
        XCTAssertTrue(session.entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: databaseURL), theirs)
        XCTAssertNil(session.mergeNotice)
    }

    /// Reading a replaced file is nothing the person did: a lock that comes before it is not "a change was not saved".
    func testLockingWhileAFileWaitsToBeReadAgainReportsNoUnsavedChange() async throws {
        let session = VaultSession()
        session.mergePrompts = prompts
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        session.saveEditing(item("Bank"))
        XCTAssertTrue(session.savesPending, "the save is being written beside the app")
        session.filesChangedOnDisk()

        session.lock()

        XCTAssertEqual(session.message, "")
        await session.savesSettled()
        XCTAssertEqual(prompts.shown.count, 0)
    }

    // MARK: Changed on both Macs

    /// The other Mac changes Bank; a second later this Mac changes it too, before either has the other's change.
    private func bothChangeBank(_ session: VaultSession) throws {
        // A second apart, so each version has a time of its own: the file keeps times to the second.
        Thread.sleep(forTimeInterval: 1.1)
        let theirs = try otherMac { vault in
            vault.entries[vault.entries.firstIndex { $0.title == "Bank" }!].password = "from the other Mac"
        }
        Thread.sleep(forTimeInterval: 1.1)
        let id = try XCTUnwrap(session.entries.first { $0.title == "Bank" }?.id)
        var done = false
        session.changeEntry(id, { entry in
            entry.password = "from this Mac"
            return true
        }, then: { done = $0 })
        XCTAssertTrue(done)
        try arrive(theirs)
        session.filesChangedOnDisk()
    }

    func testTheSameItemChangedOnBothMacsIsSaidOnceListedAndCanBeRestored() async throws {
        let session = unlockedSession()
        try bothChangeBank(session)

        XCTAssertEqual(password("Bank", in: session), "from this Mac", "the later change is the item")
        XCTAssertEqual(session.mergeNotice, .changedOnBoth(1))
        XCTAssertEqual(session.mergeNotice?.summary, "1 item was changed on both Macs")
        XCTAssertTrue(session.hasItemsChangedOnBoth)
        let listed = session.itemsChangedOnBoth()
        XCTAssertEqual(listed.map(\.title), ["Bank"])
        let earlier = try XCTUnwrap(listed.first?.versions.first { $0.isTheEarlierChange })
        XCTAssertEqual(earlier.differing, ["Password"])
        XCTAssertEqual(listed.first?.versions.count, 2, "the original and the other Mac's change")

        // Restore brings the other Mac's change back, and the one it replaces goes into the history.
        var restored = false
        session.restoreVersion(earlier.id, of: try XCTUnwrap(listed.first?.listID)) { restored = $0 }
        XCTAssertTrue(restored)
        XCTAssertEqual(password("Bank", in: session), "from the other Mac")
        XCTAssertEqual(try onDisk().entries.first { $0.title == "Bank" }?.password, "from the other Mac")
        XCTAssertEqual(session.itemsChangedOnBoth().first?.versions.count, 3)

        // Said once: after × it is gone, also after locking and unlocking, while the list stays reachable.
        session.dismissMergeNotice()
        XCTAssertNil(session.mergeNotice)
        await unlockAgain(session)
        XCTAssertNil(session.mergeNotice)
        XCTAssertTrue(session.hasItemsChangedOnBoth)
        XCTAssertEqual(session.itemsChangedOnBoth().map(\.title), ["Bank"])
    }

    func testTheLineSurvivesALockUntilItIsRead() async throws {
        let session = unlockedSession()
        try bothChangeBank(session)
        await unlockAgain(session)
        XCTAssertEqual(session.mergeNotice, .changedOnBoth(1))
        session.markChangesSeen()
        XCTAssertNil(session.mergeNotice)
    }

    /// The Mac whose change went into the history hears of it too: the merged file says so.
    func testTheMacThatDidNotDoTheMergeIsToldToo() throws {
        let session = unlockedSession()
        let common = try Data(contentsOf: databaseURL)
        // This Mac changes Bank. Later the other Mac, which has not seen that, changes Bank too, gets this Mac's file
        // and merges: its later change is the item, and this Mac's is in the history.
        let bank = try XCTUnwrap(session.entries.first { $0.title == "Bank" }?.id)
        session.changeEntry(bank) { entry in
            entry.password = "from this Mac"
            return true
        }
        let ours = try KDBX.load(data: try Data(contentsOf: databaseURL), password: "pw")
        Thread.sleep(forTimeInterval: 1.1)
        var theirs = try KDBX.load(data: common, password: "pw")
        theirs.entries[theirs.entries.firstIndex { $0.title == "Bank" }!].password = "from the other Mac, later"
        theirs = try KDBX.load(data: try KDBX.save(vault: &theirs, password: "pw"), password: "pw")
        var merged = try VaultMerge.merge(ours, into: theirs).vault
        try arrive(try KDBX.save(vault: &merged, password: "pw"))

        session.filesChangedOnDisk()

        XCTAssertEqual(password("Bank", in: session), "from the other Mac, later")
        XCTAssertEqual(session.mergeNotice, .changedOnBoth(1), "this Mac's change is in the history, and it is told")
        XCTAssertEqual(session.itemsChangedOnBoth().first?.versions.first { $0.isTheEarlierChange }?.differing, ["Password"])
    }

    /// This Mac's change lost to a later move to the Recycle Bin on the other Mac: that must not go unseen either.
    func testAChangeThatLostToALaterMoveToTheRecycleBinIsListedAsBeingThere() throws {
        let session = unlockedSession()
        let common = try Data(contentsOf: databaseURL)
        Thread.sleep(forTimeInterval: 1.1)
        let bank = try XCTUnwrap(session.entries.first { $0.title == "Bank" }?.id)
        session.changeEntry(bank) { entry in
            entry.password = "from this Mac"
            return true
        }
        Thread.sleep(forTimeInterval: 1.1)
        var theirs = try KDBX.load(data: common, password: "pw")
        theirs.entries[theirs.entries.firstIndex { $0.title == "Bank" }!].trashed = true
        try arrive(try KDBX.save(vault: &theirs, password: "pw"))

        session.filesChangedOnDisk()

        XCTAssertEqual(titles(session), ["Mail"])
        XCTAssertEqual(session.mergeNotice, .changedOnBoth(1))
        let listed = try XCTUnwrap(session.itemsChangedOnBoth().first)
        XCTAssertEqual(listed.title, "Bank")
        XCTAssertTrue(listed.trashed)
        XCTAssertTrue(ChangedOnBothView.summary(of: listed).hasPrefix("In the Recycle Bin"))
    }

    /// The other Mac's file lands twice in a row. The second arrives while the first is still being read beside the app.
    func testAFileThatChangesAgainWhileItIsBeingReadIsReadOnceMore() async throws {
        let session = VaultSession()
        session.mergePrompts = prompts
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        session.saveEditing(item("Bank"))
        await session.savesSettled()

        let first = try otherMac { $0.entries.append(self.item("First")) }
        try arrive(first)
        session.filesChangedOnDisk()
        XCTAssertTrue(session.savesPending, "the first is being read")
        var second = try KDBX.load(data: first, password: "pw")
        second.entries.append(item("Second"))
        try arrive(try KDBX.save(vault: &second, password: "pw"))
        session.filesChangedOnDisk()

        let read = await waitUntil { self.titles(session) == ["Bank", "First", "Second"] }
        XCTAssertTrue(read, "\(titles(session))")
    }

    func testADatabaseOpenedForTheFirstTimeDoesNotReportWhatHappenedBefore() async throws {
        let session = unlockedSession()
        try bothChangeBank(session)
        session.lock()
        // Another Mac, which never opened this database: no memory of what it has shown.
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("mergeSeenChanges.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        await unlockAgain(session)
        XCTAssertNil(session.mergeNotice)
        XCTAssertTrue(session.hasItemsChangedOnBoth, "the list is still there to open")
    }

    // MARK: A file that cannot be read

    func testAReplacedFileThatDoesNotOpenIsLeftAloneAndNothingIsSavedOverIt() throws {
        let session = unlockedSession()
        let theirs = try otherMac(password: "changed on the other Mac") { _ in }
        try arrive(theirs)

        session.filesChangedOnDisk()

        guard case .unreadable(let file, let reason)? = session.mergeNotice else { return XCTFail("\(String(describing: session.mergeNotice))") }
        XCTAssertEqual(file, "Passwords.kdbx")
        XCTAssertEqual(session.mergeNotice?.summary, "Passwords.kdbx cannot be read")
        XCTAssertEqual(session.mergeNotice?.actionTitle, "Why?")
        XCTAssertTrue(reason.contains("does not open with this master password"), reason)
        XCTAssertEqual(titles(session), ["Bank", "Mail"], "what is in memory stays usable")
        // A save says why it cannot be written, and writes nothing.
        session.saveEditing(item("Server"))
        XCTAssertTrue(session.message.contains("does not open with this master password"), session.message)
        XCTAssertEqual(try Data(contentsOf: databaseURL), theirs)
        XCTAssertEqual(titles(session), ["Bank", "Mail"])
        // Why? shows the whole reason; × puts the line away.
        session.performMergeNotice()
        XCTAssertEqual(prompts.shown.last?.text, reason)
        session.dismissMergeNotice()
        XCTAssertNil(session.mergeNotice)
        session.filesChangedOnDisk()
        XCTAssertNil(session.mergeNotice, "the same unreadable file is not tried and reported again")
    }

    // MARK: The copies a sync tool leaves

    private func leaveCopy(named name: String, password: String = "pw", _ change: (inout Vault) -> Void) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try otherMac(password: password, change).write(to: url)
        return url
    }

    func testASyncToolsCopyOfThisDatabaseIsMergedWithoutAskingAndCanThenBeMovedToTheTrash() throws {
        let session = unlockedSession()
        let copy = try leaveCopy(named: "Passwords.sync-conflict-20261120-031800-ABCDEFG.kdbx") { $0.entries.append(self.item("API key")) }

        session.lookForCopies()

        XCTAssertEqual(titles(session), ["API key", "Bank", "Mail"])
        XCTAssertEqual(Set(try onDisk().entries.map(\.title)), ["API key", "Bank", "Mail"])
        XCTAssertEqual(session.mergeNotice?.summary, "A copy was merged in")
        XCTAssertEqual(session.mergeNotice?.actionTitle, "Move to Trash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "the copy is the owner's to remove")
        XCTAssertEqual(prompts.shown.count, 0, "nothing was asked")

        session.performMergeNotice()
        XCTAssertEqual(trashed, [copy])
        XCTAssertNil(session.mergeNotice)
    }

    func testAMergedCopyCanStillBeMovedToTheTrashAfterALock() async throws {
        let session = unlockedSession()
        let copy = try leaveCopy(named: "Passwords.sync-conflict-20261120-031800-ABCDEFG.kdbx") { $0.entries.append(self.item("API key")) }
        session.lookForCopies()
        await unlockAgain(session)
        XCTAssertEqual(session.mergeNotice?.actionTitle, "Move to Trash")
        session.performMergeNotice()
        XCTAssertEqual(trashed, [copy])
    }

    func testAMergedCopyThatIsKeptIsNotMergedOrMentionedAgain() async throws {
        let session = unlockedSession()
        _ = try leaveCopy(named: "Passwords.sync-conflict-20261120-031800-ABCDEFG.kdbx") { $0.entries.append(self.item("API key")) }
        session.lookForCopies()
        session.dismissMergeNotice()
        XCTAssertNil(session.mergeNotice)
        let written = try Data(contentsOf: databaseURL)

        await unlockAgain(session)
        session.lookForCopies()

        XCTAssertNil(session.mergeNotice)
        XCTAssertEqual(try Data(contentsOf: databaseURL), written)
    }

    func testACopyIsFoundWhenTheDatabaseIsUnlocked() async throws {
        let session = unlockedSession()
        _ = try leaveCopy(named: "Passwords (Ada's conflicted copy 2026-11-20).kdbx") { $0.entries.append(self.item("API key")) }
        await unlockAgain(session)
        XCTAssertEqual(titles(session), ["API key", "Bank", "Mail"])
    }

    func testANameAPersonCouldHaveGivenIsOfferedAndMergedOnlyWhenAsked() throws {
        let session = unlockedSession()
        let copy = try leaveCopy(named: "Passwords 2.kdbx") { $0.entries.append(self.item("API key")) }

        session.lookForCopies()

        XCTAssertEqual(titles(session), ["Bank", "Mail"], "not merged unasked")
        XCTAssertEqual(session.mergeNotice?.summary, "Possible copy: Passwords 2.kdbx")
        XCTAssertEqual(session.mergeNotice?.actionTitle, "Merge…")

        session.performMergeNotice()
        XCTAssertEqual(titles(session), ["API key", "Bank", "Mail"])
        XCTAssertEqual(prompts.shown.last?.text, "Merged Passwords 2.kdbx: 1 item added.")
        XCTAssertEqual(session.mergeNotice?.summary, "A copy was merged in")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    }

    func testAnOfferedCopyThatIsDismissedIsNotOfferedAgain() async throws {
        let session = unlockedSession()
        _ = try leaveCopy(named: "Passwords 2.kdbx") { $0.entries.append(self.item("API key")) }
        session.lookForCopies()
        session.dismissMergeNotice()
        XCTAssertNil(session.mergeNotice)
        await unlockAgain(session)
        XCTAssertNil(session.mergeNotice)
        XCTAssertEqual(titles(session), ["Bank", "Mail"])
    }

    func testASyncToolsCopyThatDoesNotOpenWithThisDatabasesPasswordIsOfferedAndItsPasswordAsked() throws {
        let session = unlockedSession()
        _ = try leaveCopy(named: "Passwords.sync-conflict-20261120-031800-ABCDEFG.kdbx", password: "older password") { $0.entries.append(self.item("API key")) }

        session.lookForCopies()
        XCTAssertEqual(titles(session), ["Bank", "Mail"])
        XCTAssertEqual(session.mergeNotice?.actionTitle, "Merge…")

        prompts.answers = [("wrong guess", nil), ("older password", nil)]
        session.performMergeNotice()
        XCTAssertEqual(prompts.asked.map(\.wrong), [false, true])
        XCTAssertEqual(titles(session), ["API key", "Bank", "Mail"])
    }

    func testASyncToolsNameOnAnotherDatabaseIsNotMergedUnaskedNorOnAGuess() throws {
        let session = unlockedSession()
        // Another database altogether, with the same password and the same key settings, under a conflict copy's name.
        var other = Vault(name: "Other", rootName: "Other", entries: [item("Stranger")], kdf: .default)
        let copy = directory.appendingPathComponent("Passwords.sync-conflict-20261120-031800-ABCDEFG.kdbx")
        try KDBX.save(vault: &other, password: "pw").write(to: copy)
        XCTAssertEqual(KDBX.kdf(ofHeader: try Data(contentsOf: copy)), KDBX.kdf(ofHeader: try Data(contentsOf: databaseURL)))

        session.lookForCopies()

        XCTAssertEqual(titles(session), ["Bank", "Mail"])
        XCTAssertEqual(session.mergeNotice?.actionTitle, "Merge…")
        // Merge… on the line was offered on the strength of the name alone: another database is still not folded in.
        session.performMergeNotice()
        XCTAssertEqual(titles(session), ["Bank", "Mail"])
        XCTAssertTrue(prompts.shown.last?.text.hasPrefix("Passwords.sync-conflict-20261120-031800-ABCDEFG.kdbx is another database") == true, prompts.shown.last?.text ?? "")
        XCTAssertNil(session.mergeNotice)
        // Merge from File… is how it is asked for.
        session.mergeFile(at: copy)
        XCTAssertEqual(titles(session), ["Bank", "Mail", "Stranger"])
    }

    /// A header is untrusted until a key opens the file: a copy that asks for another key derivation than this
    /// database's is not opened unasked, though it is this database and would open with its password.
    func testACopyThatAsksForOtherKeySettingsIsOfferedNotOpenedUnasked() throws {
        let session = unlockedSession()
        var theirs = try onDisk()
        theirs.entries.append(item("API key"))
        _ = try KDBX.save(vault: &theirs, password: "pw")
        let xml = try XCTUnwrap(theirs.preserve?.document.xmlString)
        let copy = directory.appendingPathComponent("Passwords.sync-conflict-20261120-031800-ABCDEFG.kdbx")
        try KDBX.testingDatabase(xml: xml, password: "pw", kdf: .fastTest).write(to: copy)

        session.lookForCopies()

        XCTAssertEqual(titles(session), ["Bank", "Mail"], "not opened, so not merged")
        XCTAssertEqual(session.mergeNotice?.actionTitle, "Merge…")
        session.performMergeNotice()
        XCTAssertEqual(titles(session), ["API key", "Bank", "Mail"], "asked for, it is this database and is merged")
    }

    func testAMergedCopyThatWasWrittenAgainIsNotMovedToTheTrash() throws {
        let session = unlockedSession()
        let copy = try leaveCopy(named: "Passwords.sync-conflict-20261120-031800-ABCDEFG.kdbx") { $0.entries.append(self.item("API key")) }
        session.lookForCopies()
        XCTAssertEqual(session.mergeNotice?.actionTitle, "Move to Trash")
        // The sync tool writes the copy again before the button is pressed: it now holds something the database lacks.
        try otherMac { $0.entries.append(self.item("Arrived later")) }.write(to: copy, options: .atomic)

        session.performMergeNotice()

        XCTAssertEqual(trashed, [], "what was not merged is not thrown away")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(titles(session), ["API key", "Arrived later", "Bank", "Mail"], "it is merged as the new copy it is")
    }

    // MARK: Merge from File…

    func testMergeFromFileMergesTheChosenDatabaseAndSaysWhatCameOfIt() throws {
        let session = unlockedSession()
        let chosen = directory.appendingPathComponent("elsewhere.kdbx")
        try otherMac { vault in
            vault.entries.append(self.item("API key"))
            vault.entries.append(self.item("Server"))
        }.write(to: chosen)
        let before = try Data(contentsOf: chosen)

        session.mergeFile(at: chosen)

        XCTAssertEqual(titles(session), ["API key", "Bank", "Mail", "Server"])
        XCTAssertEqual(prompts.shown.last?.text, "Merged elsewhere.kdbx: 2 items added.")
        XCTAssertEqual(try Data(contentsOf: chosen), before, "the chosen file is never changed")

        session.mergeFile(at: chosen)
        XCTAssertEqual(prompts.shown.last?.text, "The database already has everything in elsewhere.kdbx.")
    }

    func testMergeFromFileAsksForTheFilesOwnPasswordAndStopsWhenCancelled() throws {
        let session = unlockedSession()
        let chosen = directory.appendingPathComponent("elsewhere.kdbx")
        try otherMac(password: "its own") { $0.entries.append(self.item("API key")) }.write(to: chosen)

        session.mergeFile(at: chosen)
        XCTAssertEqual(prompts.asked.count, 1)
        XCTAssertEqual(titles(session), ["Bank", "Mail"], "cancelled: nothing merged")

        prompts.answers = [("its own", nil)]
        session.mergeFile(at: chosen)
        XCTAssertEqual(titles(session), ["API key", "Bank", "Mail"])
        XCTAssertEqual(try onDisk().entries.count, 3, "and it is saved with this database's password")
    }

    func testMergeFromFileRefusesTheOpenDatabaseItselfAndAFileThatIsNotADatabase() throws {
        let session = unlockedSession()
        session.mergeFile(at: databaseURL)
        XCTAssertEqual(prompts.shown.last?.text, "Passwords.kdbx is the open database.")
        let notes = directory.appendingPathComponent("notes.kdbx")
        try Data("not a database".utf8).write(to: notes)
        session.mergeFile(at: notes)
        XCTAssertTrue(prompts.shown.last?.text.hasPrefix("notes.kdbx could not be read.") == true, prompts.shown.last?.text ?? "")
        XCTAssertEqual(titles(session), ["Bank", "Mail"])
    }

    // MARK: What is drawn

    /// With `PASSWORDPIE_SNAPSHOTS=<folder>` the pictures are also written there, for docs/images.
    private func picture(of view: NSView, named name: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let folder = ProcessInfo.processInfo.environment["PASSWORDPIE_SNAPSHOTS"] else { return }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }

    func testTheListWindowAndTheLineDraw() throws {
        let session = unlockedSession()
        try bothChangeBank(session)
        let item = try XCTUnwrap(session.itemsChangedOnBoth().first)
        for (name, opened) in [("changed-on-both", Set<String>()), ("changed-on-both-history", [item.id])] {
            let host = NSHostingView(rootView: ChangedOnBothView(session: session, opened: opened, close: {}))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            XCTAssertEqual(host.fittingSize.width, 460)
            XCTAssertGreaterThan(host.fittingSize.height, 200)
            try picture(of: host, named: name)
        }
        let lines: [(String, MergeNotice)] = [
            ("line-changed-on-both", .changedOnBoth(2)),
            ("line-copy-merged", .copiesMerged([ConflictCopy(url: URL(fileURLWithPath: "/a.kdbx"), tool: .syncthing, certain: true)])),
            ("line-copy-offered", .copyOffered(ConflictCopy(url: URL(fileURLWithPath: "/Passwords 2.kdbx"), tool: .unknown, certain: false)))
        ]
        for (name, notice) in lines {
            let line = try XCTUnwrap(PanelController.noticeLine(chromeBatch: nil, mergeNotice: notice))
            let row = ChromeBatchRowView(frame: NSRect(x: 0, y: 0, width: 320, height: ChromeBatchRowView.height))
            row.show(line.summary, action: line.action)
            XCTAssertEqual(row.actionTitle, notice.actionTitle)
            try picture(of: row, named: name)
        }
        XCTAssertNil(PanelController.noticeLine(chromeBatch: nil, mergeNotice: nil))
        // One line: Chrome's question first, while it waits.
        let chrome = ChromeBatch(accounts: [ChromeBatch.Account(id: UUID(), title: "Bank", username: "ada")])
        XCTAssertEqual(PanelController.noticeLine(chromeBatch: chrome, mergeNotice: .changedOnBoth(2))?.summary, chrome.summary)
    }

    // MARK: Words

    func testWhatAMergeDidInWords() {
        var report = VaultMergeReport()
        XCTAssertEqual(MergeSummary.text(report, fileName: "a.kdbx"), "The database already has everything in a.kdbx.")
        XCTAssertEqual(MergeSummary.text(nil, fileName: "a.kdbx"), "The database already has everything in a.kdbx.")
        report.changed = true
        report.added = 3
        report.updated = 1
        XCTAssertEqual(MergeSummary.text(report, fileName: "a.kdbx"), "Merged a.kdbx: 3 items added, 1 updated.")
        report.changedOnBoth = [VaultMergeReport.Item(id: UUID(), title: "Bank", kept: Date(), older: Date())]
        XCTAssertEqual(
            MergeSummary.text(report, fileName: "a.kdbx"),
            "Merged a.kdbx: 3 items added, 1 updated. 1 item was changed in both: the later change is the item, and the earlier one is in its history."
        )
        XCTAssertEqual(MergeSummary.changedOnBoth(2), "2 items were changed on both Macs")
        XCTAssertEqual(MergeNotice.copiesMerged([ConflictCopy(url: URL(fileURLWithPath: "/a"), tool: .syncthing, certain: true), ConflictCopy(url: URL(fileURLWithPath: "/b"), tool: .dropbox, certain: true)]).summary, "2 copies were merged in")
    }

    // MARK: Looking at the files

    func testAReplacedFileLooksDifferentAndTheWatcherSaysWhichFileAndFolderChanged() throws {
        let session = unlockedSession()
        let before = try XCTUnwrap(FileSignature(path: databaseURL.path))
        var reports: [(files: [String], folders: [String])] = []
        let watcher = DatabaseFileWatcher(interval: 3600) { files, folders in reports.append((files, folders)) }
        watcher.watch([databaseURL.path])
        watcher.lookNow()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(reports.isEmpty, "nothing changed since it began to watch")

        // The same bytes written again by renaming a new file over the old one, as a sync tool does.
        try arrive(try Data(contentsOf: databaseURL))
        XCTAssertNotEqual(FileSignature(path: databaseURL.path), before)
        watcher.lookNow()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(reports.map(\.files), [[databaseURL.path]])
        XCTAssertEqual(reports.map(\.folders), [[databaseURL.path]], "a file came and went in the folder")

        watcher.watch([])
        try arrive(try Data(contentsOf: databaseURL))
        watcher.lookNow()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(reports.count, 1, "not watched any more")
        _ = session
    }

    func testTheSessionTellsItsWatcherWhichFilesAreOpenAndNoneWhenLocked() throws {
        var reports = 0
        let watcher = DatabaseFileWatcher(interval: 3600) { _, _ in reports += 1 }
        let session = VaultSession(writes: .inline)
        session.fileWatcher = watcher
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        session.saveEditing(item("Bank"))
        watcher.lookNow()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let afterSaving = reports

        try arrive(try Data(contentsOf: databaseURL))
        watcher.lookNow()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(reports, afterSaving + 1, "the open database is watched")

        session.lock()
        try arrive(try Data(contentsOf: databaseURL))
        watcher.lookNow()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(reports, afterSaving + 1, "locked: nothing is watched")
    }
}

@MainActor
final class ScriptedMergePrompts: MergePrompting {
    var answers: [(password: String, keyFile: Data?)] = []
    private(set) var asked: [(name: String, wrong: Bool)] = []
    private(set) var shown: [(text: String, title: String)] = []

    func keys(forFileNamed name: String, wrong: Bool) -> (password: String, keyFile: Data?)? {
        asked.append((name, wrong))
        return answers.isEmpty ? nil : answers.removeFirst()
    }

    func show(_ text: String, title: String) {
        shown.append((text, title))
    }
}
