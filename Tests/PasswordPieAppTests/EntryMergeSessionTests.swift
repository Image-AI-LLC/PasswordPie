import AppKit
import PasswordPieCore
import XCTest
@testable import PasswordPie

@MainActor
final class EntryMergeSessionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
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

    private func login(_ title: String, notes: String = "") -> VaultEntry {
        var entry = VaultEntry()
        entry.title = title
        entry.username = "ada"
        entry.password = "secret"
        entry.url = "https://github.com/login"
        entry.notes = notes
        return entry
    }

    func testSavingDuplicatesMergesAndSplitKeepsThemApart() {
        let session = unlockedSession()
        let first = login("GitHub")
        session.saveEditing(first)
        session.saveEditing(login("GitHub copy", notes: "extra"))

        let merged = session.entries.filter { !$0.trashed }
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(EntryMerge.partCount(merged[0]), 2)

        session.edit(merged[0].id)
        session.splitEditing()
        let split = session.entries.filter { !$0.trashed }
        XCTAssertEqual(split.map(\.title).sorted(), ["GitHub", "GitHub copy"])
        XCTAssertTrue(split.allSatisfy { EntryMerge.keepsSeparate($0) && EntryMerge.partCount($0) == 0 })

        session.saveEditing(login("GitHub again"))
        XCTAssertEqual(session.entries.filter { !$0.trashed }.count, 3)

        let marked = session.entries.filter { !$0.trashed && EntryMerge.keepsSeparate($0) }
        for item in marked {
            var copy = item
            EntryMerge.setKeepSeparate(false, on: &copy)
            session.saveEditing(copy)
        }
        let visible = session.entries.filter { !$0.trashed }
        XCTAssertEqual(visible.count, 1)
        XCTAssertGreaterThanOrEqual(EntryMerge.partCount(visible[0]), 2)
    }

    func testUnlockMergesDuplicatesAlreadyInTheFile() async throws {
        var vault = Vault(entries: [login("GitHub"), login("GitHub copy", notes: "extra")], kdf: .fastTest)
        let url = directory.appendingPathComponent("test.kdbx")
        try KDBX.save(vault: &vault, password: "pw").write(to: url)

        let session = VaultSession()
        session.restore()
        XCTAssertFalse(session.creating)
        session.passwordDraft = "pw"
        session.unlock()
        for _ in 0..<500 where session.unlocking {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(session.locked)
        XCTAssertFalse(session.unlocking)
        XCTAssertEqual(session.entries.filter { !$0.trashed }.count, 1)

        let saved = try KDBX.load(data: Data(contentsOf: url), password: "pw")
        XCTAssertEqual(saved.entries.filter { !$0.trashed }.count, 1)
        XCTAssertEqual(saved.entries.filter(\.trashed).count, 1)
    }

    func testProtectedMergeFieldsStayMasked() {
        let secret = VaultField(key: "PIN", value: "1234", protected: true)
        let plain = VaultField(key: "Title (2)", value: "GitHub", protected: false)
        XCTAssertFalse(mergedExtraFieldText(secret).contains("1234"))
        XCTAssertEqual(mergedExtraFieldText(plain), "GitHub")
    }

    func testSplitUsesTheEditedRowWhenAnotherRowSharesItsIdentifier() async throws {
        let shared = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        var plain = login("Plain")
        plain.id = shared
        plain.password = "other-secret"
        var merged = login("Merged")
        merged.id = shared
        merged.password = "merged-secret"
        merged.notes = "kept on the merged row"
        var older = login("Older")
        older.password = "merged-secret"
        let folded = EntryMerge.merged([merged, older])
        let survivor = try XCTUnwrap(folded.first { !$0.trashed })
        XCTAssertEqual(survivor.id, shared)
        var vault = Vault(entries: [plain, survivor] + folded.filter(\.trashed), kdf: .fastTest)
        let url = directory.appendingPathComponent("test.kdbx")
        try KDBX.save(vault: &vault, password: "pw").write(to: url)

        let session = VaultSession()
        session.restore()
        session.passwordDraft = "pw"
        session.unlock()
        for _ in 0..<500 where session.unlocking {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(session.locked)
        let edited = try XCTUnwrap(session.entries.first { $0.title == "Merged" && !$0.trashed })
        session.edit(edited.id)
        session.splitEditing()
        let live = session.entries.filter { !$0.trashed }
        XCTAssertTrue(live.contains { $0.title == "Plain" && $0.password == "other-secret" })
        XCTAssertTrue(live.contains { $0.title == "Older" })
    }

    func testAStaleSplitSlotKeepsTheOtherAccount() {
        let kept = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
        let other = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
        var plain = VaultEntry()
        plain.id = other
        var merged = VaultEntry()
        merged.id = kept
        XCTAssertEqual(SplitPlacement.index(slot: 0, entries: [plain, merged], id: kept), 1)
    }

    func testDetailsHidesTheMergeRecordAndShowsNumberedFields() {
        let session = unlockedSession()
        var entry = VaultEntry()
        entry.title = "GitHub"
        entry.username = "ada"
        entry.password = "secret"
        entry.setValue("secret-json", for: EntryMerge.manifestKey, protected: true)
        entry.setValue("1", for: EntryMerge.keepSeparateKey)
        entry.setValue("GitHub copy", for: "Title (2)")
        let model = DetailsModel(entry: entry, session: session, done: {})
        XCTAssertFalse(model.fields.contains { $0.label == EntryMerge.manifestKey || $0.label == EntryMerge.keepSeparateKey })
        XCTAssertTrue(model.fields.contains { $0.label == "Title (2)" && $0.value == "GitHub copy" })
    }
}
