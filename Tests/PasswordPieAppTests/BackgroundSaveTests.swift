import AppKit
@testable import PasswordPieCore
import XCTest
@testable import PasswordPie

/// A save is written off the main thread (docs/UX.md, "Saving does not freeze PasswordPie"). These sessions use the
/// background writer the app uses. Every other test file passes `.inline`, which runs the same steps in place.
@MainActor
final class BackgroundSaveTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("background-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("test.kdbx")
        setenv("PASSWORDPIE_DB", databaseURL.path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    /// A new database, which gets the app's default key settings: a save takes a few tenths of a second.
    private func unlockedSession() -> VaultSession {
        let session = VaultSession()
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        return session
    }

    private func settle(_ session: VaultSession) async {
        await session.savesSettled()
    }

    private func item(_ title: String, password: String = "secret") -> VaultEntry {
        var entry = VaultEntry()
        entry.title = title
        entry.password = password
        return entry
    }

    private func savedEntries() throws -> [VaultEntry] {
        try KDBX.load(data: Data(contentsOf: databaseURL), password: "pw").entries
    }

    /// Saves one item and waits for the file.
    private func saved(_ title: String, in session: VaultSession) async throws -> VaultEntry {
        let entry = item(title)
        session.saveEditing(entry)
        await settle(session)
        return try XCTUnwrap(session.storedEntry(entry.id))
    }

    private func lockDatabaseFolder() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    }

    private func unlockDatabaseFolder() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    // MARK: The editor

    func testSaveReturnsAtOnceAndTheEditorClosesWhenTheFileIsWritten() async throws {
        let session = unlockedSession()
        session.newEntry()
        var draft = try XCTUnwrap(session.editing)
        draft.title = "Bank"
        draft.password = "typed"

        session.saveEditing(draft)

        XCTAssertTrue(session.editorSaving, "the editor says Saving…")
        XCTAssertEqual(session.editing?.id, draft.id, "and stays open")
        XCTAssertTrue(session.entries.isEmpty, "the list changes when the file has")
        XCTAssertTrue(session.savesPending)

        await settle(session)

        XCTAssertFalse(session.editorSaving)
        XCTAssertNil(session.editing)
        XCTAssertEqual(session.editorError, "")
        XCTAssertEqual(session.entries.map(\.title), ["Bank"])
        XCTAssertEqual(try savedEntries().map(\.password), ["typed"])
    }

    func testSaveReturnsWhileASlowKeyIsStillBeingDerived() async throws {
        // Slow on purpose, like a database from another KeePass app: a save derives this key twice.
        let slow = KDFParameters(kind: .argon2id(memoryKiB: 64 * 1024, iterations: 12, parallelism: 2, version: 0x13))
        var vault = Vault(entries: [item("Bank")], kdf: slow)
        try KDBX.save(vault: &vault, password: "pw", keyFile: nil).write(to: databaseURL)
        let session = VaultSession()
        session.restore()
        session.passwordDraft = "pw"
        session.unlock()
        for _ in 0..<4_000 where session.locked { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(session.locked)
        await settle(session)
        let bank = try XCTUnwrap(session.entries.first)
        session.edit(bank.id)
        var draft = try XCTUnwrap(session.editing)
        draft.title = "Bank, renamed"

        let started = Date()
        session.saveEditing(draft)
        let returned = Date().timeIntervalSince(started)
        XCTAssertTrue(session.editorSaving)
        await settle(session)
        let written = Date().timeIntervalSince(started)

        XCTAssertNil(session.editing)
        XCTAssertEqual(try savedEntries().filter { !$0.trashed }.map(\.title), ["Bank, renamed"])
        XCTAssertLessThan(returned, written / 4, "the main thread was given back long before the file was written (\(returned) s of \(written) s)")
    }

    func testMoveToTrashKeepsTheEditorUntilTheFileIsWritten() async throws {
        let session = unlockedSession()
        let bank = try await saved("Bank", in: session)
        session.edit(bank.id)

        session.deleteEditing()

        XCTAssertTrue(session.editorSaving)
        XCTAssertNotNil(session.editing)
        XCTAssertNotNil(session.storedEntry(bank.id), "still listed until the file says otherwise")

        await settle(session)

        XCTAssertNil(session.editing)
        XCTAssertNil(session.storedEntry(bank.id))
        XCTAssertEqual(try savedEntries().map(\.trashed), [true])
    }

    func testTheEditorTakesNothingWhileItsSaveIsBeingWritten() async throws {
        let session = unlockedSession()
        let other = try await saved("Other", in: session)
        session.newEntry()
        var draft = try XCTUnwrap(session.editing)
        draft.title = "Bank"

        session.saveEditing(draft)
        session.saveEditing(draft)
        session.cancelEditing()
        session.edit(other.id)
        session.newEntry()
        session.deleteEditing()

        XCTAssertEqual(session.editing?.id, draft.id, "Cancel, another Edit and New Item wait for the save")
        await settle(session)
        XCTAssertNil(session.editing)
        XCTAssertEqual(try savedEntries().filter { !$0.trashed }.map(\.title).sorted(), ["Bank", "Other"], "written once, and not trashed")
    }

    func testAFailedSaveKeepsTheEditorOpenWithWhatWasTypedAndSaysWhy() async throws {
        let session = unlockedSession()
        let bank = try await saved("Bank", in: session)
        session.edit(bank.id)
        var draft = try XCTUnwrap(session.editing)
        draft.password = "typed-secret"
        session.editing = draft
        try lockDatabaseFolder()

        session.saveEditing(draft)
        await settle(session)

        XCTAssertFalse(session.editorSaving)
        XCTAssertEqual(session.editing?.password, "typed-secret", "what was typed stays in the open editor")
        XCTAssertFalse(session.editorError.isEmpty, "and the editor says why")
        XCTAssertEqual(session.storedEntry(bank.id)?.password, "secret", "nothing unsaved is listed")
        XCTAssertEqual(try savedEntries().map(\.password), ["secret"])

        try unlockDatabaseFolder()
        session.saveEditing(try XCTUnwrap(session.editing))
        await settle(session)

        XCTAssertNil(session.editing)
        XCTAssertEqual(session.editorError, "")
        XCTAssertEqual(try savedEntries().map(\.password), ["typed-secret"])
    }

    func testAFailedMoveToTrashKeepsTheEditorAndTheAccount() async throws {
        let session = unlockedSession()
        let bank = try await saved("Bank", in: session)
        session.edit(bank.id)
        try lockDatabaseFolder()

        session.deleteEditing()
        await settle(session)

        XCTAssertEqual(session.editing?.id, bank.id)
        XCTAssertFalse(session.editorError.isEmpty)
        XCTAssertNotNil(session.storedEntry(bank.id))
    }

    // MARK: One after another

    func testChangesAskedForTogetherAreWrittenInOrderEachOnTopOfTheOneBefore() async throws {
        let session = unlockedSession()
        let bank = try await saved("Bank", in: session)
        var answers: [Bool] = []

        session.toggleFavorite(bank.id) { answers.append($0) }
        session.saveGenerated("generated-1")
        session.toggleFavorite(bank.id) { answers.append($0) }
        session.toggleFavorite(bank.id) { answers.append($0) }

        XCTAssertEqual(session.storedEntry(bank.id)?.favorite, false, "nothing shows before it is in the file")
        XCTAssertTrue(answers.isEmpty)

        await settle(session)

        XCTAssertEqual(answers, [true, true, true])
        let saved = try savedEntries()
        XCTAssertEqual(saved.first { $0.id == bank.id }?.favorite, true, "three presses of the star")
        XCTAssertEqual(saved.map(\.title).sorted(), ["Bank", "Generated Password"], "the later writes kept the earlier ones")
        XCTAssertEqual(session.entries.count, 2)
    }

    func testAStarThatCannotBeSavedAnswersFalseAndChangesNothing() async throws {
        let session = unlockedSession()
        let bank = try await saved("Bank", in: session)
        try lockDatabaseFolder()
        var answer: Bool?

        session.toggleFavorite(bank.id) { answer = $0 }
        await settle(session)

        XCTAssertEqual(answer, false)
        XCTAssertEqual(session.storedEntry(bank.id)?.favorite, false)
    }

    func testAnImportIsRefusedWhileASaveIsBeingWritten() async throws {
        let session = unlockedSession()
        session.saveEditing(item("Bank"))

        XCTAssertNil(session.mergeImported([item("Imported")], source: .chrome), "nothing else writes the file meanwhile")

        await settle(session)
        XCTAssertEqual(try savedEntries().map(\.title), ["Bank"])
        XCTAssertEqual(session.entries.map(\.title), ["Bank"])
    }

    func testSettlingAnswersAtOnceWhenNothingIsBeingSaved() {
        let session = unlockedSession()
        var settled = false
        session.whenSavesSettle { settled = true }
        XCTAssertTrue(settled, "quitting does not wait for nothing")
    }

    // MARK: Lock

    func testLockingWhileSavingLocksAtOnceAndTheSaveStillReachesTheFile() async throws {
        let session = unlockedSession()
        session.newEntry()
        var draft = try XCTUnwrap(session.editing)
        draft.title = "Bank"
        session.saveEditing(draft)

        session.lock()

        XCTAssertTrue(session.locked)
        XCTAssertNil(session.editing)
        XCTAssertFalse(session.editorSaving)
        await settle(session)
        XCTAssertTrue(session.locked, "the finished write does not unlock anything")
        XCTAssertTrue(session.entries.isEmpty)
        XCTAssertEqual(try savedEntries().map(\.title), ["Bank"])
    }

    func testUnlockingAgainWhileTheSaveIsStillBeingWrittenOpensWhatItWrote() async throws {
        let session = unlockedSession()
        session.saveEditing(item("Bank"))
        session.lock()

        session.passwordDraft = "pw"
        session.unlock()
        for _ in 0..<4_000 where session.locked { try await Task.sleep(nanoseconds: 5_000_000) }

        XCTAssertFalse(session.locked)
        XCTAssertEqual(session.entries.map(\.title), ["Bank"], "the session starts from the file the save left, not the one before it")
    }

    // MARK: A scanned code

    func testAddingAScannedCodeSaysSoUntilTheFileIsWritten() async throws {
        let session = unlockedSession()
        let model = OTPScanModel(session: session)
        let scan = try OTPAuthImport.parse("otpauth://totp/Example:ada@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example").get()
        model.receive(scan, origin: "https://example.com", browser: nil)
        model.target = .newItem

        model.add()
        model.add()

        XCTAssertEqual(model.phase, .saving)
        XCTAssertFalse(model.isWaiting, "Add cannot be pressed twice")
        XCTAssertNotNil(model.scan)

        await settle(session)

        guard case .added(let id) = model.phase else { return XCTFail("not added: \(model.phase)") }
        XCTAssertNil(model.scan)
        XCTAssertEqual(try savedEntries().map(\.id), [id], "one item, not two")
    }

    // MARK: Chrome updates

    #if PP_DIRECT
    private func chromeLogin(password: String) -> VaultEntry {
        var live = VaultEntry(groupPath: ["Chrome (live)", "Work"])
        live.title = "github.com"
        live.url = "https://github.com"
        live.username = "ann"
        live.password = password
        return live
    }

    func testAChromeUpdateWaitsForASaveBeingWrittenAndLandsOnTopOfIt() async throws {
        let session = unlockedSession()
        session.chromeSyncEnabled = true
        session.chromeClock = { Date().addingTimeInterval(3_600) }
        var own = item("github.com", password: "mine")
        own.url = "https://github.com"
        own.username = "ann"
        session.saveEditing(own)
        await settle(session)
        session.edit(own.id)
        var draft = try XCTUnwrap(session.editing)
        draft.notes = "typed while Chrome was read"

        session.saveEditing(draft)
        let login = chromeLogin(password: "from-chrome")
        let rows = [ChromeRow(loginID: login.id, password: login.password, modifiedAt: Date().addingTimeInterval(1_800), isForm: true)]
        let result = ChromeLoginsResult(entries: [login], profileCount: 1, rows: rows)
        session.chromeSource = ChromeSnapshotSource(signature: { ChromeStoreSignature() }, load: { _ in (Data(repeating: 1, count: 16), result) })
        session.refreshChrome()
        for _ in 0..<4_000 {
            if !session.chromeBusy, !session.chromeWriteInFlight, !session.savesPending, session.storedEntry(own.id)?.password == "from-chrome" { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let stored = try XCTUnwrap(try savedEntries().first)
        XCTAssertEqual(stored.password, "from-chrome")
        XCTAssertEqual(stored.notes, "typed while Chrome was read", "the update did not write over the save")
        XCTAssertNil(session.editing)
        XCTAssertTrue(session.chromeUpdateFailures.isEmpty)
    }

    func testASaveWaitsForAChromeUpdateBeingWritten() async throws {
        let session = unlockedSession()
        session.chromeWriteInFlight = true

        session.saveEditing(item("Bank"))

        XCTAssertTrue(session.savesPending)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(try savedEntries().isEmpty, "one file write at a time")

        session.chromeWriteInFlight = false
        session.runQueuedWrites()
        await settle(session)

        XCTAssertEqual(try savedEntries().map(\.title), ["Bank"])
    }

    func testClearingPreviousPasswordsIsRefusedWhileASaveIsBeingWritten() async throws {
        let session = unlockedSession()
        let bank = try await saved("Bank", in: session)

        session.toggleFavorite(bank.id)

        XCTAssertFalse(session.clearPreviousPasswords(of: bank.id), "it would write the same file at the same time")
        await settle(session)
        XCTAssertEqual(try savedEntries().first?.favorite, true)
    }
    #endif
}
