#if PP_DIRECT
import AppKit
@testable import PasswordPieCore
import XCTest
@testable import PasswordPie

/// A newer Chrome password in a real session and a real file, from fixtures only.
@MainActor
final class ChromeUpdateSessionTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-update-\(UUID().uuidString)", isDirectory: true)
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

    /// All file times are real. The fixture's Chrome dates are later than them, and the session's clock is later still.
    private let clockOffset: TimeInterval = 3_600

    private func session() -> VaultSession {
        let session = VaultSession()
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        session.chromeSyncEnabled = true
        let offset = clockOffset
        session.chromeClock = { Date().addingTimeInterval(offset) }
        return session
    }

    private func account(_ session: VaultSession, site: String = "https://github.com", user: String = "ann", password: String = "mine") -> VaultEntry {
        var own = VaultEntry()
        own.title = "github.com"
        own.url = site
        own.username = user
        own.password = password
        session.saveEditing(own)
        return own
    }

    private func login(site: String = "https://github.com", user: String = "ann", password: String = "from-chrome") -> VaultEntry {
        var live = VaultEntry(groupPath: ["Chrome (live)", "Work"])
        live.title = "github.com"
        live.url = site
        live.username = user
        live.password = password
        return live
    }

    /// Delivers one fixture read. The password value and date are what `refreshChrome` would have got from Chrome.
    private func read(_ session: VaultSession, logins: [VaultEntry], date: Date? = nil) async {
        let when = date ?? Date().addingTimeInterval(clockOffset / 2)
        let rows = logins.map { ChromeRow(loginID: $0.id, password: $0.password, modifiedAt: when, isForm: true) }
        let result = ChromeLoginsResult(entries: logins, profileCount: 1, rows: rows)
        session.chromeSource = ChromeSnapshotSource(signature: { ChromeStoreSignature() }, load: { _ in (Data(repeating: 1, count: 16), result) })
        session.refreshChrome()
        await waitUntil { !session.chromeBusy && !session.chromeWriteInFlight }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func stored() throws -> [VaultEntry] {
        try KDBX.load(data: Data(contentsOf: databaseURL), password: "pw").entries
    }

    private func onDisk() throws -> Data { try Data(contentsOf: databaseURL) }

    private func details(_ session: VaultSession, _ id: UUID, done: @escaping () -> Void = {}, fill: (() -> Void)? = nil) throws -> DetailsModel {
        DetailsModel(entry: try XCTUnwrap(session.entry(id)), session: session, done: done, fill: fill)
    }

    // MARK: Writing

    func testANewerChromePasswordIsWrittenToTheFileWithoutAnyNotice() async throws {
        let session = session()
        let own = account(session)
        await read(session, logins: [login()])

        XCTAssertEqual(try stored().map(\.password), ["from-chrome"])
        XCTAssertEqual(session.entry(own.id)?.password, "from-chrome")
        XCTAssertEqual(session.value(of: .password, in: try XCTUnwrap(session.entry(own.id))), "from-chrome", "Copy and Fill read the saved value")
        XCTAssertEqual(session.message, "")
        XCTAssertNil(session.chromeBatch)
        XCTAssertTrue(session.chromeUpdateFailures.isEmpty)
        XCTAssertEqual(PreviousPasswords.items(of: try XCTUnwrap(try stored().first), now: session.chromeClock()).map(\.value), ["mine"])
    }

    func testAnOpenDetailsViewFollowsTheBackgroundWrite() async throws {
        let session = session()
        let own = account(session)
        let model = try details(session, own.id)
        XCTAssertEqual(model.fields.first { $0.kind == .password }?.value, "mine")
        await read(session, logins: [login()])
        XCTAssertEqual(model.fields.first { $0.kind == .password }?.value, "from-chrome")
        XCTAssertEqual(model.previous.map(\.value), ["mine"])
        XCTAssertNotNil(model.chromeUpdatedAt)
        XCTAssertEqual(model.focusedRow, .field("password"), "the keyboard stays on the same row")
    }

    func testAConflictOnDiskKeepsTheSavedPasswordAndTheFile() async throws {
        let session = session()
        let own = account(session)
        let theirs = Data("written by a sync client".utf8)
        try theirs.write(to: databaseURL)

        await read(session, logins: [login()])

        XCTAssertEqual(try onDisk(), theirs)
        XCTAssertEqual(session.entry(own.id)?.password, "mine")
        XCTAssertEqual(session.chromeUpdateFailures, [own.id])
        let model = try details(session, own.id)
        XCTAssertTrue(model.updateFailed)
        XCTAssertNil(model.chromeUpdatedAt, "the label stays plain while the update failed")
    }

    func testTryAgainReadsTheChangedFileAndApplies() async throws {
        let session = session()
        let own = account(session)
        let snapshot = try onDisk()
        // Another Mac adds nothing that matters. It just moves the file.
        var loaded = try KDBX.load(data: snapshot, password: "pw")
        loaded.entries[0].notes = "from another Mac"
        try KDBX.save(vault: &loaded, password: "pw").write(to: databaseURL)
        await read(session, logins: [login()])
        XCTAssertEqual(session.chromeUpdateFailures, [own.id])

        session.retryChromeUpdates()
        await waitUntil { session.chromeUpdateFailures.isEmpty && !session.chromeWriteInFlight }

        XCTAssertEqual(try stored().first?.password, "from-chrome")
        XCTAssertEqual(try stored().first?.notes, "from another Mac", "the other change is kept")
    }

    func testAnUnwritableFolderIsAFailedUpdateAndChangesNothing() async throws {
        let session = session()
        let own = account(session)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        await read(session, logins: [login()])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertEqual(session.entry(own.id)?.password, "mine")
        XCTAssertEqual(session.chromeUpdateFailures, [own.id])
        XCTAssertEqual(try stored().first?.password, "mine")
    }

    func testLockingDuringAWriteDoesNotStopLaterOnes() async throws {
        let session = session()
        _ = account(session)
        session.chromeWriteInFlight = true
        session.lock()
        XCTAssertFalse(session.chromeWriteInFlight, "the write belonged to the session that ended")
    }

    func testNothingIsWrittenUntilEveryOpenDatabaseHasLoaded() async throws {
        let session = session()
        let own = account(session)
        session.chromeAwaitingSiblings = true
        await read(session, logins: [login()])
        XCTAssertEqual(session.entry(own.id)?.password, "mine")
        XCTAssertEqual(try stored().first?.password, "mine")

        session.chromeAwaitingSiblings = false
        session.reconcileChromeUpdates()
        await waitUntil { !session.chromeWriteInFlight && session.entry(own.id)?.password == "from-chrome" }
        XCTAssertEqual(try stored().first?.password, "from-chrome")
    }

    func testRestoreLeavesAFileThatMustNotBeRewrittenAlone() async throws {
        let session = session()
        let own = account(session)
        await read(session, logins: [login()])
        let model = try details(session, own.id)
        let item = try XCTUnwrap(model.previous.first)
        let copy = databaseURL.deletingPathExtension().appendingPathExtension("bak")
        try FileManager.default.copyItem(at: databaseURL, to: copy)
        let before = try Data(contentsOf: copy)
        session.openedFiles[0].url = copy
        session.publishCatalog()

        XCTAssertFalse(session.restorePreviousPassword(item.id, of: own.id))

        XCTAssertEqual(try Data(contentsOf: copy), before)
    }

    func testTheSiblingCheckBeforeTheFirstReadLeavesAWaitingBatchAlone() async throws {
        let (session, logins) = many(11)
        await read(session, logins: logins)
        let held = session.chromeHeldEvents
        session.chromeRows = []
        session.liveEntries = []
        session.reconcileChromeUpdates()
        XCTAssertEqual(session.chromeHeldEvents, held)
    }

    func testTurningChromeOffDoesNotReleaseTheSiblingWait() {
        let session = session()
        session.chromeAwaitingSiblings = true
        session.clearChrome()
        XCTAssertTrue(session.chromeAwaitingSiblings)
    }

    func testAnAccountThatFailsTheWritingGateStaysASeparateRowAndNothingIsWritten() async throws {
        let session = session()
        let own = account(session)
        let before = try onDisk()
        await read(session, logins: [login(user: "ANN")])
        XCTAssertEqual(session.allEntries.filter { !$0.trashed }.count, 2)
        XCTAssertEqual(try onDisk(), before)
        XCTAssertEqual(session.entry(own.id)?.password, "mine")
    }

    func testAChromeValueThatDoesNotQualifyGoesToPreviousPasswords() async throws {
        let session = session()
        let own = account(session)
        await read(session, logins: [login()], date: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(session.entry(own.id)?.password, "mine")
        XCTAssertEqual(try details(session, own.id).previous.map(\.value), ["from-chrome"])
        XCTAssertEqual(try details(session, own.id).previous.first?.used, false)
    }

    func testAnUpdateLandingWhileTheEditorIsOpenIsNotUndone() async throws {
        let session = session()
        let own = account(session)
        session.edit(own.id)
        var draft = try XCTUnwrap(session.editing)
        draft.notes = "typed while it was open"
        await read(session, logins: [login()])

        session.saveEditing(draft)

        XCTAssertEqual(try stored().first?.password, "from-chrome")
        XCTAssertEqual(try stored().first?.notes, "typed while it was open")
        XCTAssertEqual(PreviousPasswords.items(of: try XCTUnwrap(try stored().first), now: session.chromeClock()).map(\.value), ["mine"])
    }

    func testAPasswordChangedInTheEditorGoesToPreviousPasswords() throws {
        let session = session()
        let own = account(session)
        session.edit(own.id)
        var draft = try XCTUnwrap(session.editing)
        draft.password = "typed"
        session.saveEditing(draft)
        XCTAssertEqual(PreviousPasswords.items(of: try XCTUnwrap(try stored().first), now: session.chromeClock()).map(\.value), ["mine"])
        XCTAssertNil(try details(session, own.id).chromeUpdatedAt)
    }

    func testAFailedEditDoesNotLinger() async throws {
        let session = session()
        let own = account(session)
        session.edit(own.id)
        var draft = try XCTUnwrap(session.editing)
        draft.notes = "never saved"
        session.editing = draft
        let before = try onDisk()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        session.saveEditing(draft)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertEqual(session.editing?.notes, "never saved", "the editor keeps what was typed")
        XCTAssertEqual(session.entry(own.id)?.notes, "")
        XCTAssertEqual(try onDisk(), before)

        await read(session, logins: [login()])
        XCTAssertEqual(try stored().first?.password, "from-chrome")
        XCTAssertEqual(try stored().first?.notes, "", "a later Chrome write must not carry the failed edit to disk")
    }

    // MARK: Previous passwords

    func testRestoreBringsTheOldPasswordBackAndTheUndoneEventStaysUndone() async throws {
        let session = session()
        let own = account(session)
        let chromeDate = Date().addingTimeInterval(clockOffset / 2)
        await read(session, logins: [login()], date: chromeDate)
        let model = try details(session, own.id)
        model.previousOpen = true
        let item = try XCTUnwrap(model.previous.first)
        model.focusedRow = .previous(item.id)
        model.revealed.insert(model.previousKey(item))

        model.restore(item)

        XCTAssertEqual(try stored().first?.password, "mine")
        XCTAssertEqual(session.entry(own.id)?.password, "mine")
        XCTAssertEqual(model.previous.map(\.value), ["from-chrome"], "the replaced value moves into the same list")
        XCTAssertEqual(model.focusedRow, .previousHeader)
        XCTAssertTrue(model.revealed.isEmpty, "reveal clears")

        await read(session, logins: [login()], date: chromeDate)
        XCTAssertEqual(try stored().first?.password, "mine", "the undone Chrome change does not come back")
        XCTAssertEqual(model.previous.map(\.value), ["from-chrome"])

        let later = session.chromeClock().addingTimeInterval(60)
        session.chromeClock = { later.addingTimeInterval(60) }
        await read(session, logins: [login(password: "changed-again")], date: later)
        XCTAssertEqual(try stored().first?.password, "changed-again", "a later Chrome change wins again")
    }

    func testAFailedRestoreShowsOnItsRowAndChangesNothing() async throws {
        let session = session()
        let own = account(session)
        await read(session, logins: [login()])
        let model = try details(session, own.id)
        let item = try XCTUnwrap(model.previous.first)
        let theirs = Data("moved by sync".utf8)
        try theirs.write(to: databaseURL)

        model.restore(item)

        XCTAssertEqual(try onDisk(), theirs)
        XCTAssertEqual(session.entry(own.id)?.password, "from-chrome")
        XCTAssertEqual(model.restoreFailures, [item.id])
        XCTAssertEqual(model.previous.map(\.value), ["mine"])
    }

    func testClearEmptiesTheListAndAClearedValueDoesNotReturn() async throws {
        let session = session()
        let own = account(session)
        let chrome = login()
        await read(session, logins: [chrome], date: Date(timeIntervalSince1970: 1_000_000))
        let model = try details(session, own.id)
        model.previousOpen = true
        model.clearPrevious()
        XCTAssertTrue(model.previous.isEmpty)
        XCTAssertEqual(model.focusedRow, .field("password"))
        await read(session, logins: [chrome], date: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertTrue(try details(session, own.id).previous.isEmpty)
    }

    // MARK: Keyboard

    private func keyboardModel(done: @escaping () -> Void = {}, fill: (() -> Void)? = nil) async throws -> (VaultSession, DetailsModel, PreviousPasswords.Item) {
        let session = session()
        let own = account(session)
        await read(session, logins: [login()])
        let model = try details(session, own.id, done: done, fill: fill)
        model.previousOpen = true
        return (session, model, try XCTUnwrap(model.previous.first))
    }

    func testUpAndDownWalkTheRowsAcrossThePreviousSection() async throws {
        let (_, model, item) = try await keyboardModel()
        XCTAssertEqual(model.focusedRow, .field("password"))
        model.move(1)
        XCTAssertEqual(model.focusedRow, .previousHeader)
        model.move(1)
        XCTAssertEqual(model.focusedRow, .previous(item.id))
        model.move(1)
        XCTAssertEqual(model.focusedRow, .field("url"))
        model.move(-1)
        XCTAssertEqual(model.focusedRow, .previous(item.id))
    }

    func testFoldingMovesTheKeyboardOffAHiddenRow() async throws {
        let (_, model, item) = try await keyboardModel()
        model.focusedRow = .previous(item.id)
        model.togglePrevious()
        XCTAssertEqual(model.focusedRow, .previousHeader)
    }

    func testReturnOnAPreviousRowCopiesAndNeverFills() async throws {
        var fills = 0, closed = 0
        let (session, model, item) = try await keyboardModel(done: { closed += 1 }, fill: { fills += 1 })
        model.focusedRow = .previous(item.id)
        model.activateFocused()
        await waitUntil { closed > 0 }
        XCTAssertEqual(fills, 0)
        XCTAssertEqual(closed, 1)
        XCTAssertNotNil(session.entry(model.entryID))
    }

    func testCommandReturnRestoresOnlyOnAPreviousRow() async throws {
        let (session, model, item) = try await keyboardModel()
        model.focusedRow = .field("password")
        XCTAssertFalse(model.restoreFocused())
        XCTAssertEqual(session.entry(model.entryID)?.password, "from-chrome")
        model.focusedRow = .previous(item.id)
        XCTAssertTrue(model.restoreFocused())
        XCTAssertEqual(session.entry(model.entryID)?.password, "mine")
        XCTAssertEqual(model.focusedRow, .previousHeader)
    }

    func testReturnOnTheHeaderOnlyFolds() async throws {
        var fills = 0, closed = 0
        let (_, model, _) = try await keyboardModel(done: { closed += 1 }, fill: { fills += 1 })
        model.focusedRow = .previousHeader
        model.activateFocused()
        XCTAssertFalse(model.previousOpen)
        XCTAssertEqual(fills, 0)
        XCTAssertEqual(closed, 0)
    }

    func testAPreviousPasswordNeverUsedSaysSo() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let unknown = PreviousPasswords.Item(value: "x", source: .chrome, date: nil, enteredAt: date, used: false)
        XCTAssertEqual(previousPasswordCaption(unknown, now: date), "date unknown · not used yet")
        let used = PreviousPasswords.Item(value: "x", source: .saved, date: date, enteredAt: date, used: true)
        XCTAssertTrue(previousPasswordCaption(used, now: date).hasPrefix("updated "))
        XCTAssertFalse(previousPasswordCaption(used, now: date).contains("not used yet"))
    }

    func testTheUpdateLabelReadsLikeAPerson() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(chromeUpdatedText(now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertEqual(chromeUpdatedText(now.addingTimeInterval(-3_700), now: now), "1 hour ago")
        XCTAssertEqual(chromeUpdatedText(now.addingTimeInterval(-2 * 86_400), now: now), "2 days ago")
    }

    // MARK: Many at once

    private func many(_ count: Int) -> (VaultSession, [VaultEntry]) {
        let session = session()
        var logins: [VaultEntry] = []
        for index in 0..<count {
            let site = "https://site\(index).example"
            _ = account(session, site: site)
            logins.append(login(site: site))
        }
        return (session, logins)
    }

    func testMoreThanTenWritesNothingAndWaits() async throws {
        let (session, logins) = many(11)
        let before = try onDisk()
        await read(session, logins: logins)
        XCTAssertEqual(try onDisk(), before)
        XCTAssertEqual(session.chromeBatch?.accounts.count, 11)
        XCTAssertEqual(session.chromeBatch?.summary, "11 passwords changed in Chrome")
        XCTAssertEqual(session.chromeBatch?.applyTitle, "Apply 11 Updates")
        XCTAssertTrue(session.allEntries.allSatisfy { $0.password == "mine" }, "the panel keeps working on the saved passwords")
    }

    func testAWaitingBatchStaysWaitingAcrossALock() async throws {
        let (session, logins) = many(11)
        await read(session, logins: logins)
        let held = session.chromeHeldEvents
        XCTAssertFalse(held.isEmpty)
        session.lock()
        XCTAssertEqual(session.chromeHeldEvents, held)
    }

    func testApplyWritesTheWholeBatchInOneWrite() async throws {
        let (session, logins) = many(11)
        await read(session, logins: logins)
        session.applyChromeBatch()
        await waitUntil { session.chromeBatch == nil }
        XCTAssertNil(session.chromeBatch)
        XCTAssertTrue(try stored().allSatisfy { $0.password == "from-chrome" })
    }

    func testDismissingKeepsTheSavedPasswordsListsChromesAndDoesNotAskAgain() async throws {
        let (session, logins) = many(11)
        let chromeDate = Date().addingTimeInterval(clockOffset / 2)
        await read(session, logins: logins, date: chromeDate)
        session.dismissChromeBatch()
        await waitUntil { session.chromeBatch == nil }
        XCTAssertTrue(try stored().allSatisfy { $0.password == "mine" })
        for entry in try stored() {
            XCTAssertEqual(PreviousPasswords.items(of: entry, now: session.chromeClock()).map(\.value), ["from-chrome"])
        }
        await read(session, logins: logins, date: chromeDate)
        XCTAssertNil(session.chromeBatch, "the same changes are not asked about twice")
        XCTAssertTrue(try stored().allSatisfy { $0.password == "mine" })
    }

    func testTenAreWrittenWithoutAsking() async throws {
        let (session, logins) = many(10)
        await read(session, logins: logins)
        XCTAssertNil(session.chromeBatch)
        XCTAssertTrue(try stored().allSatisfy { $0.password == "from-chrome" })
    }

    // MARK: Star and badge

    func testOneMarkPerIconAndTheStarWins() {
        XCTAssertEqual(iconMark(favorite: true, fromChrome: true), .favoriteStar)
        XCTAssertEqual(iconMark(favorite: true, fromChrome: false), .favoriteStar)
        XCTAssertEqual(iconMark(favorite: false, fromChrome: true), .chrome)
        XCTAssertEqual(iconMark(favorite: false, fromChrome: false), .none)
    }

    func testTheBadgeIsTheSpecifiedShareOfEachIconAtTheBottomRight() {
        let list = ChromeBadge.rect(icon: CGRect(x: 16, y: 2, width: 16, height: 16), ratio: ChromeBadge.listRatio, ring: ChromeBadge.listRing, flipped: true)
        XCTAssertEqual(list.width, 16 * 0.44, accuracy: 0.001)
        XCTAssertEqual(list.maxX, 33, accuracy: 0.001, "reaches past the icon by the ring")
        XCTAssertEqual(list.maxY, 19, accuracy: 0.001, "bottom in a y-down view")
        XCTAssertEqual(ChromeBadge.detailsRatio, 0.38)
    }

    func testTheBadgeFollowsEveryRowWithChromeInIt() async throws {
        let session = session()
        let own = account(session)
        await read(session, logins: [login()])
        XCTAssertTrue(session.chromeBadgeIDs.contains(own.id))
        XCTAssertTrue(try details(session, own.id).fromChrome)
    }

    func testAPreferencesLineSaysWhatHappens() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/PasswordPieApp/PreferencesView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("Newer Chrome passwords replace saved ones. Chrome isn't changed."))
    }
}
#endif
