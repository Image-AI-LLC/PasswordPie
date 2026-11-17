import AppKit
@testable import PasswordPieCore
import XCTest
@testable import PasswordPie

/// Preferences > Import, from a source's page to the file being gone (docs/UX.md, "Import with a guide").
@MainActor
final class ImportFlowTests: XCTestCase {
    private var directory: URL!

    private let chromeCSV = """
    name,url,username,password,note
    github.com,https://github.com/login,ann@example.com,hunter2,work account
    news.example,https://www.news.example/,ann,s3cret,
    """

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("flow-\(UUID().uuidString)", isDirectory: true)
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
        let session = VaultSession(writes: .inline)
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        return session
    }

    private func export(_ name: String = "Chrome Passwords.csv", _ text: String? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data((text ?? chromeCSV).utf8).write(to: url)
        return url
    }

    private func flow(_ session: VaultSession, on id: String = "chrome") throws -> ImportFlow {
        let flow = ImportFlow(session: session)
        flow.choose(try XCTUnwrap(ImportTile.tile(id)))
        return flow
    }

    private func outcome(_ flow: ImportFlow) throws -> ImportFlow.Outcome {
        guard case .done(let outcome) = flow.stage else {
            XCTFail("not done: \(flow.stage), \(flow.error)")
            throw CocoaError(.featureUnsupported)
        }
        return outcome
    }

    // MARK: A file

    func testADroppedFileIsCountedAndNothingIsInTheDatabaseYet() throws {
        let session = unlockedSession()
        let flow = try flow(session)
        flow.take(try export())
        XCTAssertEqual(flow.stage, .found(fileName: "Chrome Passwords.csv", count: 2))
        XCTAssertEqual(flow.error, "")
        XCTAssertTrue(session.entries.isEmpty)
    }

    func testImportPutsThemInTheSourcesGroupAndAsksAboutThePlainTextFile() throws {
        let session = unlockedSession()
        let flow = try flow(session)
        let url = try export()
        flow.take(url)
        flow.commit()
        let outcome = try outcome(flow)
        XCTAssertEqual(outcome.summary, BrowserImportSummary(added: 2))
        XCTAssertEqual(outcome.file, .ask)
        XCTAssertEqual(session.entries.map(\.groupPath), [["Chrome"], ["Chrome"]])
        XCTAssertEqual(ImportFlow.summaryText(outcome), "2 added, in the “Chrome” group.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "nothing is deleted without being asked")
    }

    func testDeleteFileRemovesTheExportForGood() throws {
        let session = unlockedSession()
        let flow = try flow(session)
        let url = try export()
        flow.take(url)
        flow.commit()
        flow.deleteFile()
        XCTAssertEqual(try outcome(flow).file, .deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(ImportFlow.fileText(try outcome(flow)), "The export file was deleted.")
    }

    func testKeepFileLeavesItAndSaysItIsStillThere() throws {
        let session = unlockedSession()
        let flow = try flow(session)
        let url = try export()
        flow.take(url)
        flow.commit()
        flow.keepFile()
        XCTAssertEqual(try outcome(flow).file, .kept)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(ImportFlow.fileText(try outcome(flow)).contains("still on disk"))
    }

    func testAFileThatCannotBeDeletedSaysSo() throws {
        let session = unlockedSession()
        let flow = try flow(session)
        let url = try export()
        flow.take(url)
        flow.commit()
        try FileManager.default.removeItem(at: url)
        flow.deleteFile()
        XCTAssertEqual(try outcome(flow).file, .deleteFailed)
    }

    func testImportingTheSameFileAgainChangesNothing() throws {
        let session = unlockedSession()
        let flow = try flow(session)
        let url = try export()
        flow.take(url)
        flow.commit()
        flow.keepFile()
        flow.startOver()
        XCTAssertEqual(flow.stage, .waiting)
        flow.take(url)
        flow.commit()
        let outcome = try outcome(flow)
        XCTAssertEqual(outcome.summary, BrowserImportSummary(unchanged: 2))
        XCTAssertEqual(ImportFlow.summaryText(outcome), "Chrome is already up to date. Nothing was changed.")
        XCTAssertEqual(session.entries.count, 2)
    }

    // MARK: The wrong file

    func testAFileWithoutPasswordsStaysOutAndSaysWhy() throws {
        let session = unlockedSession()
        let flow = try flow(session)
        flow.take(try export("bookmarks.csv", "name,url\nExample,https://example.com\n"))
        XCTAssertEqual(flow.stage, .waiting)
        XCTAssertEqual(flow.error, "This file has no Password column, so it is not a password export.")
        flow.commit()
        XCTAssertTrue(session.entries.isEmpty)
    }

    func testALockedDatabaseTakesNoFile() throws {
        let session = VaultSession(writes: .inline)
        session.restore()
        XCTAssertTrue(session.locked)
        let flow = try flow(session)
        flow.take(try export())
        XCTAssertEqual(flow.stage, .waiting)
        XCTAssertEqual(flow.error, "Unlock PasswordPie first.")
    }

    func testLockingForgetsWhatWasRead() throws {
        let session = unlockedSession()
        let flow = try flow(session)
        flow.take(try export())
        session.lock()
        XCTAssertEqual(flow.stage, .waiting)
        flow.commit()
        XCTAssertEqual(flow.stage, .waiting)
    }

    func testGoingBackToTheSourcesForgetsTheFile() throws {
        let session = unlockedSession()
        let flow = try flow(session)
        flow.take(try export())
        flow.showSources()
        XCTAssertNil(flow.tile)
        flow.choose(try XCTUnwrap(ImportTile.tile("firefox")))
        XCTAssertEqual(flow.stage, .waiting)
        flow.commit()
        XCTAssertTrue(session.entries.isEmpty)
    }

    func testKeePassHasNoFileToTake() throws {
        let session = unlockedSession()
        let flow = try flow(session, on: "keepass")
        flow.take(try export())
        XCTAssertEqual(flow.stage, .waiting)
    }

    // MARK: A protected file

    func testAProtectedFileAsksForItsPasswordAndIsNotOfferedForDeletion() throws {
        let fixture = URL(fileURLWithPath: "/Users/oldcai/projects/PasswordPie/keepassxc/tests/data/bitwarden_encrypted_export.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "KeePassXC's Bitwarden export is not on this machine")
        let url = directory.appendingPathComponent("bitwarden.json")
        try FileManager.default.copyItem(at: fixture, to: url)
        let session = unlockedSession()
        let flow = try flow(session, on: "bitwarden")
        flow.take(url)
        XCTAssertEqual(flow.stage, .protected(fileName: "bitwarden.json"))
        XCTAssertEqual(flow.error, "", "asking for a password is not an error")

        flow.passwordDraft = "wrong"
        flow.unlockFile()
        XCTAssertEqual(flow.stage, .protected(fileName: "bitwarden.json"))
        XCTAssertEqual(flow.error, "That password does not open this file.")
        XCTAssertEqual(flow.passwordDraft, "", "the typed password is not kept")

        flow.passwordDraft = "a"
        flow.unlockFile()
        guard case .found(_, let count) = flow.stage else { return XCTFail("\(flow.stage) \(flow.error)") }
        XCTAssertGreaterThan(count, 0)
        flow.commit()
        XCTAssertEqual(try outcome(flow).file, .none)
        XCTAssertTrue(session.entries.allSatisfy { $0.groupPath.first == "Bitwarden" })
    }

    // MARK: Choosing in the panel

    func testChooseFileTakesWhatThePanelReturns() throws {
        let session = unlockedSession()
        let flow = try flow(session)
        let url = try export()
        var asked = ""
        flow.pickFile = { message in
            asked = message
            return url
        }
        flow.chooseFile()
        XCTAssertTrue(asked.contains("Chrome Passwords.csv"), asked)
        XCTAssertEqual(flow.stage, .found(fileName: "Chrome Passwords.csv", count: 2))
        flow.pickFile = { _ in nil }
        flow.chooseFile()
        XCTAssertEqual(flow.stage, .found(fileName: "Chrome Passwords.csv", count: 2), "Cancel changes nothing")
    }

    // MARK: Apple Passwords, without a file

    func testWhatApplePasswordsSendsLandsOnItsPage() throws {
        let session = unlockedSession()
        let flow = ImportFlow(session: session)
        flow.receive(.reading)
        XCTAssertEqual(flow.tile?.id, "apple-passwords")
        XCTAssertTrue(flow.reading)

        let report = session.finishCredentialExchange([ExchangedItem(title: "GitHub", urls: ["https://github.com"], username: "ann", password: "pw")])
        flow.receive(report)
        XCTAssertFalse(flow.reading)
        let outcome = try outcome(flow)
        XCTAssertEqual(outcome.summary, BrowserImportSummary(added: 1))
        XCTAssertEqual(outcome.file, .none, "there was no file")
        XCTAssertEqual(session.entries.map(\.groupPath), [["Apple Passwords"]])
    }

    func testAnEmptyHandoverFromApplePasswordsSaysSo() {
        let session = unlockedSession()
        let flow = ImportFlow(session: session)
        flow.receive(session.finishCredentialExchange([]))
        XCTAssertEqual(flow.error, "Apple Passwords sent no passwords. Nothing was changed.")
        XCTAssertEqual(flow.stage, .waiting)
    }

    func testOnTheSafariPageAHandoverStaysThere() throws {
        let session = unlockedSession()
        let flow = try flow(session, on: "safari")
        flow.receive(.reading)
        XCTAssertEqual(flow.tile?.id, "safari")
    }

    // MARK: Words

    func testABrowserCountsPasswordsAndAPasswordManagerCountsItems() {
        XCTAssertEqual(ImportFlow.counted(214, from: .chrome), "214 passwords")
        XCTAssertEqual(ImportFlow.counted(1, from: .chrome), "1 password")
        XCTAssertEqual(ImportFlow.counted(3, from: .onePassword), "3 items")
        XCTAssertEqual(ImportFlow.counted(214, from: .chrome, capitalized: true), "214 Passwords")
    }
}
