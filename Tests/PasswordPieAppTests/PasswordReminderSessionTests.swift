import AppKit
@testable import PasswordPieCore
import XCTest
@testable import PasswordPie

@MainActor
final class PasswordReminderSessionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("reminder-\(UUID().uuidString)", isDirectory: true)
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

    /// Saving records when the password was set, in the file; a new password records it again.
    func testSavingStartsTheClockAndANewPasswordRestartsIt() throws {
        let session = unlockedSession()
        var entry = VaultEntry()
        entry.title = "Payroll"
        entry.username = "ada"
        entry.password = "first"
        PasswordRotation.setPeriod(30, on: &entry)
        session.saveEditing(entry)

        let saved = try XCTUnwrap(session.entries.first { $0.title == "Payroll" })
        let first = try XCTUnwrap(PasswordRotation.changed(of: saved))
        XCTAssertLessThan(abs(first.timeIntervalSinceNow), 5)
        XCTAssertFalse(PasswordRotation.isDue(saved, now: Date()))
        XCTAssertTrue(PasswordRotation.isDue(saved, now: Date().addingTimeInterval(31 * 86_400)))

        // An old date, as if a month had gone by: the same password keeps it across a save that changes something else.
        session.edit(saved.id)
        var aged = try XCTUnwrap(session.editing)
        let old = Int(Date().addingTimeInterval(-40 * 86_400).timeIntervalSince1970)
        let digest = aged.value(for: PasswordRotation.changedKey).split(separator: " ")[1]
        aged.setValue("\(old) \(digest)", for: PasswordRotation.changedKey)
        aged.notes = "note"
        session.saveEditing(aged)
        let overdue = try XCTUnwrap(session.entries.first { $0.title == "Payroll" })
        XCTAssertTrue(PasswordRotation.isDue(overdue, now: Date()))
        XCTAssertEqual(MenuBuilder.topLevel(entries: session.entries).first?.title, "Passwords to Change")

        session.edit(overdue.id)
        var changed = try XCTUnwrap(session.editing)
        changed.password = "second"
        session.saveEditing(changed)
        let fresh = try XCTUnwrap(session.entries.first { $0.title == "Payroll" })
        XCTAssertFalse(PasswordRotation.isDue(fresh, now: Date()))
        XCTAssertNotEqual(MenuBuilder.topLevel(entries: session.entries).first?.title, "Passwords to Change")

        let onDisk = try KDBX.load(data: Data(contentsOf: directory.appendingPathComponent("test.kdbx")), password: "pw")
        XCTAssertNotNil(onDisk.entries.first { $0.title == "Payroll" }.flatMap(PasswordRotation.changed))
    }

    /// Another app changed the password while PasswordPie was locked: opening the file dates the new one.
    func testOpeningAFileWhoseReminderLostItsDateDatesItAgain() async throws {
        let session = unlockedSession()
        var entry = VaultEntry()
        entry.title = "Payroll"
        entry.username = "ada"
        entry.password = "first"
        PasswordRotation.setPeriod(30, on: &entry)
        session.saveEditing(entry)
        session.lock()

        let url = directory.appendingPathComponent("test.kdbx")
        var vault = try KDBX.load(data: Data(contentsOf: url), password: "pw")
        vault.entries[0].password = "changed elsewhere"
        XCTAssertNil(PasswordRotation.changed(of: vault.entries[0]))
        try KDBX.save(vault: &vault, password: "pw").write(to: url)

        session.passwordDraft = "pw"
        session.unlock()
        for _ in 0..<500 where session.unlocking {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let reopened = try XCTUnwrap(session.entries.first { $0.title == "Payroll" })
        XCTAssertNotNil(PasswordRotation.changed(of: reopened))
        let onDisk = try KDBX.load(data: Data(contentsOf: url), password: "pw")
        XCTAssertNotNil(onDisk.entries.first.flatMap(PasswordRotation.changed))
    }

    /// An account that becomes due while the app stays open shows up when the panel opens.
    func testAnAccountThatBecomesDueWhileOpenAppearsInTheMenu() throws {
        let session = unlockedSession()
        var entry = VaultEntry()
        entry.title = "Payroll"
        entry.username = "ada"
        entry.password = "first"
        PasswordRotation.setPeriod(30, on: &entry)
        session.saveEditing(entry)
        XCTAssertNotEqual(session.topLevelRows?.first?.title, "Passwords to Change")

        session.chromeClock = { Date().addingTimeInterval(31 * 86_400) }
        session.refreshDueReminders()

        XCTAssertEqual(session.topLevelRows?.first?.title, "Passwords to Change")
    }
}
