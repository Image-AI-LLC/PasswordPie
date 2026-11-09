import XCTest
@testable import PasswordPieCore

final class PreviousPasswordsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func login(_ password: String = "current") -> VaultEntry {
        var entry = VaultEntry()
        entry.title = "github.com"
        entry.url = "https://github.com"
        entry.username = "ann"
        entry.password = password
        return entry
    }

    private func item(_ value: String, used: Bool, entered: TimeInterval = 0, source: PreviousPasswords.Source = .chrome) -> PreviousPasswords.Item {
        PreviousPasswords.Item(value: value, source: source, date: now.addingTimeInterval(-entered), enteredAt: now.addingTimeInterval(-entered), used: used)
    }

    func testTheFieldIsReservedProtectedAndNeverShownAsAnExtraField() {
        var entry = login()
        var state = PreviousPasswords.State()
        state.items = [item("old", used: true)]
        PreviousPasswords.set(state, on: &entry)
        XCTAssertTrue(EntryMerge.isReservedKey(PreviousPasswords.key))
        XCTAssertEqual(entry.fields.first { $0.key == PreviousPasswords.key }?.protected, true)
        XCTAssertFalse(EntryMerge.extraFields(entry).contains { $0.key == PreviousPasswords.key })
    }

    func testAnEmptyStateLeavesNoField() {
        var entry = login()
        PreviousPasswords.set(PreviousPasswords.State(), on: &entry)
        XCTAssertFalse(entry.fields.contains { $0.key == PreviousPasswords.key })
    }

    func testARecordThisVersionCannotReadIsNotReadableAndStaysUntouched() {
        var entry = login()
        entry.setValue("{\"v\":99}", for: PreviousPasswords.key, protected: true)
        XCTAssertFalse(PreviousPasswords.isReadable(entry))
        var plain = login()
        XCTAssertTrue(PreviousPasswords.isReadable(plain))
        plain.setValue("not json", for: PreviousPasswords.key, protected: true)
        XCTAssertFalse(PreviousPasswords.isReadable(plain))
    }

    // MARK: Limits and eviction

    func testValuesAreKeptForNinetyDaysFromEnteringTheList() {
        var state = PreviousPasswords.State()
        state.items = [
            item("recent-replaced", used: true, entered: 2 * day),
            item("just-inside", used: false, entered: 89 * day),
            item("expired", used: false, entered: 90 * day),
            item("expired-used", used: true, entered: 91 * day)
        ]
        let trimmed = PreviousPasswords.trimmed(state, now: now)
        XCTAssertEqual(trimmed.items.map(\.value), ["recent-replaced", "just-inside"])
    }

    func testTheMostRecentlyReplacedValueOutlivesNinetyDays() {
        var state = PreviousPasswords.State()
        state.items = [item("only-replaced", used: true, entered: 200 * day), item("chrome-side", used: false, entered: 300 * day)]
        XCTAssertEqual(PreviousPasswords.trimmed(state, now: now).items.map(\.value), ["only-replaced"])
    }

    func testOverTenNeverAdoptedChromeValuesGoFirstOldestFirst() {
        var state = PreviousPasswords.State()
        state.items = (0..<6).map { item("used-\($0)", used: true, entered: Double($0 + 1) * day) }
            + (0..<7).map { item("chrome-\($0)", used: false, entered: Double($0 + 1) * day) }
        let kept = Set(PreviousPasswords.trimmed(state, now: now).items.map(\.value))
        XCTAssertEqual(kept.count, 10)
        XCTAssertTrue(kept.isSuperset(of: (0..<6).map { "used-\($0)" }), "values that were really saved stay longest")
        XCTAssertFalse(kept.contains("chrome-6"), "the oldest never-adopted value leaves first")
        XCTAssertFalse(kept.contains("chrome-5"))
        XCTAssertFalse(kept.contains("chrome-4"))
        XCTAssertTrue(kept.contains("chrome-0"))
    }

    func testOverTenSavedValuesDropTheOldestButNeverTheMostRecentlyReplaced() {
        var state = PreviousPasswords.State()
        // Item 0 entered the list last.
        state.items = (0..<12).map { item("used-\($0)", used: true, entered: Double($0 + 1) * day) }
        let kept = PreviousPasswords.trimmed(state, now: now).items.map(\.value)
        XCTAssertEqual(kept.count, 10)
        XCTAssertTrue(kept.contains("used-0"))
        XCTAssertFalse(kept.contains("used-11"))
    }

    func testValuesAreDistinctAndNewestFirst() {
        var state = PreviousPasswords.State()
        state.items = [item("a", used: false, entered: 5 * day), item("b", used: true, entered: 1 * day), item("a", used: true, entered: 2 * day)]
        let trimmed = PreviousPasswords.trimmed(state, now: now).items
        XCTAssertEqual(trimmed.map(\.value), ["b", "a"])
        XCTAssertEqual(trimmed.last?.used, true, "the value that was once saved keeps that fact")
    }

    func testTheCapDoesNotDependOnHistoryMaxItems() {
        XCTAssertEqual(PreviousPasswords.maxItems, 10)
    }

    // MARK: Moving values

    func testAManualChangeMovesTheOldValueWithItsDateAndHasNoChromeLabel() {
        var entry = login("old")
        var after = entry
        after.password = "new"
        let earlier = now.addingTimeInterval(-40 * day)
        PreviousPasswords.recordChange(from: entry.password, on: &after, previousDate: earlier, now: now)
        entry = after
        XCTAssertEqual(PreviousPasswords.items(of: entry, now: now).map(\.value), ["old"])
        XCTAssertEqual(PreviousPasswords.items(of: entry, now: now).first?.date, earlier)
        XCTAssertEqual(PreviousPasswords.items(of: entry, now: now).first?.used, true)
        XCTAssertEqual(PreviousPasswords.passwordDate(of: entry, fallback: nil), now)
        XCTAssertNil(PreviousPasswords.chromeUpdateDate(of: entry, now: now))
    }

    func testRestoreSwapsTheValuesAndChangesOnlyThePassword() throws {
        var entry = login("current")
        entry.notes = "keep me"
        var state = PreviousPasswords.State()
        state.items = [item("older", used: true, entered: day)]
        PreviousPasswords.set(state, on: &entry)
        let id = try XCTUnwrap(state.items.first?.id)

        XCTAssertTrue(PreviousPasswords.restore(id, on: &entry, previousDate: now.addingTimeInterval(-day), now: now))

        XCTAssertEqual(entry.password, "older")
        XCTAssertEqual(entry.notes, "keep me")
        XCTAssertEqual(PreviousPasswords.items(of: entry, now: now).map(\.value), ["current"])
        XCTAssertEqual(PreviousPasswords.passwordDate(of: entry, fallback: nil), now, "Restore is the newest change")
    }

    func testRestoreOfAnUnknownRowChangesNothing() {
        var entry = login("current")
        let before = entry
        XCTAssertFalse(PreviousPasswords.restore(UUID(), on: &entry, previousDate: nil, now: now))
        XCTAssertEqual(entry, before)
    }

    func testClearEmptiesTheListButRemembersWhatItDecided() {
        var entry = login()
        var state = PreviousPasswords.State()
        state.items = [item("old", used: true)]
        state.events = [PreviousPasswords.Event(id: "e1", at: now, kind: .kept)]
        PreviousPasswords.set(state, on: &entry)
        PreviousPasswords.clear(on: &entry)
        XCTAssertTrue(PreviousPasswords.items(of: entry, now: now).isEmpty)
        XCTAssertEqual(PreviousPasswords.state(of: entry).events.map(\.id), ["e1"], "a cleared Chrome value must not come back on the next read")
    }

    func testTheChromeUpdateLabelLastsSevenDaysAndFollowsTheValue() {
        var entry = login("from-chrome")
        var state = PreviousPasswords.State()
        state.current = PreviousPasswords.Current(value: "from-chrome", date: now.addingTimeInterval(-2 * day), source: .chrome, event: "e")
        PreviousPasswords.set(state, on: &entry)
        XCTAssertEqual(PreviousPasswords.chromeUpdateDate(of: entry, now: now), now.addingTimeInterval(-2 * day))
        XCTAssertNil(PreviousPasswords.chromeUpdateDate(of: entry, now: now.addingTimeInterval(6 * day)))
        entry.password = "edited-elsewhere"
        XCTAssertNil(PreviousPasswords.chromeUpdateDate(of: entry, now: now), "a record is bound to its value")
    }

    func testPasswordDateUsesTheRecordOnlyWhileItMatchesTheValue() {
        var entry = login("value")
        var state = PreviousPasswords.State()
        state.current = PreviousPasswords.Current(value: "value", date: now, source: .saved, event: nil)
        PreviousPasswords.set(state, on: &entry)
        let fallback = now.addingTimeInterval(-day)
        XCTAssertEqual(PreviousPasswords.passwordDate(of: entry, fallback: fallback), now)
        entry.password = "changed in KeePassXC"
        XCTAssertEqual(PreviousPasswords.passwordDate(of: entry, fallback: fallback), fallback)
    }
}
