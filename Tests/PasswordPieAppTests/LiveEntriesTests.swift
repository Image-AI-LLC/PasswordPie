import AppKit
import PasswordPieCore
import XCTest
@testable import PasswordPie

/// Chrome is only ever read. A login reaches the KeePass file when the user edits or favorites it, and stays one entry.
@MainActor
final class LiveEntriesTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("test.kdbx")
        setenv("PASSWORDPIE_DB", databaseURL.path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        try? FileManager.default.removeItem(at: directory)
    }

    private func unlockedSession() -> VaultSession {
        let session = VaultSession()
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        return session
    }

    private func liveLogin() -> VaultEntry {
        var live = VaultEntry()
        live.title = "github.com"
        live.url = "https://github.com/login"
        live.username = "ann"
        live.password = "chrome-secret"
        live.groupPath = ["Chrome (live)", "Work"]
        return live
    }

    private func savedEntries() throws -> [VaultEntry] {
        try KDBX.load(data: Data(contentsOf: databaseURL), password: "pw").entries
    }

    func testLiveLoginsAreSearchableButNotSavedUntilTheUserActsOnOne() throws {
        let session = unlockedSession()
        XCTAssertFalse(session.locked)
        let live = liveLogin()
        session.liveEntries = [live]

        var own = VaultEntry()
        own.title = "Own"
        session.saveEditing(own)
        session.toggleFavorite(own.id)

        XCTAssertTrue(session.isLive(live.id))
        XCTAssertFalse(session.entries.contains { $0.id == live.id })
        #if PP_DIRECT
        XCTAssertTrue(session.allEntries.contains { $0.id == live.id })
        XCTAssertNotNil(session.entry(live.id))
        #endif
        let saved = try savedEntries()
        XCTAssertEqual(saved.map(\.title), ["Own"])
        XCTAssertFalse(saved.contains { $0.password == "chrome-secret" })
        XCTAssertEqual(session.entry(own.id)?.favorite, true, "the user's own entry can still be a favorite")
    }

    func testLockingForgetsLiveLogins() {
        let session = unlockedSession()
        session.liveEntries = [liveLogin()]
        session.lock()
        XCTAssertTrue(session.liveEntries.isEmpty)
    }

    #if PP_DIRECT
    /// The store channel never has live Chrome logins.
    func testEditingALiveLoginOpensAnUnsavedDraftAndCancelLeavesTheFileAlone() throws {
        let session = unlockedSession()
        let live = liveLogin()
        session.liveEntries = [live]

        session.edit(live.id)

        let draft = try XCTUnwrap(session.editing)
        XCTAssertEqual(draft.id, live.id)
        XCTAssertEqual(draft.password, "chrome-secret")
        XCTAssertEqual(draft.groupPath, ["Chrome"])
        XCTAssertEqual(draft.tagList, ["Chrome"])
        XCTAssertTrue(session.editingIsNew, "there is nothing in the database to move to the trash yet")
        session.cancelEditing()
        XCTAssertTrue(session.entries.isEmpty)
    }

    private func accountLogins() -> [VaultEntry] {
        ["https://stash.corp.example/login", "https://gitlab.corp.example/users/sign_in"].map { url in
            var live = VaultEntry()
            live.title = websiteHost(forWebsite: url) ?? url
            live.url = url
            live.username = "ann"
            live.password = "chrome-secret"
            live.groupPath = ["Chrome (live)", "Work"]
            return live
        }
    }

    func testOneAccountOnTwoSitesIsOneRowAndSavingItKeepsItOneRow() throws {
        let session = unlockedSession()
        let logins = accountLogins()
        session.liveEntries = logins
        XCTAssertEqual(session.allEntries.count, 1)
        let id = try XCTUnwrap(session.allEntries.first?.id)
        XCTAssertEqual(id, logins[1].id)
        XCTAssertTrue(session.isLive(id))

        session.edit(id)
        session.saveEditing(try XCTUnwrap(session.editing))

        XCTAssertEqual(session.allEntries.count, 1)
        XCTAssertEqual(session.allEntries.first?.id, id)
        let saved = try savedEntries()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].title, "corp.example")
        XCTAssertEqual(EntryMerge.otherWebsites(saved[0]).map(\.value), ["https://stash.corp.example/login"])
    }

    func testEverySiteOfAnAccountCanBeOpenedAndCopiedFromItsDetails() throws {
        let session = unlockedSession()
        session.liveEntries = accountLogins()
        let entry = try XCTUnwrap(session.allEntries.first)
        let model = DetailsModel(entry: entry, session: session) {}
        let sites = model.fields.filter { $0.kind == .url || $0.kind == .otherWebsite("URL (2)") }
        XCTAssertEqual(sites.map(\.value), ["https://gitlab.corp.example/users/sign_in", "https://stash.corp.example/login"])
        XCTAssertEqual(sites.map(\.label), ["website", "website"])
        XCTAssertEqual(fieldControl(sites[1], revealed: false), fieldControl(sites[0], revealed: false))
        XCTAssertFalse(model.fields.contains { $0.kind == .custom("URL (2)") }, "listed once, as a website")
    }

    func testSavingAnEditKeepsOneEntryWithTheSameIdentity() throws {
        let session = unlockedSession()
        let live = liveLogin()
        session.liveEntries = [live]

        session.edit(live.id)
        session.saveEditing(try XCTUnwrap(session.editing))

        let saved = try savedEntries()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].id, live.id)
        XCTAssertEqual(saved[0].password, "chrome-secret")
        XCTAssertEqual(saved[0].groupPath, ["Chrome"])
        XCTAssertEqual(saved[0].tagList, ["Chrome"])
        XCTAssertEqual(session.allEntries.filter { !$0.trashed }.count, 1)
        XCTAssertFalse(session.isLive(live.id))
        XCTAssertEqual(session.entry(live.id)?.groupPath, ["Chrome"], "open details and pinned windows keep working")
    }

    func testChangingTheUsernameAndPasswordKeepsOneEntryAndShowsChromesValues() throws {
        let session = unlockedSession()
        let live = liveLogin()
        session.liveEntries = [live]

        session.edit(live.id)
        var draft = try XCTUnwrap(session.editing)
        draft.username = "ann-renamed"
        draft.password = "my-own-secret"
        session.saveEditing(draft)

        XCTAssertEqual(session.allEntries.filter { !$0.trashed }.count, 1)
        let shown = try XCTUnwrap(session.entry(live.id))
        XCTAssertEqual(shown.username, "ann-renamed")
        XCTAssertEqual(shown.password, "my-own-secret")
        XCTAssertEqual(shown.value(for: ChromeLogins.usernameFieldName), "ann")
        XCTAssertEqual(shown.value(for: ChromeLogins.passwordFieldName), "chrome-secret")
        XCTAssertEqual(session.value(of: .custom(ChromeLogins.passwordFieldName), in: shown), "chrome-secret")
    }

    func testChromesValuesAreOnlyDisplayedAndNeverReachTheFile() throws {
        let session = unlockedSession()
        let live = liveLogin()
        session.liveEntries = [live]
        session.edit(live.id)
        var draft = try XCTUnwrap(session.editing)
        draft.password = "my-own-secret"
        session.saveEditing(draft)

        session.toggleFavorite(live.id)
        session.edit(live.id)
        let reopened = try XCTUnwrap(session.editing)
        XCTAssertFalse(reopened.fields.contains { $0.value == "chrome-secret" }, "the editor edits what is stored")
        XCTAssertFalse(session.editingIsNew)
        session.saveEditing(reopened)

        for entry in try savedEntries() {
            XCTAssertFalse(entry.fields.contains { $0.value == "chrome-secret" })
        }
        XCTAssertEqual(session.entry(live.id)?.favorite, true)
        XCTAssertEqual(session.entry(live.id)?.value(for: ChromeLogins.passwordFieldName), "chrome-secret")

        session.edit(live.id)
        session.deleteEditing()
        let bin = try KDBX.load(data: Data(contentsOf: databaseURL), password: "pw").entries
        XCTAssertFalse(bin.contains { entry in entry.fields.contains { $0.value == "chrome-secret" } }, "moving it to the trash writes the stored entry too")
    }

    func testFavoritingALiveLoginSavesItFavoritedAsTheSameEntry() throws {
        let session = unlockedSession()
        let live = liveLogin()
        session.liveEntries = [live]

        session.toggleFavorite(live.id)

        let saved = try savedEntries()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].id, live.id)
        XCTAssertTrue(saved[0].favorite)
        XCTAssertEqual(saved[0].tagList.filter { $0 != "Favorite" }, ["Chrome"])
        XCTAssertEqual(session.allEntries.filter { !$0.trashed }.count, 1)
        XCTAssertEqual(session.entry(live.id)?.favorite, true)

        session.toggleFavorite(live.id)
        XCTAssertEqual(session.entry(live.id)?.favorite, false, "the second star only changes the saved entry")
        XCTAssertEqual(try savedEntries().count, 1)
    }

    func testFavoritingALiveLoginThatCannotBeWrittenLeavesItLive() throws {
        let session = unlockedSession()
        let live = liveLogin()
        session.liveEntries = [live]
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        session.toggleFavorite(live.id)

        XCTAssertTrue(session.isLive(live.id))
        XCTAssertTrue(session.entries.isEmpty)
        XCTAssertEqual(session.entry(live.id)?.favorite, false)
    }

    private func lockDatabaseFolder() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        addTeardownBlock { [directory] in
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory!.path)
        }
    }

    func testAFailedSaveOfADraftKeepsTheEditorOpenAndLeavesNoHiddenEntry() throws {
        let session = unlockedSession()
        let live = liveLogin()
        session.liveEntries = [live]
        session.edit(live.id)
        session.editing?.password = "typed-secret"
        let draft = try XCTUnwrap(session.editing)
        try lockDatabaseFolder()

        session.saveEditing(draft)

        XCTAssertEqual(session.editing?.password, "typed-secret", "what the user typed stays in the open editor")
        XCTAssertTrue(session.isLive(live.id))
        XCTAssertTrue(session.entries.isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        session.saveEditing(try XCTUnwrap(session.editing))

        XCTAssertNil(session.editing)
        let saved = try savedEntries().filter { $0.id == live.id }
        XCTAssertEqual(saved.map(\.password), ["typed-secret"], "saving again writes one row")
    }

    func testAFailedSaveOfADraftOverItsTrashedCopyKeepsTheEditorOpen() throws {
        let session = unlockedSession()
        let live = liveLogin()
        session.liveEntries = [live]
        session.toggleFavorite(live.id)
        session.edit(live.id)
        session.deleteEditing()
        session.edit(live.id)
        session.editing?.password = "typed-secret"
        let draft = try XCTUnwrap(session.editing)
        try lockDatabaseFolder()

        session.saveEditing(draft)

        XCTAssertEqual(session.editing?.password, "typed-secret")
        XCTAssertTrue(session.isLive(live.id), "the trashed row stays trashed")
    }

    func testAFailedSaveOfANewItemKeepsTheEditorOpen() throws {
        let session = unlockedSession()
        session.newEntry()
        session.editing?.title = "Typed"
        let draft = try XCTUnwrap(session.editing)
        try lockDatabaseFolder()

        session.saveEditing(draft)

        XCTAssertEqual(session.editing?.title, "Typed")
        XCTAssertTrue(session.entries.isEmpty)
    }

    func testAnEntryAlreadyInTheDatabaseAbsorbsItsChromeLogin() throws {
        let session = unlockedSession()
        var own = VaultEntry()
        own.title = "GitHub"
        own.url = "https://github.com"
        own.username = "ann"
        own.password = "my-own-secret"
        session.saveEditing(own)
        session.liveEntries = [liveLogin()]

        XCTAssertEqual(session.allEntries.filter { !$0.trashed }.map(\.id), [own.id])
        XCTAssertEqual(session.entry(own.id)?.value(for: ChromeLogins.passwordFieldName), "chrome-secret")
    }

    func testAChromePasswordChangedLaterShowsBesideTheSavedOne() throws {
        let session = unlockedSession()
        let live = liveLogin()
        session.liveEntries = [live]
        session.toggleFavorite(live.id)

        var changed = live
        changed.password = "changed-in-chrome"
        session.liveEntries = [changed]

        XCTAssertEqual(session.entry(live.id)?.password, "chrome-secret")
        XCTAssertEqual(session.entry(live.id)?.value(for: ChromeLogins.passwordFieldName), "changed-in-chrome")
        XCTAssertEqual(session.allEntries.filter { !$0.trashed }.count, 1)
    }

    func testTrashingTheSavedEntryBringsBackTheLiveLoginAndSavingAgainReusesItsRow() throws {
        let session = unlockedSession()
        let live = liveLogin()
        session.liveEntries = [live]
        session.toggleFavorite(live.id)

        session.edit(live.id)
        session.deleteEditing()
        XCTAssertTrue(session.isLive(live.id), "Chrome still has it")
        XCTAssertEqual(session.entry(live.id)?.password, "chrome-secret")

        session.edit(live.id)
        session.saveEditing(try XCTUnwrap(session.editing))

        XCTAssertEqual(session.entries.filter { $0.id == live.id }.count, 1, "a KeePass UUID stays unique")
        XCTAssertFalse(session.isLive(live.id))
        XCTAssertEqual(try savedEntries().filter { !$0.trashed && $0.id == live.id }.count, 1)
    }

    func testPinnedWindowsSeeTheSameCombinedEntry() {
        let live = liveLogin()
        var saved = live
        saved.password = "my-own-secret"
        let shown = VaultSession.visibleEntries(saved: [saved], live: [live])
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown[0].value(for: ChromeLogins.passwordFieldName), "chrome-secret")
    }

    func testTheChromePasswordFieldCanBeRevealedAndCopied() throws {
        let session = unlockedSession()
        let live = liveLogin()
        var saved = live
        saved.password = "my-own-secret"
        session.saveEditing(saved)
        session.liveEntries = [live]

        let model = DetailsModel(entry: try XCTUnwrap(session.entry(live.id)), session: session) {}
        let field = try XCTUnwrap(model.fields.first { $0.label == ChromeLogins.passwordFieldName })
        XCTAssertTrue(field.secret)
        XCTAssertFalse(model.isShown(field), "masked until asked")
        XCTAssertEqual(fieldControl(field, revealed: false), FieldControl(primary: .copy, menu: [.reveal, .largeType]))
    }
    #endif

    func testChromeLastUsedTimesFeedTheRankingMapAndLaterOnesWin() {
        let session = unlockedSession()
        let live = liveLogin()
        let early = Date(timeIntervalSince1970: 1_000)
        session.chromeLastUsed = [live.id: early]
        XCTAssertEqual(session.lastUsedMap[live.id], early)
        session.lock()
        XCTAssertTrue(session.lastUsedMap.isEmpty, "locking forgets Chrome's times")
    }

    #if PP_DIRECT
    private func assertKeepsLastUsedTime(save: (VaultSession, UUID) throws -> Void) throws {
        let session = unlockedSession()
        let live = liveLogin()
        let used = Date(timeIntervalSince1970: 1_700_000_000)
        session.liveEntries = [live]
        session.chromeLastUsed = [live.id: used]
        try save(session, live.id)
        session.chromeLastUsed = [:]
        XCTAssertEqual(try XCTUnwrap(session.lastUsedMap[live.id]).timeIntervalSince1970, used.timeIntervalSince1970, accuracy: 1)
    }

    func testSavingAnEditKeepsChromesLastUsedTimeAfterChromeIsOff() throws {
        try assertKeepsLastUsedTime { session, id in
            session.edit(id)
            session.saveEditing(try XCTUnwrap(session.editing))
        }
    }

    func testFavoritingKeepsChromesLastUsedTimeAfterChromeIsOff() throws {
        try assertKeepsLastUsedTime { session, id in session.toggleFavorite(id) }
    }
    #endif

    func testImportedPasswordsAreSavedIntoTheUnlockedFileAndShowInTheList() throws {
        let session = unlockedSession()
        var own = VaultEntry()
        own.title = "Own"
        session.saveEditing(own)

        var imported = VaultEntry(groupPath: ["Chrome"], tags: "Chrome")
        imported.title = "github.com"
        imported.url = "https://github.com"
        imported.username = "ann"
        imported.password = "imported-secret"
        let summary = session.mergeImported([imported], source: .chrome)

        XCTAssertEqual(summary, BrowserImportSummary(added: 1, updated: 0, unchanged: 0, removed: 0))
        XCTAssertEqual(Set(session.entries.map(\.title)), ["Own", "github.com"])
        let saved = try savedEntries()
        XCTAssertEqual(Set(saved.map(\.title)), ["Own", "github.com"])
        XCTAssertEqual(saved.first { $0.title == "github.com" }?.groupPath, ["Chrome"])

        // A second export without that site moves it to the recycle bin, and leaves the user's own entry alone.
        var other = VaultEntry(groupPath: ["Chrome"], tags: "Chrome")
        other.title = "news.example"
        other.url = "https://news.example"
        other.username = "bob"
        other.password = "pw2"
        let second = session.mergeImported([other], source: .chrome)
        XCTAssertEqual(second, BrowserImportSummary(added: 1, updated: 0, unchanged: 0, removed: 1))
        XCTAssertFalse(session.entries.contains { $0.title == "github.com" && !$0.trashed })
        XCTAssertTrue(session.entries.contains { $0.title == "Own" && !$0.trashed })
    }
}
