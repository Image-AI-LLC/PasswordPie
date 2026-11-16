import AppKit
@testable import PasswordPieCore
import XCTest
@testable import PasswordPie

/// The link rule sits on the session's one copy function, so these go through `copy(_:of:)` as every window does.
@MainActor
final class AppLinkSessionTests: XCTestCase {
    private var directory: URL!
    private let pasteboard = FakePasteboard()
    private let harbor = LinkedApp(bundleID: "example.harbor", teamID: "TEAM123456", name: "Harbor")
    private let ledger = LinkedApp(bundleID: "example.ledger", teamID: nil, name: "Ledger")
    private var front: LinkedApp?
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var notices: [AppLinkNotice] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("applink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
        front = harbor
        notices = []
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        try? FileManager.default.removeItem(at: directory)
    }

    private func session(titles: [String] = ["Northwind SSO"]) -> VaultSession {
        let session = VaultSession(pasteboard: pasteboard, writes: .inline)
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        for title in titles {
            var entry = VaultEntry()
            entry.title = title
            // Not the same sign-in as another title's, or the two would be merged into one account.
            entry.username = "ada+\(title.count)@northwind.example"
            entry.password = "secret"
            entry.otp = "JBSWY3DPEHPK3PXP"
            entry.url = "https://sso.northwind.example"
            session.saveEditing(entry)
        }
        session.copyTargetApp = { [unowned self] in self.front }
        session.appLinkClock = { [unowned self] in self.clock }
        session.onAppLink = { [unowned self] in self.notices.append($0) }
        return session
    }

    private func id(_ session: VaultSession, _ title: String = "Northwind SSO") throws -> UUID {
        try XCTUnwrap(session.entries.first { $0.title == title && !$0.trashed }?.id)
    }

    private func apps(_ session: VaultSession, _ title: String = "Northwind SSO") throws -> [LinkedApp] {
        AppLinks.apps(of: try XCTUnwrap(session.entries.first { $0.title == title && !$0.trashed }))
    }

    func testUsernameAndPasswordOverOneAppLinkTheAccountAndSaveIt() throws {
        let session = session()
        let id = try id(session)
        session.copy(.username, of: id)
        XCTAssertEqual(try apps(session), [])
        XCTAssertEqual(notices, [])
        clock += 30
        session.copy(.password, of: id)
        XCTAssertEqual(try apps(session), [harbor])
        XCTAssertEqual(notices, [.linked(entry: id, title: "Northwind SSO", app: harbor)])
        XCTAssertEqual(notices.first?.message, "Northwind SSO is now shown first in Harbor")
        XCTAssertEqual(notices.first?.action, "Undo")

        let onDisk = try KDBX.load(data: Data(contentsOf: directory.appendingPathComponent("test.kdbx")), password: "pw")
        XCTAssertEqual(onDisk.entries.first { $0.title == "Northwind SSO" }.map(AppLinks.apps), [harbor])
        XCTAssertEqual(session.appEntries(for: harbor).map(\.title), ["Northwind SSO"])
        XCTAssertEqual(session.appEntries(for: ledger), [])
        XCTAssertTrue(session.isLinked(id, to: harbor))
        XCTAssertFalse(session.isLinked(id, to: nil))
    }

    func testALinkedAccountIsNotLinkedOrAnnouncedAgain() throws {
        let session = session()
        let id = try id(session)
        session.copy(.username, of: id)
        session.copy(.password, of: id)
        session.copy(.username, of: id)
        session.copy(.password, of: id)
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(try apps(session), [harbor])
    }

    func testOtherFieldsAndOtherAppsDoNotMakeALink() throws {
        let session = session(titles: ["Northwind SSO", "Other"])
        let id = try id(session)
        session.copy(.username, of: id)
        session.copy(.url, of: id)
        session.copy(.notes, of: id)
        session.copy(.username, of: id)
        XCTAssertEqual(try apps(session), [], "one field, however often")

        front = ledger
        session.copy(.password, of: id)
        XCTAssertEqual(try apps(session), [], "the password went to another app")

        front = harbor
        session.copy(.username, of: id)
        session.copy(.password, of: try self.id(session, "Other"))
        XCTAssertEqual(try apps(session), [])
        XCTAssertEqual(try apps(session, "Other"), [], "two accounts are not a pair")
        XCTAssertEqual(notices, [])
    }

    func testNoAppInFrontThatCanBeLinkedMeansNothingIsLearned() throws {
        let session = session()
        let id = try id(session)
        front = nil
        session.copy(.username, of: id)
        session.copy(.password, of: id)
        XCTAssertEqual(try apps(session), [])
        front = harbor
        session.copy(.password, of: id)
        XCTAssertEqual(try apps(session), [], "the copy over a browser or a PasswordPie window was not the first half")
    }

    func testThePairHasFiveMinutesAndLockingForgetsIt() async throws {
        let session = session()
        let id = try id(session)
        session.copy(.username, of: id)
        clock += 301
        session.copy(.password, of: id)
        XCTAssertEqual(try apps(session), [])

        session.copy(.password, of: id)
        session.lock()
        session.passwordDraft = "pw"
        session.unlock()
        for _ in 0..<4_000 where session.locked { try await Task.sleep(nanoseconds: 5_000_000) }
        clock += 5
        session.copy(.username, of: try self.id(session))
        XCTAssertEqual(try apps(session), [], "the password copied before the lock is not half a pair")
        XCTAssertEqual(notices, [])
    }

    func testAfterAnUndoTheSameCopiesAskAndDoNotLink() throws {
        let session = session()
        let id = try id(session)
        session.copy(.username, of: id)
        session.copy(.password, of: id)
        var undone = false
        session.unlinkApp(harbor, from: id) { undone = $0 }
        XCTAssertTrue(undone)
        XCTAssertEqual(try apps(session), [])
        XCTAssertEqual(session.appEntries(for: harbor), [])

        session.copy(.password, of: id)
        session.copy(.username, of: id)
        XCTAssertEqual(try apps(session), [])
        XCTAssertEqual(notices.last, .offer(entry: id, title: "Northwind SSO", app: harbor))
        XCTAssertEqual(notices.last?.message, "Show Northwind SSO first in Harbor again?")
        XCTAssertEqual(notices.last?.action, "Show first")

        session.linkApp(harbor, to: id)
        XCTAssertEqual(try apps(session), [harbor], "Show first on the bubble links it again")
    }

    func testAnAccountCanHaveTwoAppsAndLosesOnlyTheOneUnlinked() throws {
        let session = session()
        let id = try id(session)
        session.copy(.username, of: id)
        session.copy(.password, of: id)
        front = ledger
        session.copy(.username, of: id)
        session.copy(.password, of: id)
        XCTAssertEqual(try apps(session), [harbor, ledger])
        session.unlinkApp(harbor, from: id)
        XCTAssertEqual(try apps(session), [ledger])
    }
}
