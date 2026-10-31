import XCTest
@testable import PasswordPieCore

final class BrowserImportTests: XCTestCase {
    private let chromeCSV = """
    name,url,username,password,note
    github.com,https://github.com/login,ann@example.com,hunter2,work account
    news.example,https://www.news.example/,ann,s3cret,
    """

    private let appleCSV = """
    Title,URL,Username,Password,Notes,OTPAuth
    GitHub (ann),https://github.com,ann,pw1,,otpauth://totp/GitHub:ann?secret=JBSWY3DPEHPK3PXP
    """

    private func entry(_ url: String, _ user: String, _ password: String, source: BrowserImportSource = .chrome) -> VaultEntry {
        var e = VaultEntry(groupPath: [source.label], tags: source.label)
        e.title = url
        e.url = url
        e.username = user
        e.password = password
        return e
    }

    // MARK: Parsing

    func testChromeCSVBecomesEntriesInTheChromeGroup() throws {
        let entries = try BrowserImport.entries(fromCSV: Data(chromeCSV.utf8), source: .chrome)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].title, "github.com")
        XCTAssertEqual(entries[0].username, "ann@example.com")
        XCTAssertEqual(entries[0].password, "hunter2")
        XCTAssertEqual(entries[0].notes, "work account")
        XCTAssertEqual(entries[0].groupPath, ["Chrome"])
        XCTAssertEqual(entries[0].tagList, ["Chrome"])
    }

    func testApplePasswordsCSVKeepsTheOneTimeCode() throws {
        let entries = try BrowserImport.entries(fromCSV: Data(appleCSV.utf8), source: .applePasswords)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].groupPath, ["Apple Passwords"])
        XCTAssertEqual(entries[0].tagList, ["Apple Passwords"])
        XCTAssertTrue(entries[0].otp.contains("JBSWY3DPEHPK3PXP"))
    }

    func testFileWithoutAPasswordColumnIsRejected() {
        let csv = "name,url,username\nfoo,https://foo.example,bar\n"
        XCTAssertThrowsError(try BrowserImport.entries(fromCSV: Data(csv.utf8), source: .chrome))
    }

    func testEmptyFileIsRejected() {
        XCTAssertThrowsError(try BrowserImport.entries(fromCSV: Data(), source: .chrome))
        XCTAssertThrowsError(try BrowserImport.entries(fromCSV: Data("name,url,username,password,note\n".utf8), source: .chrome))
    }

    // MARK: Merging

    func testFirstImportAddsEverything() {
        let result = BrowserImport.merge([entry("https://a.example", "u", "p")], into: [], source: .chrome)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.summary, BrowserImportSummary(added: 1, updated: 0, unchanged: 0, removed: 0))
    }

    func testReimportUpdatesThePasswordAndKeepsTheUsersOtherEdits() {
        var existing = entry("https://a.example/login", "u", "old")
        existing.notes = "my note"
        existing.setValue("blue", for: "Custom")
        let originalID = existing.id
        let result = BrowserImport.merge([entry("https://www.a.example/", "U", "new")], into: [existing], source: .chrome)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].id, originalID)
        XCTAssertEqual(result.entries[0].password, "new")
        XCTAssertEqual(result.entries[0].notes, "my note")
        XCTAssertEqual(result.entries[0].value(for: "Custom"), "blue")
        XCTAssertEqual(result.summary, BrowserImportSummary(added: 0, updated: 1, unchanged: 0, removed: 0))
    }

    func testIdenticalReimportChangesNothing() {
        let existing = entry("https://a.example", "u", "p")
        let result = BrowserImport.merge([entry("https://a.example", "u", "p")], into: [existing], source: .chrome)
        XCTAssertEqual(result.entries, [existing])
        XCTAssertEqual(result.summary, BrowserImportSummary(added: 0, updated: 0, unchanged: 1, removed: 0))
    }

    func testEntriesMissingFromTheNewExportMoveToTheRecycleBin() {
        let kept = entry("https://a.example", "u", "p")
        let gone = entry("https://b.example", "u", "p")
        let result = BrowserImport.merge([entry("https://a.example", "u", "p")], into: [kept, gone], source: .chrome)
        XCTAssertFalse(result.entries.first { $0.id == kept.id }!.trashed)
        XCTAssertTrue(result.entries.first { $0.id == gone.id }!.trashed)
        XCTAssertEqual(result.summary.removed, 1)
    }

    func testTheUsersOwnEntriesAreNeverTouched() {
        var own = VaultEntry(groupPath: ["Personal"])
        own.title = "Mine"
        own.url = "https://a.example"
        own.username = "u"
        own.password = "mine"
        let appleEntry = entry("https://c.example", "u", "p", source: .applePasswords)
        let result = BrowserImport.merge([entry("https://a.example", "u", "chrome")], into: [own, appleEntry], source: .chrome)
        XCTAssertEqual(result.entries.first { $0.id == own.id }, own)
        XCTAssertEqual(result.entries.first { $0.id == appleEntry.id }, appleEntry)
        XCTAssertEqual(result.entries.count, 3)
        XCTAssertEqual(result.summary.added, 1)
    }

    func testAUserEntryTaggedLikeTheSourceInAnotherGroupIsLeftAlone() {
        var own = VaultEntry(groupPath: ["Personal"], tags: "Chrome")
        own.title = "Mine"
        own.url = "https://b.example"
        own.username = "u"
        own.password = "mine"
        let result = BrowserImport.merge([entry("https://a.example", "u", "chrome")], into: [own], source: .chrome)
        XCTAssertEqual(result.entries.first { $0.id == own.id }, own)
        XCTAssertFalse(result.entries.first { $0.id == own.id }!.trashed)
        XCTAssertEqual(result.summary.removed, 0)
    }

    func testAnEntryTheUserDeletedStaysDeleted() {
        var deleted = entry("https://a.example", "u", "p")
        deleted.trashed = true
        let result = BrowserImport.merge([entry("https://a.example", "u", "p")], into: [deleted], source: .chrome)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertTrue(result.entries[0].trashed)
        XCTAssertEqual(result.summary, BrowserImportSummary(added: 0, updated: 0, unchanged: 0, removed: 0))
    }

    func testSameSiteAndUserTwiceInOneExportLosesNothing() {
        let imported = [entry("https://a.example/one", "u", "p1"), entry("https://a.example/two", "u", "p2")]
        let first = BrowserImport.merge(imported, into: [], source: .chrome)
        XCTAssertEqual(first.entries.map(\.password), ["p1", "p2"])
        let second = BrowserImport.merge(imported, into: first.entries, source: .chrome)
        XCTAssertEqual(second.entries.count, 2)
        XCTAssertEqual(second.summary, BrowserImportSummary(added: 0, updated: 0, unchanged: 2, removed: 0))
    }

    func testAnEmptyImportNeverWipesTheGroup() {
        let existing = entry("https://a.example", "u", "p")
        let result = BrowserImport.merge([], into: [existing], source: .chrome)
        XCTAssertEqual(result.entries, [existing])
        XCTAssertEqual(result.summary, BrowserImportSummary(added: 0, updated: 0, unchanged: 0, removed: 0))
    }

    func testMergedVaultSurvivesAKDBXRoundTrip() throws {
        let imported = try BrowserImport.entries(fromCSV: Data(chromeCSV.utf8), source: .chrome)
        var vault = Vault(entries: BrowserImport.merge(imported, into: [], source: .chrome).entries, kdf: .fastTest)
        let data = try KDBX.save(vault: &vault, password: "pw")
        let reopened = try KDBX.load(data: data, password: "pw")
        XCTAssertEqual(reopened.entries.count, 2)
        XCTAssertEqual(reopened.entries[0].groupPath, ["Chrome"])
        XCTAssertEqual(reopened.entries[0].tagList, ["Chrome"])
        XCTAssertEqual(reopened.entries[0].password, "hunter2")
    }

    // MARK: Plain-text export cleanup

    func testDeletingTheExportRemovesTheFileForGood() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).csv")
        try Data(chromeCSV.utf8).write(to: url)
        try BrowserImport.deleteExport(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDeletingAnExportThatIsGoneReportsTheFailure() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).csv")
        XCTAssertThrowsError(try BrowserImport.deleteExport(at: url))
    }
}
