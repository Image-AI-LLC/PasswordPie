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
        for (index, title) in titles.enumerated() {
            var entry = VaultEntry()
            entry.title = title
            // Not the same sign-in as another title's, or the two would be merged into one account.
            entry.username = "ada+\(index)@northwind.example"
            entry.password = "secret"
            entry.otp = "JBSWY3DPEHPK3PXP"
            entry.url = "https://sso.northwind.example"
            session.saveEditing(entry)
        }
        session.copyTargetApp = { [unowned self] in self.front }
        session.onAppLink = { [unowned self] in self.notices.append($0) }
        return session
    }

    private func id(_ session: VaultSession, _ title: String = "Northwind SSO") throws -> UUID {
        try XCTUnwrap(session.entries.first { $0.title == title && !$0.trashed }?.id)
    }

    private func apps(_ session: VaultSession, _ title: String = "Northwind SSO") throws -> [LinkedApp] {
        AppLinks.apps(of: try XCTUnwrap(session.entries.first { $0.title == title && !$0.trashed }))
    }

    func testAPasswordCopiedOverAnAppLinksTheAccountAndSavesIt() throws {
        let session = session()
        let id = try id(session)
        session.copy(.password, of: id)
        XCTAssertEqual(try apps(session), [harbor], "the password alone: the app may already show the username")
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
        session.copy(.password, of: id)
        session.copy(.username, of: id)
        session.copy(.password, of: id)
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(try apps(session), [harbor])
    }

    func testOnlyAPasswordMakesALink() throws {
        let session = session()
        let id = try id(session)
        session.copy(.username, of: id)
        session.copy(.url, of: id)
        session.copy(.notes, of: id)
        session.copy(.username, of: id)
        XCTAssertEqual(try apps(session), [], "a username is not a sign-in, however often it is copied")
        XCTAssertEqual(notices, [])
    }

    func testAnAccountWithNoPasswordIsNotLinked() throws {
        let session = session()
        let id = try id(session)
        var entry = try XCTUnwrap(session.entries.first { $0.id == id })
        entry.password = ""
        session.saveEditing(entry)
        session.copy(.password, of: id)
        XCTAssertEqual(try apps(session), [], "nothing was copied")
        XCTAssertEqual(notices, [])
    }

    func testEachAccountIsLinkedToTheAppItsOwnPasswordWasCopiedOver() throws {
        let session = session(titles: ["Northwind SSO", "Other"])
        session.copy(.password, of: try id(session))
        front = ledger
        session.copy(.password, of: try id(session, "Other"))
        XCTAssertEqual(try apps(session), [harbor])
        XCTAssertEqual(try apps(session, "Other"), [ledger])
        XCTAssertEqual(notices.count, 2)
    }

    func testNoAppInFrontThatCanBeLinkedMeansNoLink() throws {
        let session = session()
        let id = try id(session)
        front = nil
        session.copy(.password, of: id)
        XCTAssertEqual(try apps(session), [], "a browser or a PasswordPie window was in front")
        XCTAssertEqual(notices, [])
        front = harbor
        session.copy(.password, of: id)
        XCTAssertEqual(try apps(session), [harbor])
    }

    func testAfterAnUndoAPasswordCopyStaysCompletelySilentAndManualLinkWorks() throws {
        let session = session()
        let id = try id(session)
        session.copy(.password, of: id)
        var undone = false
        session.unlinkApp(harbor, from: id) { undone = $0 }
        XCTAssertTrue(undone)
        XCTAssertEqual(try apps(session), [])
        XCTAssertEqual(session.appEntries(for: harbor), [])

        session.copy(.username, of: id)
        session.copy(.password, of: id)
        XCTAssertEqual(try apps(session), [], "does not auto-link again after refusal")
        XCTAssertEqual(notices.count, 1, "completely silent — no repeat offer bubble")

        // Manual link still works and clears the refusal.
        session.linkApp(harbor, to: id, manual: true)
        XCTAssertEqual(try apps(session), [harbor])
    }

    func testThreeDistinctAutoUndosStopAutomaticAddingForThatApp() throws {
        let session = session(titles: ["Northwind", "Staging DB", "Admin API", "Billing"])
        let id1 = try id(session, "Northwind")
        let id2 = try id(session, "Staging DB")
        let id3 = try id(session, "Admin API")
        let id4 = try id(session, "Billing")

        // 1st and 2nd auto-add + Undo
        session.copy(.password, of: id1)
        session.unlinkApp(harbor, from: id1)
        session.copy(.password, of: id2)
        session.unlinkApp(harbor, from: id2)
        XCTAssertFalse(session.appLinkAutoExclusions.isExcluded(bundleID: harbor.bundleID))

        // 3rd distinct account undone triggers app-level exclusion and announces .autoStopped
        session.copy(.password, of: id3)
        session.unlinkApp(harbor, from: id3)
        XCTAssertTrue(session.appLinkAutoExclusions.isExcluded(bundleID: harbor.bundleID))
        XCTAssertEqual(notices.last, .autoStopped(app: harbor))
        XCTAssertEqual(notices.last?.message, "Stopped adding Harbor automatically")
        XCTAssertEqual(notices.last?.action, "Turn Back On")

        // 4th account copied over Harbor stays completely silent (not auto-linked, no bubble)
        let noticeCountBefore = notices.count
        session.copy(.password, of: id4)
        XCTAssertEqual(try apps(session, "Billing"), [])
        XCTAssertEqual(notices.count, noticeCountBefore)

        // Manual linking still works even while automatic adding is off for Harbor
        session.linkApp(harbor, to: id4, manual: true)
        XCTAssertEqual(try apps(session, "Billing"), [harbor])

        // Re-enabling automatic adding resets the count and allows future auto-adds
        session.reenableAutoLink(bundleID: harbor.bundleID)
        XCTAssertFalse(session.appLinkAutoExclusions.isExcluded(bundleID: harbor.bundleID))
        XCTAssertEqual(session.appLinkAutoExclusions.undoCount(for: harbor.bundleID), 0)
    }

    func testRemovingManuallyAddedLinksDoesNotCountTowardAppExclusion() throws {
        let session = session(titles: ["One", "Two", "Three"])
        for title in ["One", "Two", "Three"] {
            let entryID = try id(session, title)
            session.linkApp(harbor, to: entryID, manual: true)
            session.unlinkApp(harbor, from: entryID)
        }
        XCTAssertFalse(session.appLinkAutoExclusions.isExcluded(bundleID: harbor.bundleID))
        XCTAssertEqual(session.appLinkAutoExclusions.undoCount(for: harbor.bundleID), 0)
    }

    func testAnAccountCanHaveTwoAppsAndLosesOnlyTheOneUnlinked() throws {
        let session = session()
        let id = try id(session)
        session.copy(.password, of: id)
        front = ledger
        session.copy(.password, of: id)
        XCTAssertEqual(try apps(session), [harbor, ledger])
        session.unlinkApp(harbor, from: id)
        XCTAssertEqual(try apps(session), [ledger])
    }
}
