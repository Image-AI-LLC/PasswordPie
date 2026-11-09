#if PP_DIRECT
import XCTest
@testable import PasswordPieCore

/// The rules in "The newest password wins" (docs/UX.md).
final class ChromeUpdatesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400
    private let site = "https://github.com"

    private func entry(_ password: String, user: String = "ann", url: String? = nil, id: UUID = UUID()) -> VaultEntry {
        var entry = VaultEntry(id: id)
        entry.title = "github.com"
        entry.url = url ?? site
        entry.username = user
        entry.password = password
        return entry
    }

    private func rows(for login: VaultEntry, _ values: [(String, Date?)], form: Bool = true) -> [ChromeRow] {
        values.map { ChromeRow(loginID: login.id, password: $0.0, modifiedAt: $0.1, isForm: form) }
    }

    private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * day) }

    private func plan(_ saved: [VaultEntry], _ live: [VaultEntry], _ rows: [ChromeRow], savedDate: Date? = nil, rules: ChromeJoinRules = ChromeJoinRules()) -> ChromeUpdates.Plan {
        var dates: [UUID: Date] = [:]
        if let savedDate { for entry in saved { dates[entry.id] = savedDate } }
        return ChromeUpdates.plan(saved: saved, live: live, rows: rows, dates: dates, rules: rules, now: now)
    }

    // MARK: Which password is newest

    func testAChromeDateLaterThanTheSavedOneReplacesIt() throws {
        let saved = entry("mine"), live = entry("chrome")
        let result = plan([saved], [live], rows(for: live, [("chrome", ago(1))]), savedDate: ago(3))
        let replacement = try XCTUnwrap(result.updates.first?.replacement)
        XCTAssertEqual(replacement.value, "chrome")
        XCTAssertEqual(replacement.date, ago(1))
    }

    func testAnOlderChromeDateKeepsTheSavedPasswordAndListsChromesValue() throws {
        let saved = entry("mine"), live = entry("chrome")
        let result = plan([saved], [live], rows(for: live, [("chrome", ago(9))]), savedDate: ago(3))
        XCTAssertTrue(result.updates.isEmpty)
        XCTAssertEqual(try XCTUnwrap(result.changes.first).kept.map(\.value), ["chrome"])
        XCTAssertEqual(result.changes.first?.kept.first?.date, ago(9))
    }

    func testATieStaysWithTheDatabase() {
        let saved = entry("mine"), live = entry("chrome")
        XCTAssertTrue(plan([saved], [live], rows(for: live, [("chrome", ago(1))]), savedDate: ago(1)).updates.isEmpty)
    }

    func testTheSameSecondIsATie() {
        let saved = entry("mine"), live = entry("chrome")
        let date = Date(timeIntervalSince1970: ago(1).timeIntervalSince1970.rounded(.down))
        XCTAssertTrue(plan([saved], [live], rows(for: live, [("chrome", date.addingTimeInterval(0.6))]), savedDate: date).updates.isEmpty)
    }

    func testNoZeroOrFutureChromeDateNeverReplacesAndListsAsDateUnknown() {
        for date: Date? in [nil, Date(timeIntervalSince1970: 0), now.addingTimeInterval(60)] {
            let saved = entry("mine"), live = entry("chrome")
            let result = plan([saved], [live], rows(for: live, [("chrome", date)]), savedDate: ago(3))
            XCTAssertTrue(result.updates.isEmpty, "\(String(describing: date))")
            XCTAssertEqual(result.changes.first?.kept.map(\.value), ["chrome"])
            XCTAssertNil(result.changes.first?.kept.first?.date, "shown as date unknown")
        }
    }

    func testNoSavedDateNeverReplaces() {
        let saved = entry("mine"), live = entry("chrome")
        let result = plan([saved], [live], rows(for: live, [("chrome", ago(1))]), savedDate: nil)
        XCTAssertTrue(result.updates.isEmpty)
        XCTAssertEqual(result.changes.first?.kept.map(\.value), ["chrome"])
    }

    func testTheLatestOfSeveralQualifyingRowsWinsAndTheOthersAreListed() throws {
        let saved = entry("mine")
        let work = entry("work-value"), home = entry("home-value")
        let result = plan([saved], [work, home], rows(for: work, [("work-value", ago(2))]) + rows(for: home, [("home-value", ago(1))]), savedDate: ago(5))
        let change = try XCTUnwrap(result.updates.first)
        XCTAssertEqual(change.replacement?.value, "home-value")
        XCTAssertEqual(change.kept.map(\.value), ["work-value"])
    }

    func testTwoStoresOfOneLoginAreComparedRowByRow() throws {
        let saved = entry("mine"), live = entry("older-store")
        let result = plan([saved], [live], rows(for: live, [("older-store", ago(4)), ("newer-store", ago(1))]), savedDate: ago(2))
        XCTAssertEqual(result.updates.first?.replacement?.value, "newer-store")
        XCTAssertEqual(result.updates.first?.kept.map(\.value), ["older-store"])
    }

    func testTheSameValueInTwoRowsIsOneUpdateAndNotAlsoListed() throws {
        let saved = entry("mine"), work = entry("same"), home = entry("same")
        let result = plan([saved], [work, home], rows(for: work, [("same", ago(2))]) + rows(for: home, [("same", ago(1))]), savedDate: ago(5))
        XCTAssertEqual(result.updates.count, 1)
        XCTAssertEqual(result.updates.first?.kept, [])
        XCTAssertEqual(result.updates.first?.settled.count, 1)
    }

    func testAValueEqualToTheSavedPasswordIsNothing() {
        let saved = entry("same"), live = entry("same")
        XCTAssertTrue(plan([saved], [live], rows(for: live, [("same", ago(1))]), savedDate: ago(3)).isEmpty)
    }

    private func applied(_ change: ChromeUpdates.Change, to entry: VaultEntry, kind: PreviousPasswords.EventKind = .automatic, at: Date? = nil) -> VaultEntry {
        var copy = entry
        ChromeUpdates.apply(change, to: &copy, kind: kind, now: at ?? now)
        return copy
    }

    func testAThenBThenAEachWinAsANewEvent() throws {
        var saved = entry("A"), live = entry("B")
        live.id = saved.id
        saved = applied(try XCTUnwrap(plan([saved], [live], rows(for: live, [("B", ago(3))]), savedDate: ago(9)).updates.first), to: saved)
        XCTAssertEqual(saved.password, "B")
        XCTAssertEqual(PreviousPasswords.items(of: saved, now: now).map(\.value), ["A"])

        live.password = "A"
        saved = applied(try XCTUnwrap(plan([saved], [live], rows(for: live, [("A", ago(1))])).updates.first), to: saved)
        XCTAssertEqual(saved.password, "A")
        XCTAssertEqual(PreviousPasswords.items(of: saved, now: now).map(\.value), ["B"], "a value appears once, and never alongside the saved one")
    }

    func testAnAppliedUpdateRecordsItsDateSourceAndTheOldPassword() throws {
        let saved = entry("mine"), live = entry("chrome")
        let updated = applied(try XCTUnwrap(plan([saved], [live], rows(for: live, [("chrome", ago(1))]), savedDate: ago(40)).updates.first), to: saved)
        XCTAssertEqual(updated.password, "chrome")
        XCTAssertEqual(PreviousPasswords.chromeUpdateDate(of: updated, now: now), ago(1))
        let old = try XCTUnwrap(PreviousPasswords.items(of: updated, now: now).first)
        XCTAssertEqual(old.value, "mine")
        XCTAssertEqual(old.source, .saved)
        XCTAssertEqual(old.date, ago(40))
        XCTAssertTrue(old.used)
    }

    func testAKeptValueIsNeverUsedAndRemembered() throws {
        let saved = entry("mine"), live = entry("chrome")
        let source = rows(for: live, [("chrome", nil)])
        let updated = applied(try XCTUnwrap(plan([saved], [live], source, savedDate: ago(40)).changes.first), to: saved)
        XCTAssertEqual(updated.password, "mine")
        let item = try XCTUnwrap(PreviousPasswords.items(of: updated, now: now).first)
        XCTAssertEqual(item.source, .chrome)
        XCTAssertNil(item.date)
        XCTAssertFalse(item.used)
        XCTAssertTrue(plan([updated], [live], source, savedDate: ago(40)).isEmpty, "the same event is not looked at twice")
    }

    func testAKeptValueStaysClearedAfterClear() throws {
        let saved = entry("mine"), live = entry("chrome")
        let source = rows(for: live, [("chrome", nil)])
        var updated = applied(try XCTUnwrap(plan([saved], [live], source, savedDate: ago(40)).changes.first), to: saved)
        PreviousPasswords.clear(on: &updated)
        XCTAssertTrue(plan([updated], [live], source, savedDate: ago(40)).isEmpty)
    }

    // MARK: Undoing

    func testAnUndoneChromeEventCannotComeBackButALaterChangeWins() throws {
        let saved = entry("mine"), live = entry("chrome")
        let firstRows = rows(for: live, [("chrome", ago(1))])
        var updated = applied(try XCTUnwrap(plan([saved], [live], firstRows, savedDate: ago(40)).updates.first), to: saved)
        let oldID = try XCTUnwrap(PreviousPasswords.items(of: updated, now: now).first?.id)
        XCTAssertTrue(PreviousPasswords.restore(oldID, on: &updated, previousDate: nil, now: now))
        XCTAssertEqual(updated.password, "mine")

        // Even with the restore's record lost, the event is known.
        var withoutRecord = updated
        var state = PreviousPasswords.state(of: withoutRecord)
        state.current = nil
        PreviousPasswords.set(state, on: &withoutRecord)
        XCTAssertTrue(plan([updated], [live], firstRows).isEmpty)
        XCTAssertTrue(plan([withoutRecord], [live], firstRows, savedDate: ago(40)).isEmpty)

        let later = now.addingTimeInterval(120)
        let second = rows(for: live, [("chrome-again", later)])
        let again = ChromeUpdates.plan(saved: [updated], live: [live], rows: second, dates: [:], now: later.addingTimeInterval(1))
        XCTAssertEqual(again.updates.first?.replacement?.value, "chrome-again")
    }

    func testTheSameValueAtALaterTimeIsANewEventAfterAnUndo() throws {
        let saved = entry("mine"), live = entry("chrome")
        var updated = applied(try XCTUnwrap(plan([saved], [live], rows(for: live, [("chrome", ago(1))]), savedDate: ago(40)).updates.first), to: saved)
        let oldID = try XCTUnwrap(PreviousPasswords.items(of: updated, now: now).first?.id)
        PreviousPasswords.restore(oldID, on: &updated, previousDate: nil, now: now)
        let later = now.addingTimeInterval(300)
        let again = ChromeUpdates.plan(saved: [updated], live: [live], rows: rows(for: live, [("chrome", later)]), dates: [:], now: later.addingTimeInterval(1))
        XCTAssertEqual(again.updates.first?.replacement?.value, "chrome", "tracked by event, not by value")
    }

    // MARK: The same account, for writing

    private func replaces(saved: VaultEntry, also: [VaultEntry] = [], live: VaultEntry, form: Bool = true, rules: ChromeJoinRules = ChromeJoinRules()) -> Bool {
        let all = [saved] + also
        var dates: [UUID: Date] = [:]
        for entry in all { dates[entry.id] = ago(30) }
        return !ChromeUpdates.plan(saved: all, live: [live], rows: rows(for: live, [(live.password, ago(1))], form: form), dates: dates, rules: rules, now: now).updates.isEmpty
    }

    func testTheSameAccountReplaces() {
        XCTAssertTrue(replaces(saved: entry("mine"), live: entry("chrome", url: "https://github.com/login")))
    }

    func testAUsernameInAnotherCaseIsAnotherAccountAndStaysASeparateRow() {
        let saved = entry("mine"), live = entry("chrome", user: "ANN")
        XCTAssertFalse(replaces(saved: saved, live: live))
        XCTAssertEqual(ChromeLogins.combined(saved: [saved], live: [live]).count, 2)
    }

    func testAnEmptyUsernameNeverWrites() {
        XCTAssertFalse(replaces(saved: entry("mine", user: ""), live: entry("chrome", user: "")))
    }

    func testSchemeHostAndPortMustMatch() {
        for url in ["http://github.com", "https://www.github.com", "https://gist.github.com", "https://github.com:8443"] {
            let saved = entry("mine"), live = entry("chrome", url: url)
            XCTAssertFalse(replaces(saved: saved, live: live), url)
        }
        XCTAssertTrue(replaces(saved: entry("mine", url: "https://github.com:443"), live: entry("chrome")))
    }

    func testTwoLiveSavedEntriesForTheAccountWriteNeither() {
        let first = entry("mine"), second = entry("other"), live = entry("chrome")
        XCTAssertFalse(replaces(saved: first, also: [second], live: live))
        XCTAssertEqual(ChromeLogins.combined(saved: [first, second], live: [live]).count, 3, "ambiguous, so it stays its own row")
    }

    func testATrashedCopyDoesNotMakeItAmbiguous() {
        var trashed = entry("old")
        trashed.trashed = true
        XCTAssertTrue(replaces(saved: entry("mine"), also: [trashed], live: entry("chrome")))
    }

    func testKeepSeparateEntriesNeverJoinADifferentPassword() {
        var saved = entry("mine")
        EntryMerge.setKeepSeparate(true, on: &saved)
        let live = entry("chrome")
        XCTAssertFalse(replaces(saved: saved, live: live))
        XCTAssertEqual(ChromeLogins.combined(saved: [saved], live: [live]).count, 2)
    }

    func testOnlyAnOrdinaryFormLoginWrites() {
        let saved = entry("mine"), live = entry("chrome")
        XCTAssertFalse(replaces(saved: saved, live: live, form: false, rules: ChromeJoinRules(notForms: [live.id])))
    }

    func testAnEntryInAFileThatCannotBeWrittenIsLeftAlone() {
        let saved = entry("mine"), live = entry("chrome")
        XCTAssertFalse(replaces(saved: saved, live: live, rules: ChromeJoinRules(readOnly: [saved.id])))
        XCTAssertEqual(ChromeLogins.combined(saved: [saved], live: [live], rules: ChromeJoinRules(readOnly: [saved.id])).count, 2)
    }

    func testAnEntryServingSeveralSitesKeepsItsPasswordAndListsChromes() throws {
        var saved = entry("mine")
        saved.setValue("https://gitlab.com", for: "URL (2)")
        let live = entry("chrome", url: "https://gitlab.com")
        XCTAssertEqual(ChromeLogins.combined(saved: [saved], live: [live]).count, 1)
        let result = plan([saved], [live], rows(for: live, [("chrome", ago(1))]), savedDate: ago(30))
        XCTAssertTrue(result.updates.isEmpty)
        XCTAssertEqual(result.changes.first?.kept.map(\.value), ["chrome"])
    }

    func testALoginSavedFromChromeAndRenamedHereKeepsItsRowAndNeverWrites() {
        let id = UUID()
        let saved = entry("mine", user: "ann-renamed", id: id)
        let live = entry("chrome", user: "ann", id: id)
        XCTAssertEqual(ChromeLogins.combined(saved: [saved], live: [live]).count, 1)
        let result = plan([saved], [live], rows(for: live, [("chrome", ago(1))]), savedDate: ago(30))
        XCTAssertTrue(result.updates.isEmpty)
        XCTAssertEqual(result.changes.first?.kept.map(\.value), ["chrome"])
    }

    func testAnEntryWithAnUnreadableRecordIsLeftAlone() {
        var saved = entry("mine")
        saved.setValue("{\"v\":99}", for: PreviousPasswords.key, protected: true)
        let live = entry("chrome")
        XCTAssertTrue(plan([saved], [live], rows(for: live, [("chrome", ago(1))]), savedDate: ago(30)).isEmpty)
    }

    func testAChromeDifferenceNeverAddsADisplayField() {
        let saved = entry("mine"), live = entry("chrome")
        let shown = ChromeLogins.combined(saved: [saved], live: [live])
        XCTAssertEqual(shown, [saved])
        XCTAssertFalse(shown[0].fields.contains { $0.value == "chrome" })
    }

    func testTheViewNamesEveryRowWithChromeInIt() {
        let saved = entry("mine"), mine = entry("same", user: "bob", url: "https://b.example")
        let live = entry("chrome"), other = entry("x", user: "c", url: "https://c.example")
        let view = ChromeLogins.view(saved: [saved, mine], live: [live, other])
        XCTAssertEqual(view.fromChrome, [saved.id, other.id])
    }

    // MARK: Many at once

    private func accounts(_ count: Int) -> (saved: [VaultEntry], live: [VaultEntry], rows: [ChromeRow]) {
        var saved: [VaultEntry] = []
        var live: [VaultEntry] = []
        var rowList: [ChromeRow] = []
        for index in 0..<count {
            let url = "https://site\(index).example"
            let mine = entry("mine\(index)", url: url), chrome = entry("chrome\(index)", url: url)
            saved.append(mine)
            live.append(chrome)
            rowList += rows(for: chrome, [("chrome\(index)", ago(1))])
        }
        return (saved, live, rowList)
    }

    private func dates(_ saved: [VaultEntry]) -> [UUID: Date] {
        Dictionary(uniqueKeysWithValues: saved.map { ($0.id, ago(30)) })
    }

    func testTenUpdatesAreWrittenAndElevenAreHeld() {
        let ten = accounts(10)
        XCTAssertFalse(ChromeUpdates.shouldHold(ChromeUpdates.plan(saved: ten.saved, live: ten.live, rows: ten.rows, dates: dates(ten.saved), now: now), saved: ten.saved, alreadyHeld: [], now: now))
        let eleven = accounts(11)
        XCTAssertTrue(ChromeUpdates.shouldHold(ChromeUpdates.plan(saved: eleven.saved, live: eleven.live, rows: eleven.rows, dates: dates(eleven.saved), now: now), saved: eleven.saved, alreadyHeld: [], now: now), "the first run after upgrading counts too")
    }

    func testTheCountCarriesAcrossReads() {
        let all = accounts(13)
        let firstLive = Array(all.live.prefix(6))
        let firstRows = all.rows.filter { row in firstLive.contains { $0.id == row.loginID } }
        let first = ChromeUpdates.plan(saved: all.saved, live: firstLive, rows: firstRows, dates: dates(all.saved), now: now)
        XCTAssertFalse(ChromeUpdates.shouldHold(first, saved: all.saved, alreadyHeld: [], now: now))
        var saved = all.saved
        for change in first.changes {
            let index = saved.firstIndex { $0.id == change.entryID }!
            ChromeUpdates.apply(change, to: &saved[index], kind: .automatic, now: now)
        }
        let second = ChromeUpdates.plan(saved: saved, live: all.live, rows: all.rows, dates: dates(all.saved), now: now)
        XCTAssertEqual(second.updates.count, 7, "the six already written are not counted twice")
        XCTAssertTrue(ChromeUpdates.shouldHold(second, saved: saved, alreadyHeld: [], now: now))
        XCTAssertFalse(ChromeUpdates.shouldHold(second, saved: saved, alreadyHeld: [], now: now.addingTimeInterval(ChromeUpdates.batchWindow + 1)), "after a day the earlier ones no longer count")
    }

    func testABatchAlreadyWaitingStaysWaitingEvenIfItWouldNowFit() throws {
        let few = accounts(2)
        let plan = ChromeUpdates.plan(saved: few.saved, live: few.live, rows: few.rows, dates: dates(few.saved), now: now)
        let held = Set(plan.updates.compactMap { $0.replacement?.event })
        XCTAssertTrue(ChromeUpdates.shouldHold(plan, saved: few.saved, alreadyHeld: held, now: now))
    }

    func testAnApprovedBatchDoesNotCountAgainstTheNextUpdate() throws {
        var saved = accounts(12).saved
        let all = accounts(12)
        saved = all.saved
        for change in ChromeUpdates.plan(saved: saved, live: all.live, rows: all.rows, dates: dates(saved), now: now).changes {
            let index = saved.firstIndex { $0.id == change.entryID }!
            ChromeUpdates.apply(change, to: &saved[index], kind: .approved, now: now)
        }
        let one = accounts(1)
        let plan = ChromeUpdates.plan(saved: one.saved, live: one.live, rows: one.rows, dates: dates(one.saved), now: now)
        XCTAssertFalse(ChromeUpdates.shouldHold(plan, saved: saved + one.saved, alreadyHeld: [], now: now))
    }

    func testDecliningKeepsThePasswordListsChromesValueAndIsNotAskedAgain() throws {
        let saved = entry("mine"), live = entry("chrome")
        let source = rows(for: live, [("chrome", ago(1))])
        let change = try XCTUnwrap(plan([saved], [live], source, savedDate: ago(30)).updates.first)
        let declined = applied(change, to: saved, kind: .declined)
        XCTAssertEqual(declined.password, "mine")
        let item = try XCTUnwrap(PreviousPasswords.items(of: declined, now: now).first)
        XCTAssertEqual(item.value, "chrome")
        XCTAssertFalse(item.used)
        XCTAssertTrue(plan([declined], [live], source, savedDate: ago(30)).isEmpty)
    }
}
#endif
