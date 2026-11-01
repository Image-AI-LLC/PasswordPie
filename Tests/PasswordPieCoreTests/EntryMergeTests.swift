import XCTest
@testable import PasswordPieCore

final class EntryMergeTests: XCTestCase {
    private func account(
        _ title: String,
        user: String = "ada",
        password: String = "secret",
        url: String = "https://github.com/login",
        notes: String = "",
        tags: String = "",
        favorite: Bool = false,
        path: [String] = [],
        id: UUID = UUID()
    ) -> VaultEntry {
        var entry = VaultEntry(id: id, groupPath: path, tags: tags)
        entry.title = title
        entry.username = user
        entry.password = password
        entry.url = url
        entry.notes = notes
        if favorite { entry.favorite = true }
        return entry
    }

    private func live(_ entries: [VaultEntry]) -> [VaultEntry] {
        entries.filter { !$0.trashed }
    }

    func testSameLoginBecomesOneAccountAndTheCopyIsTrashed() {
        let first = account("GitHub", id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        var second = account("GitHub", notes: "backup codes", id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        second.favorite = true
        let merged = EntryMerge.merged([first, second])
        XCTAssertEqual(live(merged).map(\.id), [second.id])
        XCTAssertEqual(merged.first { $0.id == first.id }?.trashed, true)
        XCTAssertEqual(EntryMerge.partCount(live(merged)[0]), 2)
    }

    func testDifferentPasswordUsernameOrWebsiteStaysSeparate() {
        let base = account("GitHub")
        XCTAssertEqual(live(EntryMerge.merged([base, account("GitHub", password: "other")])).count, 2)
        XCTAssertEqual(live(EntryMerge.merged([base, account("GitHub", user: "grace")])).count, 2)
        XCTAssertEqual(live(EntryMerge.merged([base, account("GitHub", url: "https://gitlab.com")])).count, 2)
    }

    func testEmptyLoginPartsAreNotMerged() {
        let named = account("GitHub")
        XCTAssertEqual(live(EntryMerge.merged([named, account("GitHub", password: "")])).count, 2)
        XCTAssertEqual(live(EntryMerge.merged([named, account("GitHub", user: "")])).count, 2)
        let bare = account("GitHub", url: "")
        var other = bare
        other.id = UUID()
        other.title = "GitHub"
        XCTAssertEqual(live(EntryMerge.merged([bare, other])).count, 2)
    }

    func testWebsiteHostIgnoresSchemeWwwAndPath() {
        let web = account("GitHub", url: "https://www.github.com/login")
        let plain = account("github.com", url: "http://github.com/settings", notes: "extra")
        let merged = EntryMerge.merged([web, plain])
        XCTAssertEqual(live(merged).count, 1)
        XCTAssertEqual(EntryMerge.partCount(live(merged)[0]), 2)
    }

    func testSubdomainsStaySeparate() {
        let mail = account("Google", url: "https://mail.google.com")
        let accounts = account("Google", url: "https://accounts.google.com")
        XCTAssertEqual(live(EntryMerge.merged([mail, accounts])).count, 2)
    }

    func testABareDomainTitleMatchesThatWebsite() {
        let titled = account("github.com", url: "")
        let site = account("GitHub", url: "https://github.com/settings", notes: "extra")
        XCTAssertEqual(live(EntryMerge.merged([titled, site])).count, 1)
    }

    func testDifferentValuesKeepANumberedName() {
        let first = account("GitHub", url: "https://github.com/login", tags: "office", path: ["Work"])
        var second = account("GitHub work", url: "https://github.com/settings", notes: "token", tags: "work", path: ["Home"])
        second.otp = "otpauth://totp/GitHub:ada?secret=GEZDGNBVGY3TQOJQ&issuer=GitHub"
        let kept = live(EntryMerge.merged([first, second]))[0]
        XCTAssertEqual(kept.title, "GitHub work")
        XCTAssertEqual(kept.value(for: "Title (2)"), "GitHub")
        XCTAssertTrue(kept.url == "https://github.com/settings" || kept.url == "https://github.com/login")
        XCTAssertTrue(kept.fields.contains { $0.key == "URL (2)" })
        XCTAssertEqual(kept.value(for: "Group (2)"), "Work")
        XCTAssertEqual(kept.value(for: "Tags (2)"), "office")
        XCTAssertFalse(kept.otp.isEmpty)
    }

    func testTheSameValueIsNotNumbered() {
        let first = account("GitHub", notes: "same")
        let second = account("GitHub", notes: "same")
        let kept = live(EntryMerge.merged([first, second]))[0]
        XCTAssertFalse(kept.fields.contains { $0.key.hasPrefix("Title (") || $0.key.hasPrefix("Notes (") })
        XCTAssertEqual(EntryMerge.partCount(kept), 2)
    }

    func testALongerNoteReplacesANoteItContains() {
        var first = account("GitHub", notes: "hello")
        first.favorite = true
        let second = account("GitHub", notes: "say hello please")
        let kept = live(EntryMerge.merged([first, second]))[0]
        XCTAssertEqual(kept.id, first.id)
        XCTAssertEqual(kept.notes, "say hello please")
        XCTAssertFalse(kept.fields.contains { $0.key.hasPrefix("Notes (") })
    }

    func testDifferentNotesAreBothKept() {
        var first = account("GitHub", notes: "hello")
        first.favorite = true
        let second = account("GitHub", notes: "goodbye")
        let kept = live(EntryMerge.merged([first, second]))[0]
        XCTAssertEqual(kept.notes, "hello")
        XCTAssertEqual(kept.value(for: "Notes (2)"), "goodbye")
    }

    func testUsernameCaseMergesAndKeepsBothSpellings() {
        var first = account("GitHub", user: "Ada")
        first.favorite = true
        let second = account("GitHub", user: "ada")
        let kept = live(EntryMerge.merged([first, second]))[0]
        XCTAssertEqual(kept.username, "Ada")
        XCTAssertEqual(kept.value(for: "UserName (2)"), "ada")
    }

    func testKeepSeparateAccountsAreNeverMerged() {
        var marked = account("GitHub")
        EntryMerge.setKeepSeparate(true, on: &marked)
        let other = account("GitHub", notes: "extra")
        let merged = EntryMerge.merged([marked, other])
        XCTAssertEqual(live(merged).count, 2)
        XCTAssertFalse(live(merged).contains { EntryMerge.partCount($0) >= 2 })
    }

    func testASecondMergeKeepsEditsAndAppendsTheNewAccount() {
        let first = account("GitHub", id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
        var second = account("GitHub copy", notes: "extra", id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
        second.favorite = true
        var once = EntryMerge.merged([first, second])
        var kept = live(once)[0]
        kept.title = "Edited"
        once[once.firstIndex { $0.id == kept.id }!] = kept
        let third = account("GitHub three", url: "https://github.com/three", id: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!)
        let twice = EntryMerge.merged(once + [third])
        let survivor = live(twice)[0]
        XCTAssertEqual(survivor.title, "Edited")
        XCTAssertEqual(survivor.value(for: "Title (2)"), "GitHub")
        XCTAssertEqual(EntryMerge.partCount(survivor), 3)
        XCTAssertEqual(twice.first { $0.id == third.id }?.trashed, true)
        XCTAssertEqual(EntryMerge.merged(twice), twice)
    }

    func testRestoringATrashedCopyDoesNotDuplicateSuffixes() {
        let first = account("GitHub")
        var second = account("GitHub copy", notes: "extra")
        second.favorite = true
        let once = EntryMerge.merged([first, second])
        var restored = once
        let slot = restored.firstIndex { $0.id == first.id }!
        restored[slot].trashed = false
        let again = EntryMerge.merged(restored)
        let kept = live(again)[0]
        XCTAssertEqual(EntryMerge.partCount(kept), 2)
        XCTAssertEqual(kept.fields.filter { $0.key == "Title (2)" }.count, 1)
        XCTAssertEqual(again.first { $0.id == first.id }?.trashed, true)
    }

    func testSplitRestoresTheOriginalAccountsAndMarksThem() {
        let work = account("GitHub", url: "https://github.com/login", notes: "work", path: ["Work"], id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
        var home = account("GitHub home", url: "https://github.com/settings", notes: "home", path: ["Home"], id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!)
        home.favorite = true
        let merged = EntryMerge.merged([work, home])
        let kept = live(merged)[0]
        let parts = EntryMerge.split(kept)
        XCTAssertEqual(parts?.map(\.id), [home.id, work.id])
        XCTAssertEqual(parts?.map(\.title), ["GitHub home", "GitHub"])
        XCTAssertEqual(parts?.map(\.groupPath), [["Home"], ["Work"]])
        XCTAssertEqual(parts?.map(\.notes), ["home", "work"])
        XCTAssertEqual(parts?.allSatisfy { EntryMerge.keepsSeparate($0) && !$0.trashed }, true)
        XCTAssertEqual(parts?.allSatisfy { EntryMerge.partCount($0) == 0 }, true)
        let rejoined = EntryMerge.merged((parts ?? []) + merged.filter(\.trashed))
        XCTAssertEqual(live(rejoined).count, 2)
    }

    func testMergeSurvivesASaveAndSplitStillRestoresGroups() throws {
        let work = account("GitHub", notes: "work note", path: ["Work"], id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!)
        var home = account("GitHub home", notes: "home note", path: ["Home"], id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!)
        home.favorite = true
        var vault = Vault(entries: EntryMerge.merged([work, home]), kdf: .fastTest)
        let loaded = try KDBX.load(data: try KDBX.save(vault: &vault, password: "secret"), password: "secret")
        let kept = try XCTUnwrap(loaded.entries.first { !$0.trashed })
        XCTAssertEqual(EntryMerge.partCount(kept), 2)
        XCTAssertEqual(kept.value(for: "Title (2)"), "GitHub")
        let parts = try XCTUnwrap(EntryMerge.split(kept))
        var restored = Vault(entries: parts, kdf: .fastTest)
        let round = try KDBX.load(data: try KDBX.save(vault: &restored, password: "secret"), password: "secret")
        let byTitle = Dictionary(uniqueKeysWithValues: round.entries.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["GitHub home"]?.groupPath, ["Home"])
        XCTAssertEqual(byTitle["GitHub"]?.groupPath, ["Work"])
        XCTAssertEqual(byTitle["GitHub"]?.notes, "work note")
        XCTAssertTrue(round.entries.allSatisfy { EntryMerge.keepsSeparate($0) && !$0.trashed })
    }

    func testTheMergeRecordIsNotASearchHit() {
        var entry = account("GitHub")
        entry.setValue("zzmanifesttoken", for: EntryMerge.manifestKey, protected: true)
        XCTAssertTrue(searchEntries([entry], query: "zzmanifesttoken", scope: .allFields).isEmpty)
        XCTAssertEqual(searchEntries([entry], query: "github", scope: .major).map(\.title), ["GitHub"])
    }
}
