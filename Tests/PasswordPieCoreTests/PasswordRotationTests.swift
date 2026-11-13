@testable import PasswordPieCore
import XCTest

final class PasswordRotationTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func account(period: Int? = 30) -> VaultEntry {
        var entry = VaultEntry()
        entry.title = "Payroll"
        entry.username = "ada"
        entry.password = "first"
        entry.url = "https://example.com"
        PasswordRotation.setPeriod(period, on: &entry)
        return entry
    }

    func testNoReminderIsNeverDue() {
        var entry = account(period: nil)
        XCTAssertFalse(PasswordRotation.reconcile(&entry, now: start))
        XCTAssertNil(PasswordRotation.dueDate(of: entry))
        XCTAssertFalse(PasswordRotation.isDue(entry, now: start.addingTimeInterval(1000 * day)))
    }

    func testDueAfterThePeriodFromTheDayItWasSet() {
        var entry = account()
        XCTAssertTrue(PasswordRotation.reconcile(&entry, now: start))
        XCTAssertFalse(PasswordRotation.reconcile(&entry, now: start.addingTimeInterval(day)), "a second pass keeps the date")
        XCTAssertFalse(PasswordRotation.isDue(entry, now: start.addingTimeInterval(29 * day)))
        XCTAssertTrue(PasswordRotation.isDue(entry, now: start.addingTimeInterval(30 * day)))
    }

    func testAKnownPasswordDateIsWhereTheClockStarts() {
        var entry = account()
        PasswordRotation.reconcile(&entry, known: start.addingTimeInterval(-25 * day), now: start)
        XCTAssertTrue(PasswordRotation.isDue(entry, now: start.addingTimeInterval(5 * day)))
        var future = account()
        PasswordRotation.reconcile(&future, known: start.addingTimeInterval(400 * day), now: start)
        XCTAssertEqual(PasswordRotation.changed(of: future), start)
    }

    func testAnImpossibleKnownDateIsNotBelieved() {
        for seconds in [-1e300, -9.3e18, -1, 0, 1e300] {
            var entry = account()
            PasswordRotation.reconcile(&entry, known: Date(timeIntervalSince1970: seconds), now: start)
            XCTAssertEqual(PasswordRotation.changed(of: entry), start)
        }
    }

    func testAnyChangeOfThePasswordStartsTheClockAgain() {
        var entry = account()
        PasswordRotation.reconcile(&entry, now: start)
        let later = start.addingTimeInterval(40 * day)
        XCTAssertTrue(PasswordRotation.isDue(entry, now: later))
        entry.password = "second"
        XCTAssertNil(PasswordRotation.changed(of: entry), "the old date does not apply to a new password")
        XCTAssertFalse(PasswordRotation.isDue(entry, now: later))
        XCTAssertTrue(PasswordRotation.reconcile(&entry, now: later))
        XCTAssertEqual(PasswordRotation.dueDate(of: entry), later.addingTimeInterval(30 * day))
    }

    func testTurningTheReminderOffForgetsTheDate() {
        var entry = account()
        PasswordRotation.reconcile(&entry, now: start)
        PasswordRotation.setPeriod(nil, on: &entry)
        XCTAssertTrue(PasswordRotation.reconcile(&entry, now: start))
        XCTAssertFalse(entry.fields.contains { PasswordRotation.isKey($0.key) })
    }

    func testDueListIsLongestOverdueFirstAndSkipsTheTrash() {
        var old = account(); old.title = "Old"
        PasswordRotation.reconcile(&old, now: start.addingTimeInterval(-60 * day))
        var recent = account(); recent.title = "Recent"
        PasswordRotation.reconcile(&recent, now: start.addingTimeInterval(-31 * day))
        var fresh = account(); fresh.title = "Fresh"
        PasswordRotation.reconcile(&fresh, now: start)
        var trashed = old; trashed.id = UUID(); trashed.trashed = true
        XCTAssertEqual(PasswordRotation.due(in: [recent, fresh, trashed, old], now: start).map(\.title), ["Old", "Recent"])
    }

    func testPhraseAndResetAddress() {
        XCTAssertEqual([12, 1, 0, -1, -3].map(PasswordRotation.phrase), ["in 12 days", "in 1 day", "today", "1 day ago", "3 days ago"])
        var entry = account()
        XCTAssertEqual(PasswordRotation.resetAddress(of: entry), "https://example.com")
        PasswordRotation.setResetLink(" https://example.com/reset ", on: &entry)
        XCTAssertEqual(PasswordRotation.resetAddress(of: entry), "https://example.com/reset")
        PasswordRotation.reconcile(&entry, now: start)
        XCTAssertEqual(PasswordRotation.daysLeft(of: entry, now: start.addingTimeInterval(28 * day)), 2)
    }

    func testReminderFieldsAreNotListedAsFieldsOrSearched() {
        var entry = account()
        PasswordRotation.setResetLink("https://example.com/reset", on: &entry)
        PasswordRotation.reconcile(&entry, now: start)
        XCTAssertEqual(EntryFields.custom(of: entry), [])
        XCTAssertTrue(EntryMerge.extraFields(entry).isEmpty)
    }

    func testMenuLeadsWithPasswordsToChange() {
        var due = account()
        PasswordRotation.reconcile(&due, now: start.addingTimeInterval(-31 * day))
        var fine = account(); fine.title = "Fine"
        PasswordRotation.reconcile(&fine, now: start)
        let rows = MenuBuilder.topLevel(entries: [fine, due], now: start)
        XCTAssertEqual(rows.first?.title, "Passwords to Change")
        XCTAssertEqual(rows.first?.count, 1)
        XCTAssertEqual(rows.first?.children.map(\.title), ["Payroll"])
        XCTAssertEqual(rows.first?.children.first?.due, true)
        XCTAssertNotEqual(MenuBuilder.topLevel(entries: [fine], now: start).first?.title, "Passwords to Change")
    }

    func testAFullerTwinKeepsTheReminderOfTheAccountItAbsorbs() throws {
        var reminded = account(period: 30)
        reminded.id = UUID()
        PasswordRotation.setResetLink("https://example.com/reset", on: &reminded)
        PasswordRotation.reconcile(&reminded, now: start)
        var fuller = account(period: nil)
        fuller.id = UUID()
        fuller.notes = "backup codes"

        let merged = EntryMerge.merged([reminded, fuller])

        let survivor = try XCTUnwrap(merged.first { !$0.trashed })
        XCTAssertEqual(survivor.id, fuller.id)
        XCTAssertEqual(PasswordRotation.period(of: survivor), 30)
        XCTAssertEqual(PasswordRotation.resetLink(of: survivor), "https://example.com/reset")
        XCTAssertEqual(PasswordRotation.changed(of: survivor), Date(timeIntervalSince1970: TimeInterval(Int(start.timeIntervalSince1970))))
    }
}
