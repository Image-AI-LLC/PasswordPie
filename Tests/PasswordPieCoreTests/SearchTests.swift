import CoreGraphics
import XCTest
@testable import PasswordPieCore

private func entry(
    _ title: String,
    user: String = "",
    password: String = "",
    url: String = "",
    notes: String = "",
    tags: String = "",
    favorite: Bool = false,
    path: [String] = []
) -> VaultEntry {
    var e = VaultEntry(groupPath: path)
    e.title = title
    e.username = user
    e.password = password
    e.url = url
    e.notes = notes
    e.tags = tags
    if favorite { e.favorite = true }
    return e
}

final class SearchTests: XCTestCase {
    func titles(_ query: String, _ entries: [VaultEntry], _ scope: SearchScope = .major) -> [String] {
        searchEntries(entries, query: query, scope: scope).map(\.title)
    }

    func testEmptyQueryMatchesNothingBecauseTheInitialMenuShows() {
        XCTAssertTrue(titles("   ", [entry("A")]).isEmpty)
    }

    func testPrefixOfAnyWordIsPassOne() {
        let items = [entry("GitHub Enterprise", url: "https://git.example.com"), entry("Bitbucket")]
        XCTAssertEqual(titles("ent", items), ["GitHub Enterprise"])
        XCTAssertEqual(titles("exam", items), ["GitHub Enterprise"])
        XCTAssertTrue(titles("hub", items).contains("GitHub Enterprise"), "pass 2 finds substrings when prefixes fail")
    }

    func testSubstringPassRunsOnlyWhenPrefixPassIsEmpty() {
        let items = [entry("Hubspot"), entry("GitHub")]
        XCTAssertEqual(titles("hub", items), ["Hubspot"], "a prefix hit exists, so GitHub is not offered")
        XCTAssertEqual(titles("ithu", items), ["GitHub"])
    }

    func testEveryTokenMustMatchAndTokensAreDeduplicated() {
        let items = [entry("Work Mail"), entry("Work Wiki")]
        XCTAssertEqual(titles("work mail", items), ["Work Mail"])
        XCTAssertEqual(titles("work  work", items), ["Work Mail", "Work Wiki"])
    }

    func testCaseAndDiacriticsAreIgnored() {
        XCTAssertEqual(titles("CAFE", [entry("Café Müller")]), ["Café Müller"])
        XCTAssertEqual(titles("muller", [entry("Café Müller")]), ["Café Müller"])
    }

    func testTokenWithPunctuationIsASubstringOfTitleOrHost() {
        let items = [entry("Site", url: "https://my-bank.example.org/login"), entry("Other")]
        XCTAssertEqual(titles("my-bank", items), ["Site"])
        XCTAssertEqual(titles("k.exa", items), ["Site"])
        XCTAssertTrue(titles("login", items).isEmpty, "paths are not part of the host")
    }

    func testMajorScopeIgnoresUsernameNotesTagsAndCustomFields() {
        var item = entry("Plain", user: "ada", notes: "zebra", tags: "work")
        item.setValue("quartz", for: "Recovery")
        XCTAssertTrue(titles("ada", [item]).isEmpty)
        XCTAssertTrue(titles("zebra", [item]).isEmpty)
        XCTAssertEqual(titles("ada", [item], .allFields), ["Plain"])
        XCTAssertEqual(titles("zebra", [item], .allFields), ["Plain"])
        XCTAssertEqual(titles("work", [item], .allFields), ["Plain"])
        XCTAssertEqual(titles("quartz", [item], .allFields), ["Plain"])
    }

    func testPasswordsAreNeverSearched() {
        XCTAssertTrue(titles("hunter2", [entry("A", password: "hunter2")], .allFields).isEmpty)
    }

    func testTrashIsExcluded() {
        var gone = entry("Gone")
        gone.trashed = true
        XCTAssertTrue(titles("gone", [gone]).isEmpty)
    }

    func testOrderIsAlphabeticalWithFavoritesFirst() {
        let items = [entry("b app"), entry("a app"), entry("c app", favorite: true)]
        XCTAssertEqual(titles("app", items), ["c app", "a app", "b app"])
    }

    func testResultsGroupByCategoryWithHeadersAndCaps() {
        var items = (1...7).map { entry("Site \($0)", user: "u", password: "p", url: "https://s\($0).test") }
        items.append(entry("Site pass", password: "p"))
        items.append(entry("Site note", notes: "text"))
        let rows = MenuBuilder.searchResults(entries: items, query: "site", scope: .major)
        let headers = rows.filter { $0.kind == .header }.map(\.title)
        XCTAssertEqual(headers, ["Open Login", "Secure Notes", "Show Password"])
        let more = try? XCTUnwrap(rows.first { $0.kind == .showMore })
        XCTAssertEqual(more?.title, "Show 2 more items")
        XCTAssertEqual(more?.children.count, 2)
        XCTAssertEqual(rows.filter { $0.category == .login && $0.entryID != nil }.count, 5)
    }

    func testNoMatchesGivesOneDisabledRow() {
        let rows = MenuBuilder.searchResults(entries: [entry("A")], query: "zzz", scope: .major)
        XCTAssertEqual(rows, [MenuRow(kind: .disabled, title: "No items found")])
        XCTAssertFalse(rows[0].isSelectable)
    }
}

final class CategoryTests: XCTestCase {
    func testMapping() {
        XCTAssertEqual(entry("a", user: "u", password: "p").category, .login)
        XCTAssertEqual(entry("a", url: "https://x.test").category, .login)
        XCTAssertEqual(entry("a", password: "p").category, .password)
        XCTAssertEqual(entry("a", notes: "n").category, .secureNote)
        XCTAssertEqual(entry("a").category, .secureNote)
        var card = entry("Visa", password: "1234")
        card.setValue("4111", for: "Card Number")
        XCTAssertEqual(card.category, .creditCard)
        var person = entry("Me")
        person.setValue("Ada", for: "First Name")
        XCTAssertEqual(person.category, .identity)
    }

    func testNamesAndOrder() {
        XCTAssertEqual(ItemCategory.allCases.sorted().map(\.pluralName), ["Logins", "Secure Notes", "Credit Cards", "Identities", "Passwords", "Documents"])
        XCTAssertEqual(ItemCategory.login.searchGroupTitle, "Open Login")
        XCTAssertEqual(ItemCategory.password.searchGroupTitle, "Show Password")
        XCTAssertEqual(ItemCategory.secureNote.searchGroupTitle, "Secure Notes")
    }
}

final class TopLevelMenuTests: XCTestCase {
    func titles(_ rows: [MenuRow]) -> [String] {
        rows.map { $0.kind == .separator ? "-" : $0.title }
    }

    func testEmptyVaultShowsOnlyTheGenerator() {
        XCTAssertEqual(titles(MenuBuilder.topLevel(entries: [])), ["Password Generator"])
    }

    func testTopLevelOrderHasNoItems() {
        let items = [
            entry("Fav", user: "u", password: "p", tags: "Favorite"),
            entry("Note", notes: "n", tags: "shop"),
            entry("Deep", user: "u", password: "p", path: ["Internet", "Banks"]),
            entry("Direct", user: "u", password: "p", path: ["Internet"])
        ]
        let rows = MenuBuilder.topLevel(entries: items)
        XCTAssertEqual(titles(rows), ["Favorites", "Password Generator", "-", "Logins", "Secure Notes", "-", "Folders", "Tags"])
        XCTAssertTrue(rows.allSatisfy { $0.entryID == nil })
        let folders = rows.first { $0.title == "Folders" }!.children
        XCTAssertEqual(titles(folders), ["Internet"])
        XCTAssertEqual(titles(folders[0].children), ["Banks", "-", "Direct"])
        let tags = rows.first { $0.title == "Tags" }!.children
        XCTAssertEqual(titles(tags), ["shop"], "the Favorite tag is not listed")
    }

    func testCategoriesBeyondTheLimitCollapseIntoShowMore() {
        var card = entry("C"); card.setValue("1", for: "Card Number")
        let items = [entry("L", user: "u", password: "p"), entry("N", notes: "n"), entry("P", password: "p"), card]
        XCTAssertFalse(titles(MenuBuilder.topLevel(entries: items, categoryLimit: 3)).contains { $0.hasPrefix("Show") }, "limit + 1 categories still fit")
        let rows = MenuBuilder.topLevel(entries: items, categoryLimit: 2)
        XCTAssertEqual(titles(rows), ["Password Generator", "-", "Logins", "Secure Notes", "Show 2 more categories"])
        XCTAssertEqual(rows.last?.children.map(\.title), ["Credit Cards", "Passwords"])
    }

    func testDuplicateTitlesShowTheUsername() {
        let items = [
            entry("Mail", user: "a@x.com", password: "p"),
            entry("MAIL", user: "b@x.com", password: "p"),
            entry("Café", user: "c", password: "p"),
            entry("Unique", user: "d", password: "p")
        ]
        let rows = MenuBuilder.topLevel(entries: items).first { $0.title == "Logins" }!.children
        XCTAssertEqual(rows.first { $0.title == "Mail" }?.username, "a@x.com")
        XCTAssertEqual(rows.first { $0.title == "MAIL" }?.username, "b@x.com")
        XCTAssertEqual(rows.first { $0.title == "Unique" }?.username, "")
        XCTAssertEqual(rows.first { $0.title == "Café" }?.username, "")
    }

    func testSubmenuEntriesAreAlphabetical() {
        let items = [entry("beta", user: "u"), entry("Alpha", user: "u"), entry("gamma", user: "u", favorite: true)]
        let rows = MenuBuilder.topLevel(entries: items).first { $0.title == "Logins" }!.children
        XCTAssertEqual(rows.map(\.title), ["Alpha", "beta", "gamma"], "favorites are not moved to the top outside search")
    }

    func testTrashAndDuplicateFavoriteAppear() {
        var gone = entry("Gone", user: "u", tags: "Favorite")
        gone.trashed = true
        XCTAssertEqual(titles(MenuBuilder.topLevel(entries: [gone])), ["Password Generator"])
    }
}

final class AutoLockTests: XCTestCase {
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    func policy(_ clock: Clock, idle: @escaping () -> TimeInterval, settings: AutoLockSettings = AutoLockSettings()) -> AutoLockPolicy {
        AutoLockPolicy(settings: settings, clock: { clock.now }, systemIdle: idle)
    }

    /// Regression for the vault locking ~30 s after unlocking: a source stuck at 1.4 M s must not lock a vault in use.
    func testBrokenIdleReadingDoesNotLockRightAfterActivity() {
        let clock = Clock()
        var p = policy(clock) { 1_443_425 }
        p.registerActivity()
        clock.advance(30)
        XCTAssertFalse(p.shouldLockForIdle())
        clock.advance(200)
        XCTAssertFalse(p.shouldLockForIdle())
        clock.advance(100)
        XCTAssertTrue(p.shouldLockForIdle(), "both clocks have now passed the 5 minute timeout")
    }

    func testBothClocksMustExceedTheTimeout() {
        let clock = Clock()
        var idle: TimeInterval = 0
        var p = policy(clock) { idle }
        clock.advance(400)
        XCTAssertFalse(p.shouldLockForIdle(), "the user is typing")
        idle = 301
        XCTAssertTrue(p.shouldLockForIdle())
        p.registerActivity()
        XCTAssertFalse(p.shouldLockForIdle(), "app activity restarts the countdown")
    }

    func testTimeoutDefaultsAndFallback() {
        XCTAssertEqual(AutoLockSettings().timeout, 300)
        XCTAssertEqual(AutoLockSettings(timeoutMinutes: 0).timeout, 300)
        XCTAssertEqual(AutoLockSettings(timeoutMinutes: -3).timeout, 300)
        XCTAssertEqual(AutoLockSettings(timeoutMinutes: 10).timeout, 600)
    }

    func testIdleCanBeDisabled() {
        let clock = Clock()
        let p = policy(clock, idle: { 9_999 }, settings: AutoLockSettings(lockOnIdle: false))
        clock.advance(9_999)
        XCTAssertFalse(p.shouldLockForIdle())
    }

    func testSleepAndWake() {
        let clock = Clock()
        var p = policy(clock, idle: { 0 })
        XCTAssertTrue(p.willSleep())
        clock.advance(60)
        XCTAssertFalse(p.didWake(), "a short nap does not lock on wake")
        XCTAssertTrue(p.willSleep())
        clock.advance(300)
        XCTAssertTrue(p.didWake())
        XCTAssertFalse(p.didWake(), "no sleep recorded")
    }

    func testSleepGate() {
        let clock = Clock()
        var p = policy(clock, idle: { 0 }, settings: AutoLockSettings(lockOnSleep: false))
        XCTAssertFalse(p.willSleep())
    }

    func testScreenSaverUserSwitchPowerOff() {
        let clock = Clock()
        var settings = AutoLockSettings()
        let on = policy(clock, idle: { 0 }, settings: settings)
        XCTAssertTrue(on.screenSaverDidStart())
        XCTAssertTrue(on.sessionDidResignActive())
        XCTAssertTrue(on.willPowerOff())
        settings.lockOnScreenSaver = false
        settings.lockOnUserSwitch = false
        let off = policy(clock, idle: { 0 }, settings: settings)
        XCTAssertFalse(off.screenSaverDidStart())
        XCTAssertFalse(off.sessionDidResignActive())
        XCTAssertTrue(off.willPowerOff())
    }

    func testTouchIDWindowIsSevenDaysAfterMasterPasswordUnlock() {
        let unlocked = Date(timeIntervalSince1970: 0)
        let day: TimeInterval = 86_400
        XCTAssertTrue(TouchIDWindow.isValid(unlockedAt: unlocked, now: unlocked.addingTimeInterval(7 * day)))
        XCTAssertFalse(TouchIDWindow.isValid(unlockedAt: unlocked, now: unlocked.addingTimeInterval(7 * day + 1)))
        XCTAssertFalse(TouchIDWindow.isValid(unlockedAt: nil, now: unlocked))
    }
}

final class ClipboardGuardTests: XCTestCase {
    final class FakeBoard: PasteboardLike {
        var changeCount = 0
        var text: String?
        func write(_ string: String) -> Int { changeCount += 1; text = string; return changeCount }
        func clear() { changeCount += 1; text = nil }
        func foreignCopy(_ string: String) { changeCount += 1; text = string }
    }

    final class FakeTimer: Cancellable {
        let delay: TimeInterval
        let action: () -> Void
        var cancelled = false
        init(delay: TimeInterval, action: @escaping () -> Void) { self.delay = delay; self.action = action }
        func cancel() { cancelled = true }
        func fire() { if !cancelled { action() } }
    }

    var timers: [FakeTimer] = []

    func makeGuard(_ board: FakeBoard, timeout: TimeInterval = 90) -> ClipboardGuard {
        ClipboardGuard(pasteboard: board, timeout: timeout) { delay, action in
            let timer = FakeTimer(delay: delay, action: action)
            self.timers.append(timer)
            return timer
        }
    }

    func testClearsAfterTheTimeout() {
        let board = FakeBoard()
        let guardian = makeGuard(board)
        guardian.copy("secret")
        XCTAssertEqual(timers.last?.delay, 90)
        timers.last?.fire()
        XCTAssertNil(board.text)
    }

    func testTimeoutHasAFiveSecondFloor() {
        let board = FakeBoard()
        let guardian = makeGuard(board, timeout: 1)
        guardian.copy("x")
        XCTAssertEqual(timers.last?.delay, 5)
    }

    func testDoesNotClearSomethingElseTheUserCopied() {
        let board = FakeBoard()
        let guardian = makeGuard(board)
        guardian.copy("secret")
        board.foreignCopy("my shopping list")
        timers.last?.fire()
        XCTAssertEqual(board.text, "my shopping list")
    }

    func testFlushClearsOurCopyButNotAForeignOne() {
        let board = FakeBoard()
        let guardian = makeGuard(board)
        guardian.copy("secret")
        guardian.flush()
        XCTAssertNil(board.text)
        XCTAssertTrue(timers[0].cancelled)
        guardian.copy("again")
        board.foreignCopy("mine")
        guardian.flush()
        XCTAssertEqual(board.text, "mine")
        guardian.flush()
        XCTAssertEqual(board.text, "mine", "a second flush does nothing")
    }

    func testANewCopyCancelsTheOldTimer() {
        let board = FakeBoard()
        let guardian = makeGuard(board)
        guardian.copy("one")
        let first = timers[0]
        guardian.copy("two")
        XCTAssertTrue(first.cancelled)
        first.fire()
        XCTAssertEqual(board.text, "two")
        timers[1].fire()
        XCTAssertNil(board.text)
    }
}

final class GeneratorTests: XCTestCase {
    func testCharacterRecipeCountsAndLength() {
        for _ in 0..<50 {
            let recipe = CharacterRecipe(length: 24, digits: 4, symbols: 3)
            let password = PasswordGenerator.generate(recipe)
            XCTAssertEqual(password.count, 24)
            XCTAssertEqual(password.filter(\.isNumber).count, 4)
            XCTAssertEqual(password.filter { !$0.isLetter && !$0.isNumber }.count, 3)
        }
    }

    func testLimitsAreClamped() {
        let recipe = CharacterRecipe(length: 1000, digits: 99, symbols: -1)
        XCTAssertEqual(recipe.length, 64)
        XCTAssertEqual(recipe.digits, 10)
        XCTAssertEqual(recipe.symbols, 0)
        XCTAssertEqual(PassphraseRecipe(words: 1).words, 3)
        XCTAssertEqual(PassphraseRecipe(words: 50).words, 10)
    }

    func testAvoidAmbiguousExcludesLookalikes() {
        for _ in 0..<50 {
            let password = PasswordGenerator.generate(CharacterRecipe(length: 64, digits: 10, symbols: 0, avoidAmbiguous: true))
            XCTAssertFalse(password.contains { "0Ool1I|".contains($0) })
        }
    }

    func testPassphraseHasRequestedWordsAndSeparator() {
        let phrase = PasswordGenerator.generate(PassphraseRecipe(words: 5, separator: " "))
        XCTAssertEqual(phrase.split(separator: " ").count, 5)
        XCTAssertEqual(PasswordGenerator.wordList.count, 256)
        XCTAssertEqual(Set(PasswordGenerator.wordList).count, 256)
    }

    func testDefaultPassphraseIsSixWordsAndMeterReportsItsEntropy() {
        XCTAssertEqual(PassphraseRecipe().words, 6)
        XCTAssertEqual(PasswordGenerator.entropyBits(PassphraseRecipe()), 48, accuracy: 0.001)
        XCTAssertLessThan(PasswordGenerator.entropyBits(PassphraseRecipe(words: 3)), 25)
    }

    func testIndexSamplingRejectsBiasedBytes() {
        var bytes: [UInt8] = [255, 254, 7]
        let value = PasswordGenerator.index(below: 10) { bytes.removeFirst() }
        XCTAssertEqual(value, 7, "bytes 250 and above are rejected for a modulus of 10")
    }
}

final class MenuGeometryTests: XCTestCase {
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 877)

    func testConfinementInsetsAllButTheTop() {
        let area = MenuGeometry.confinement(visibleFrame: visible)
        XCTAssertEqual(area, CGRect(x: 8, y: 8, width: 1424, height: 869))
    }

    func testHotkeyPlacementIsCenteredTwentyPercentDown() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(MenuGeometry.centeredTopLeft(screenFrame: screen), CGPoint(x: 570, y: 720))
        let second = CGRect(x: 1440, y: -100, width: 1920, height: 1080)
        XCTAssertEqual(MenuGeometry.centeredTopLeft(screenFrame: second), CGPoint(x: 1440 + 810, y: -100 + 864))
    }

    func testFrameHangsFromTopLeftAndMovesUpOnlyAtTheBottom() {
        let area = MenuGeometry.confinement(visibleFrame: visible)
        let hang = MenuGeometry.frame(topLeft: CGPoint(x: 100, y: 700), size: CGSize(width: 300, height: 200), in: area)
        XCTAssertEqual(hang, CGRect(x: 100, y: 500, width: 300, height: 200))
        let low = MenuGeometry.frame(topLeft: CGPoint(x: 100, y: 150), size: CGSize(width: 300, height: 200), in: area)
        XCTAssertEqual(low.minY, 8)
        XCTAssertEqual(low.maxY, 208)
    }

    func testFrameClampsHorizontallyAndCapsHeight() {
        let area = MenuGeometry.confinement(visibleFrame: visible)
        let right = MenuGeometry.frame(topLeft: CGPoint(x: 1400, y: 800), size: CGSize(width: 300, height: 100), in: area)
        XCTAssertEqual(right.maxX, 1432)
        let tall = MenuGeometry.frame(topLeft: CGPoint(x: 0, y: 800), size: CGSize(width: 300, height: 5000), in: area)
        XCTAssertEqual(tall.height, area.height)
        XCTAssertEqual(tall.maxY, area.maxY)
    }

    func testSnapBackInsideThreeHundredPoints() {
        let center = CGPoint(x: 570, y: 720)
        XCTAssertTrue(MenuGeometry.shouldSnapToCenter(topLeft: CGPoint(x: 700, y: 650), centered: center))
        XCTAssertFalse(MenuGeometry.shouldSnapToCenter(topLeft: CGPoint(x: 100, y: 300), centered: center))
    }

    func testSubmenuOpensToTheRightAlignedWithTheRow() {
        let area = MenuGeometry.confinement(visibleFrame: visible)
        let parent = CGRect(x: 100, y: 500, width: 300, height: 300)
        let child = MenuGeometry.childFrame(parent: parent, rowTop: 700, size: CGSize(width: 200, height: 105), in: area)
        XCTAssertEqual(child.minX, 400)
        XCTAssertEqual(child.maxY, 705, "five points above the row so the first row lines up")
    }

    func testSubmenuFlipsLeftWhenItDoesNotFit() {
        let area = MenuGeometry.confinement(visibleFrame: visible)
        let parent = CGRect(x: 1100, y: 500, width: 300, height: 300)
        let child = MenuGeometry.childFrame(parent: parent, rowTop: 700, size: CGSize(width: 200, height: 105), in: area)
        XCTAssertEqual(child.maxX, 1100)
    }

    func testMenuWidthIsCappedAtAQuarterOfTheScreen() {
        XCTAssertEqual(MenuGeometry.width(widestRow: 120, minimum: 300, screenWidth: 1440), 300)
        XCTAssertEqual(MenuGeometry.width(widestRow: 340, minimum: 300, screenWidth: 1440), 340)
        XCTAssertEqual(MenuGeometry.width(widestRow: 900, minimum: 300, screenWidth: 1440), 360)
        XCTAssertEqual(MenuGeometry.width(widestRow: 10, minimum: 50, screenWidth: 1440), 50)
    }
}
