import AppKit
import PasswordPieCore
import XCTest
@testable import PasswordPie

/// `docs/UX.md`, "Pick up where you left off": reopening within 10 seconds brings back the search and the selected account.
@MainActor
final class QuickAccessRecallTests: XCTestCase {
    private var directory: URL!
    private var clock = Date(timeIntervalSinceReferenceDate: 1_000_000)

    override func setUpWithError() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "the panel needs a screen to become visible")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("recall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("PASSWORDPIE_DB", directory.appendingPathComponent("test.kdbx").path, 1)
        setenv("PASSWORDPIE_USAGE", directory.appendingPathComponent("usage.json").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("PASSWORDPIE_DB")
        unsetenv("PASSWORDPIE_USAGE")
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: The window

    func testRecallLastsUnderTenSeconds() {
        var recall = QuickAccessRecall()
        let start = Date()
        let saved = QuickAccessSnapshot(searchText: "git", place: MenuPlace(query: "git", path: []))

        recall.remember(saved, at: start)
        XCTAssertEqual(recall.take(at: start.addingTimeInterval(9.9)), saved)

        recall.remember(saved, at: start)
        XCTAssertNil(recall.take(at: start.addingTimeInterval(10)))
    }

    func testRecallIsUsedOnce() {
        var recall = QuickAccessRecall()
        let start = Date()
        recall.remember(QuickAccessSnapshot(searchText: "git", place: MenuPlace(query: "git", path: [])), at: start)

        XCTAssertNotNil(recall.take(at: start))
        XCTAssertNil(recall.take(at: start))
    }

    func testAClockSetBackwardsEndsTheRecall() {
        var recall = QuickAccessRecall()
        let start = Date()
        recall.remember(QuickAccessSnapshot(searchText: "git", place: MenuPlace(query: "git", path: [])), at: start)

        XCTAssertNil(recall.take(at: start.addingTimeInterval(-1)))
    }

    func testForgetEndsTheRecall() {
        var recall = QuickAccessRecall()
        let start = Date()
        recall.remember(QuickAccessSnapshot(searchText: "git", place: MenuPlace(query: "git", path: [])), at: start)

        recall.forget()

        XCTAssertNil(recall.take(at: start))
    }

    // MARK: Reopening the panel

    func testReopeningKeepsTheSearchAndTheSameAccount() throws {
        let (_, panel) = openPanel(entries: [login("GitHub", "first"), login("GitHub", "second")])
        defer { panel.hide() }
        search("github", in: panel)
        let top = try XCTUnwrap(panel.menu.currentEntryID)
        _ = panel.headerKey(.down)
        let chosen = try XCTUnwrap(panel.menu.currentEntryID)
        XCTAssertNotEqual(chosen, top, "equal titles sort by id, so the account to keep is the one that is not on top")

        panel.hide()
        clock.addTimeInterval(5)
        panel.show(.hotkey)

        XCTAssertEqual(panel.header.searchField.stringValue, "github")
        XCTAssertEqual(panel.menu.query, "github")
        XCTAssertEqual(panel.menu.currentEntryID, chosen)
        XCTAssertFalse(panel.header.showsSeparator, "a query is showing, so the band under the field stays hidden")
    }

    func testTheSearchComesBackSelectedSoTypingReplacesIt() throws {
        let (_, panel) = openPanel(entries: [login("GitHub", "first")])
        defer { panel.hide() }
        search("github", in: panel)

        panel.hide()
        panel.show(.hotkey)

        let editor = try XCTUnwrap(panel.header.searchField.currentEditor())
        XCTAssertEqual(editor.string, "github")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 6))
    }

    func testTenSecondsLaterTheMenuStartsEmpty() {
        let (_, panel) = openPanel(entries: [login("GitHub", "first")])
        defer { panel.hide() }
        search("github", in: panel)

        panel.hide()
        clock.addTimeInterval(10)
        panel.show(.hotkey)

        XCTAssertEqual(panel.header.searchField.stringValue, "")
        XCTAssertEqual(panel.menu.query, "")
    }

    func testEveryCloseStartsTheTenSecondsAgain() {
        let (_, panel) = openPanel(entries: [login("GitHub", "first")])
        defer { panel.hide() }
        search("github", in: panel)

        panel.hide()
        clock.addTimeInterval(9)
        panel.show(.hotkey)
        panel.hide()
        clock.addTimeInterval(9)
        panel.show(.hotkey)

        XCTAssertEqual(panel.menu.query, "github")
    }

    func testEscapeMeansDone() {
        let (_, panel) = openPanel(entries: [login("GitHub", "first")])
        defer { panel.hide() }
        search("github", in: panel)

        panel.headerEscape()
        XCTAssertTrue(panel.isVisible, "the first press only clears the search")
        _ = panel.headerKey(.down)
        panel.headerEscape()
        XCTAssertFalse(panel.isVisible)
        panel.show(.hotkey)

        XCTAssertEqual(panel.menu.query, "")
        XCTAssertEqual(panel.menu.root.list.selectedIndex, panel.menu.root.firstSelectable)
    }

    func testEscapeOutsideTheSearchFieldMeansDoneToo() {
        let (_, panel) = openPanel(entries: [login("GitHub", "first")])
        defer { panel.hide() }
        search("github", in: panel)

        panel.panel.cancelOperation(nil)
        panel.show(.hotkey)

        XCTAssertEqual(panel.menu.query, "")
    }

    func testLockingForgetsTheSearch() async {
        let (session, panel) = openPanel(entries: [login("GitHub", "first")])
        defer { panel.hide() }
        search("github", in: panel)

        panel.hide()
        session.lock()
        session.passwordDraft = "pw"
        session.unlock()
        await waitUntil { !session.locked }
        panel.show(.hotkey)

        XCTAssertEqual(panel.header.searchField.stringValue, "")
        XCTAssertEqual(panel.menu.query, "")
    }

    func testAnAccountThatIsGoneFallsBackToTheFirstResult() throws {
        let (session, panel) = openPanel(entries: [login("GitHub", "first"), login("GitHub", "second")])
        defer { panel.hide() }
        search("github", in: panel)
        let top = try XCTUnwrap(panel.menu.currentEntryID)
        _ = panel.headerKey(.down)
        let removed = try XCTUnwrap(panel.menu.currentEntryID)
        XCTAssertNotEqual(removed, top)

        panel.hide()
        session.entries.removeAll { $0.id == removed }
        panel.show(.hotkey)

        XCTAssertEqual(panel.menu.query, "github")
        XCTAssertEqual(panel.menu.currentEntryID, top)
    }

    func testAnAccountInsideASubmenuComesBack() throws {
        var favorite = login("GitHub", "first")
        favorite.favorite = true
        var second = login("GitLab", "second")
        second.favorite = true
        let (_, panel) = openPanel(entries: [favorite, second])
        defer { panel.hide() }
        panel.menu.debugOpen(path: ["Favorites"])
        panel.menu.deepest.list.selectedIndex = 1
        let chosen = try XCTUnwrap(panel.menu.currentEntryID)

        panel.hide()
        XCTAssertEqual(panel.menu.levels.count, 1)
        panel.show(.hotkey)

        XCTAssertEqual(panel.menu.levels.count, 2)
        XCTAssertEqual(panel.menu.currentEntryID, chosen)
    }

    func testAnAccountUnderShowMoreComesBack() throws {
        let entries = (0..<8).map { login("GitHub \($0)", "user\($0)") }
        let (_, panel) = openPanel(entries: entries)
        defer { panel.hide() }
        search("github", in: panel)
        let more = try XCTUnwrap(panel.menu.root.rows.firstIndex { $0.kind == .showMore })
        panel.menu.root.list.selectedIndex = more
        _ = panel.headerKey(.enter)
        panel.menu.root.list.selectedIndex = panel.menu.root.rows.count - 1
        let chosen = try XCTUnwrap(panel.menu.currentEntryID)

        panel.hide()
        panel.show(.hotkey)

        XCTAssertEqual(panel.menu.currentEntryID, chosen)
    }

    func testTheDetailsPopoverStaysClosed() throws {
        let (_, panel) = openPanel(entries: [login("GitHub", "first")])
        defer { panel.hide() }
        search("github", in: panel)
        let chosen = try XCTUnwrap(panel.menu.currentEntryID)
        _ = panel.headerKey(.right)
        XCTAssertTrue(panel.menu.popoverIsOpen)

        panel.hide()
        panel.show(.hotkey)

        XCTAssertFalse(panel.menu.popoverIsOpen)
        XCTAssertEqual(panel.menu.currentEntryID, chosen)
    }

    // MARK: Refreshing the open list

    /// Showing the panel can refresh Chrome, which rebuilds the list right after it comes back.
    func testARefreshKeepsTheSameAccountAmongEqualTitles() throws {
        let (_, panel) = openPanel(entries: [login("GitHub", "first"), login("GitHub", "second")])
        defer { panel.hide() }
        search("github", in: panel)
        _ = panel.headerKey(.down)
        let chosen = try XCTUnwrap(panel.menu.currentEntryID)

        panel.menu.refresh()

        XCTAssertEqual(panel.menu.currentEntryID, chosen)
    }

    func testARefreshKeepsAnOpenSubmenu() throws {
        var favorite = login("GitHub", "first")
        favorite.favorite = true
        let (_, panel) = openPanel(entries: [favorite])
        defer { panel.hide() }
        panel.menu.debugOpen(path: ["Favorites"])
        panel.menu.deepest.list.selectedIndex = 0

        panel.menu.refresh()

        XCTAssertEqual(panel.menu.levels.count, 2)
        XCTAssertEqual(panel.menu.currentEntryID, favorite.id)
    }

    /// The root grows by a row while a submenu is open. The panel takes its new size at once, so the child is placed against the final list.
    func testARefreshThatGrowsTheRootKeepsTheSubmenuOnItsRow() async throws {
        let (session, panel) = openPanel(entries: [login("GitHub", "first")])
        defer { panel.hide() }
        panel.menu.debugOpen(path: ["Logins"])
        panel.menu.deepest.list.selectedIndex = 0
        XCTAssertFalse(panel.menu.root.rows.contains { $0.title == "Favorites" })

        session.entries[0].favorite = true
        await waitUntil { panel.menu.root.rows.contains { $0.title == "Favorites" } }
        // Longer than any frame animation, so a list that settled late would have moved its row by now.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(panel.menu.levels.count, 2)
        let offset = try submenuOffset(from: panel.menu.root, to: panel.menu.deepest)
        XCTAssertEqual(offset, MenuGeometry.submenuInset, accuracy: 1, "the first child row lines up with its parent")
    }

    /// The selected folder is far below the fold when the panel comes back. Its row scrolls into view before its submenu is placed.
    func testASubmenuReopenedFarDownTheListStaysBesideItsRow() throws {
        let entries = (0..<200).map { index -> VaultEntry in
            var entry = login("Site \(index)", "user\(index)")
            entry.groupPath = [String(format: "Folder %03d", index)]
            return entry
        }
        let (_, panel) = openPanel(entries: entries)
        defer { panel.hide() }
        panel.menu.debugOpen(path: ["Folders", "Folder 199"])
        panel.menu.deepest.list.selectedIndex = 0
        let chosen = try XCTUnwrap(panel.menu.currentEntryID)

        panel.hide()
        panel.show(.hotkey)

        XCTAssertEqual(panel.menu.currentEntryID, chosen)
        XCTAssertEqual(panel.menu.levels.count, 3)
        let folders = panel.menu.levels[1]
        let row = try rowOnScreen(in: folders)
        let window = try XCTUnwrap(folders.window)
        XCTAssertTrue(window.frame.insetBy(dx: 0, dy: -1).contains(row), "the selected folder is scrolled into view")
        let child = try XCTUnwrap(panel.menu.deepest.window)
        XCTAssertTrue(child.frame.minY < row.maxY && child.frame.maxY > row.minY, "the child window sits beside its row, not off in the list")
    }

    // MARK: Helpers

    private func rowOnScreen(in level: MenuLevel) throws -> NSRect {
        let index = try XCTUnwrap(level.list.selectedIndex)
        let window = try XCTUnwrap(level.list.window)
        return window.convertToScreen(level.list.convert(level.list.rect(of: index), to: nil))
    }

    /// How far the child window's top sits above its parent row's top.
    private func submenuOffset(from parent: MenuLevel, to child: MenuLevel) throws -> CGFloat {
        let window = try XCTUnwrap(child.window)
        return window.frame.maxY - (try rowOnScreen(in: parent)).maxY
    }

    private func openPanel(entries: [VaultEntry]) -> (VaultSession, PanelController) {
        let session = VaultSession()
        session.restore()
        session.passwordDraft = "pw"
        session.confirmDraft = "pw"
        session.unlock()
        session.entries = entries
        let panel = PanelController(session: session)
        panel.now = { [unowned self] in self.clock }
        panel.show(.hotkey)
        return (session, panel)
    }

    private func search(_ text: String, in panel: PanelController) {
        panel.header.searchField.stringValue = text
        panel.header.searchField.currentEditor()?.string = text
        panel.headerSearchChanged(text)
    }

    private func login(_ title: String, _ username: String) -> VaultEntry {
        var entry = VaultEntry()
        entry.title = title
        entry.username = username
        entry.password = "secret-\(username)"
        return entry
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline {
                XCTFail("timed out")
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
